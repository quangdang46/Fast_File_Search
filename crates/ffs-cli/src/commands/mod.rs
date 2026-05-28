pub mod callees;
pub(crate) mod callees_bfs;
pub(crate) mod callees_detail;
pub(crate) mod callees_format;
pub(crate) mod callees_resolve;
pub mod callers;
pub(crate) mod callers_bfs;
pub(crate) mod dedup;
pub mod deps;
pub(crate) mod deps_resolve;
pub(crate) mod did_you_mean;
pub mod dispatch;
pub(crate) mod expand;
pub(crate) mod facets;
pub mod find;
pub mod flow;
pub mod glob;
pub mod grep;
pub mod guide;
pub mod impact;
pub mod index;
pub mod map;
pub mod mcp;
pub mod outline;
pub(crate) mod outline_format;
pub mod overview;
pub(crate) mod pagination;
pub mod read;
pub mod refs;
pub mod session;
pub mod siblings;
pub mod symbol;

use std::path::Path;

use anyhow::Result;
use serde::Serialize;

use crate::cli::OutputFormat;

/// Helper: emit either a human text rendering or JSON.
pub(crate) fn emit<T, R>(format: OutputFormat, payload: &T, render_text: R) -> Result<()>
where
    T: Serialize,
    R: FnOnce(&T) -> String,
{
    match format {
        OutputFormat::Json => {
            println!("{}", serde_json::to_string_pretty(payload)?);
        }
        OutputFormat::Text => {
            print!("{}", render_text(payload));
        }
    }
    Ok(())
}

/// Walk all files under `root` honoring `.gitignore` and return their paths.
///
/// Uses `ignore::WalkBuilder::build_parallel` with up to 8 threads — capped
/// to avoid IO thrash on consumer SSDs while still giving a ~2x speedup over
/// the single-threaded walker on multi-core hardware. The returned vector is
/// in arrival order (non-deterministic across runs); callers that need
/// stable ordering must sort the result themselves.
pub(crate) fn walk_files(root: &Path) -> Vec<std::path::PathBuf> {
    use ignore::WalkState;
    use std::sync::Mutex;

    let threads = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(2)
        .min(8);

    let out: Mutex<Vec<std::path::PathBuf>> = Mutex::new(Vec::with_capacity(1024));
    let walker = ignore::WalkBuilder::new(root)
        .standard_filters(true)
        .follow_links(false)
        .threads(threads)
        .build_parallel();
    walker.run(|| {
        let out = &out;
        Box::new(move |entry| {
            if let Ok(e) = entry {
                if e.file_type().is_some_and(|t| t.is_file()) {
                    if let Ok(mut guard) = out.lock() {
                        guard.push(e.into_path());
                    }
                }
            }
            WalkState::Continue
        })
    });
    out.into_inner().unwrap_or_default()
}

/// Walk all directories under `root` honoring `.gitignore`.
pub(crate) fn walk_dirs(root: &Path) -> Vec<std::path::PathBuf> {
    use ignore::WalkState;
    use std::sync::Mutex;

    let threads = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(2)
        .min(8);

    let out: Mutex<Vec<std::path::PathBuf>> = Mutex::new(Vec::with_capacity(256));
    let walker = ignore::WalkBuilder::new(root)
        .standard_filters(true)
        .follow_links(false)
        .threads(threads)
        .build_parallel();
    walker.run(|| {
        let out = &out;
        Box::new(move |entry| {
            if let Ok(e) = entry {
                if e.file_type().is_some_and(|t| t.is_dir()) {
                    if let Ok(mut guard) = out.lock() {
                        guard.push(e.into_path());
                    }
                }
            }
            WalkState::Continue
        })
    });
    out.into_inner().unwrap_or_default()
}
