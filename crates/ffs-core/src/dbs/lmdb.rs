use heed::{Database, Env, EnvOpenOptions};
use std::fs;
use std::path::Path;
use std::sync::Arc;
use std::sync::RwLock;
use std::sync::atomic::{AtomicU8, Ordering};
use std::thread;
use std::time::Duration;

use crate::error::{Error, Result};

pub(crate) fn is_map_full(err: &heed::Error) -> bool {
    matches!(err, heed::Error::Mdb(heed::MdbError::MapFull))
}

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DbHealthState {
    Pending = 0,
    Healthy = 1,
    Degraded = 2,
}

impl DbHealthState {
    fn from_u8(v: u8) -> Self {
        debug_assert!(v <= 2);
        match v {
            0 => Self::Pending,
            1 => Self::Healthy,
            _ => Self::Degraded,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub(crate) struct DbHealth(Arc<AtomicU8>);

impl DbHealth {
    pub(crate) fn new() -> Self {
        Self(Arc::new(AtomicU8::new(DbHealthState::Pending as u8)))
    }

    pub(crate) fn is_healthy(&self) -> bool {
        // Pending counts as unhealthy: if the GC thread never flipped to
        // Healthy, something's wrong (deadlocked clear_stale_readers, stuck
        // writer mutex, etc.) and we want that surfaced.
        DbHealthState::from_u8(self.0.load(Ordering::Acquire)) == DbHealthState::Healthy
    }

    pub(crate) fn mark_healthy(&self) {
        let _ = self.0.compare_exchange(
            DbHealthState::Pending as u8,
            DbHealthState::Healthy as u8,
            Ordering::AcqRel,
            Ordering::Acquire,
        );
    }

    pub(crate) fn mark_unhealthy(&self, reason: &'static str) {
        let prev = self.0.swap(DbHealthState::Degraded as u8, Ordering::AcqRel);
        if DbHealthState::from_u8(prev) != DbHealthState::Degraded {
            tracing::error!(reason, "LMDB tracker marked unhealthy");
        }
    }
}

/// Spawn a background GC thread that clears stale readers and purges stale data.
/// Holds a read lock on the shared handle so destroy/re-init naturally wait.
#[allow(dead_code)]
pub(crate) fn spawn_lmdb_gc<T: LmdbStore>(shared: Arc<RwLock<Option<T>>>) {
    let thread_shared = shared.clone();
    let spawn_result = thread::Builder::new()
        .name("ffs-lmdb-gc".into())
        .spawn(move || {
            let guard = match thread_shared.read() {
                Ok(g) => g,
                Err(e) => {
                    tracing::debug!("gc: read lock poisoned: {e}");
                    return;
                }
            };
            let Some(ref tracker) = *guard else {
                return;
            };
            let env = tracker.env();

            if let Err(e) = T::purge_stale_data(env) {
                tracing::debug!("purge_stale_data failed: {e}");
            }

            if let Err(e) = env.clear_stale_readers() {
                tracing::debug!("clear_stale_readers in GC failed: {e}");
            }

            tracker.health().mark_healthy();
        });

    if let Err(e) = spawn_result {
        tracing::debug!(?e, "failed to spawn ffs-lmdb-gc thread");
        // No thread = mark healthy now so healthcheck isn't stuck Pending.
        if let Ok(guard) = shared.read()
            && let Some(ref tracker) = *guard
        {
            tracker.health().mark_healthy();
        }
    }
}

// Concurrent `mdb_env_open` calls on the same path can race on macOS
fn is_transient_env_open_error(err: &heed::Error) -> bool {
    match err {
        heed::Error::Io(io) => matches!(
            io.kind(),
            std::io::ErrorKind::InvalidInput | std::io::ErrorKind::NotFound
        ),
        _ => false,
    }
}

#[allow(dead_code)]
pub(crate) trait LmdbStore: Sized + Send + Sync + 'static {
    /// Short label for diagnostics
    const LABEL: &'static str;
    /// LMDB map size in bytes. Must be a multiple of the OS page size.
    const MAP_SIZE: usize;
    /// Number of named sub-databases. `0` for single-db envs.
    const MAX_DBS: u32;
    /// Hard cap on `data.mdb` size.
    const SIZE_CAP_BYTES: u64;

    fn env(&self) -> &Env;
    fn health(&self) -> &DbHealth;

    /// Override to purge stale rows, compact, etc. Default no-op.
    fn purge_stale_data(_env: &Env) -> Result<()> {
        Ok(())
    }

    /// Open the LMDB env with retry logic and stale reader cleanup.
    #[tracing::instrument]
    fn open_env(db_path: &Path) -> Result<(Env, DbHealth)> {
        Self::erase_if_oversized(db_path);
        fs::create_dir_all(db_path).map_err(Error::CreateDir)?;

        const MAX_ATTEMPTS: u32 = 8;
        let mut attempt = 0u32;
        let env = loop {
            let result = unsafe {
                let mut opts = EnvOpenOptions::new();
                opts.map_size(Self::MAP_SIZE);
                if Self::MAX_DBS > 0 {
                    opts.max_dbs(Self::MAX_DBS);
                }
                opts.open(db_path)
            };

            match result {
                Ok(env) => break env,
                Err(e) if is_transient_env_open_error(&e) && attempt + 1 < MAX_ATTEMPTS => {
                    attempt += 1;
                    tracing::debug!(
                        path = %db_path.display(),
                        attempt,
                        error = ?e,
                        "transient LMDB env open error, retrying"
                    );
                    thread::sleep(Duration::from_millis(50));
                }
                Err(e) => return Err(Error::EnvOpen(e)),
            }
        };

        // Reclaim reader slots left by prior processes that died without cleanup.
        // Must run before we start any read txns — otherwise we may hit
        // MDB_READERS_FULL on a fresh env from stale lock.mdb entries.
        match env.clear_stale_readers() {
            Ok(cleared) if cleared > 0 => {
                tracing::warn!(cleared, "reclaimed stale LMDB reader slots at open");
            }
            Ok(_) => {}
            Err(e) => tracing::debug!("clear_stale_readers at open failed: {e}"),
        }

        Ok((env, DbHealth::new()))
    }

    /// Open or create a database without blocking on the LMDB writer mutex
    /// when the database already exists.
    fn open_database_safe<KC, DC>(env: &Env, name: Option<&str>) -> Result<Database<KC, DC>>
    where
        KC: 'static,
        DC: 'static,
    {
        let rtxn = env.read_txn().map_err(Error::DbStartReadTxn)?;
        let maybe_db: Option<Database<KC, DC>> =
            env.open_database(&rtxn, name).map_err(Error::DbOpen)?;

        rtxn.commit().map_err(Error::DbCommit)?;

        match maybe_db {
            Some(db) => Ok(db),
            None => {
                // First time: create the database (requires write lock).
                let mut wtxn = env.write_txn().map_err(Error::DbStartWriteTxn)?;
                let db = env
                    .create_database(&mut wtxn, name)
                    .map_err(Error::DbCreate)?;

                wtxn.commit().map_err(Error::DbCommit)?;
                Ok(db)
            }
        }
    }

    fn erase_if_oversized(db_path: &Path) {
        let data = db_path.join("data.mdb");
        let Ok(meta) = fs::metadata(&data) else {
            return;
        };
        if meta.len() <= Self::SIZE_CAP_BYTES {
            return;
        }

        tracing::error!(
            path = %db_path.display(),
            size = meta.len(),
            cap = Self::SIZE_CAP_BYTES,
            "LMDB db exceeds size cap, erasing"
        );
        let _ = fs::remove_file(&data);
        let _ = fs::remove_file(db_path.join("lock.mdb"));
    }
}
