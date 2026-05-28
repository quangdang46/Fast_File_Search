use std::alloc::{self, Layout};
use std::ptr::NonNull;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

/// Vector that guarantees no reallocation at runtime.
///
/// Backed by an `Arc<StableBuf>` — cloning is O(1) (just an Arc bump) and all
/// clones share the same stable buffer address. Raw pointers derived from
/// `as_ptr()` remain valid for the lifetime of the Arc, which is the invariant
/// that `PostScanUnsafeSnapshot` relies on when handing file pointers to rayon
/// workers.
pub(crate) struct StableVec<T> {
    inner: Arc<StableBuf<T>>,
}

struct StableBuf<T> {
    ptr: NonNull<T>,
    cap: usize,
    /// Atomic because:
    ///   1. `push(&self)` must mutate this through a shared `&StableBuf`,
    ///      which requires interior mutability.
    ///   2. Arc clones (e.g. post-scan snapshots) read `len` outside the
    ///      picker lock, concurrent with an appending writer. Acquire/Release
    ///      on len is what makes "observed len -> element bytes initialized"
    ///      actually hold.
    ///
    /// Arc wrapping only shares ownership of the buffer; it does NOT
    /// synchronize access to fields inside the shared buffer.
    len: AtomicUsize,
}

// SAFETY: StableBuf is a thread-safe container when T is send + sync.
// There is another application-level constraint: mutations are safe
// when they are atomic updates, not read + update.
unsafe impl<T: Send> Send for StableBuf<T> {}
unsafe impl<T: Sync> Sync for StableBuf<T> {}

impl<T> Drop for StableBuf<T> {
    fn drop(&mut self) {
        let len = *self.len.get_mut();
        unsafe {
            std::ptr::drop_in_place(std::ptr::slice_from_raw_parts_mut(self.ptr.as_ptr(), len));
            if self.cap > 0 {
                let layout = Layout::array::<T>(self.cap).expect("layout");
                alloc::dealloc(self.ptr.as_ptr().cast(), layout);
            }
        }
    }
}

impl<T> StableVec<T> {
    pub fn from_vec_with_reserve(mut vec: Vec<T>, extra: usize) -> Self {
        vec.reserve(extra);
        let cap = vec.capacity();
        let len = vec.len();

        let inner = if cap == 0 {
            StableBuf {
                ptr: NonNull::dangling(),
                cap: 0,
                len: AtomicUsize::new(0),
            }
        } else {
            // Take ownership of the Vec's buffer without running element
            // drops; we hand them off to the StableBuf.
            let mut vec = std::mem::ManuallyDrop::new(vec);
            let ptr = NonNull::new(vec.as_mut_ptr()).expect("non-null");
            StableBuf {
                ptr,
                cap,
                len: AtomicUsize::new(len),
            }
        };

        Self {
            inner: Arc::new(inner),
        }
    }

    /// Append. Returns `false` if capacity is exhausted (item dropped).
    ///
    /// Safe to call via `&self` as long as the caller holds the outer
    /// picker write lock (single-writer invariant).
    #[inline]
    pub fn push(&self, item: T) -> bool {
        let cap = self.inner.cap;
        let len = self.inner.len.load(Ordering::Acquire);
        if len >= cap {
            debug_assert!(
                false,
                "StableVec: push would exceed capacity ({len} at capacity {cap})"
            );
            tracing::error!(
                len,
                capacity = cap,
                "StableVec: capacity exhausted — dropping item to prevent reallocation"
            );
            return false;
        }
        unsafe {
            std::ptr::write(self.inner.ptr.as_ptr().add(len), item);
        }
        self.inner.len.store(len + 1, Ordering::Release);
        true
    }

    #[inline]
    pub fn remove(&mut self, index: usize) -> T {
        let len = self.inner.len.load(Ordering::Acquire);
        debug_assert!(index < len, "remove index out of bounds");
        unsafe {
            let ptr = self.inner.ptr.as_ptr().add(index);
            let val = std::ptr::read(ptr);
            // Shift elements left
            std::ptr::copy(ptr.add(1), ptr, len - index - 1);
            self.inner.len.store(len - 1, Ordering::Release);
            val
        }
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.inner.len.load(Ordering::Acquire)
    }

    #[inline]
    pub fn as_ptr(&self) -> *const T {
        self.inner.ptr.as_ptr()
    }

    /// Mutable element access for in-place field updates. Never shifts.
    ///
    /// LATENT UB: produces `&mut T` aliasing Arc-shared memory; the
    /// `&mut self` on StableVec does NOT imply unique access to the
    /// `StableBuf` when sibling Arc clones exist. Safe in practice
    /// because callers hold the picker write lock and writes target
    /// disjoint fields, but strictly forbidden by the aliasing model.
    #[inline]
    pub fn get_mut(&mut self, index: usize) -> Option<&mut T> {
        let len = self.inner.len.load(Ordering::Acquire);
        if index >= len {
            return None;
        }
        unsafe { Some(&mut *self.inner.ptr.as_ptr().add(index)) }
    }

    #[inline]
    pub fn last(&self) -> Option<&T> {
        let len = self.len();
        if len == 0 {
            None
        } else {
            unsafe { Some(&*self.inner.ptr.as_ptr().add(len - 1)) }
        }
    }

    /// Iterate mutably for in-place field updates. Never shifts storage.
    /// Same latent-UB caveat as [`get_mut`]: `&mut T` into Arc-shared memory.
    #[inline]
    pub fn iter_mut(&mut self) -> std::slice::IterMut<'_, T> {
        let len = self.inner.len.load(Ordering::Acquire);
        unsafe { std::slice::from_raw_parts_mut(self.inner.ptr.as_ptr(), len).iter_mut() }
    }

    #[inline]
    pub fn retain<F: FnMut(&T) -> bool>(&mut self, mut f: F) {
        let len = self.inner.len.load(Ordering::Acquire);
        let mut kept = 0usize;
        unsafe {
            let ptr = self.inner.ptr.as_ptr();
            for i in 0..len {
                if f(&*ptr.add(i)) {
                    if kept != i {
                        std::ptr::copy_nonoverlapping(ptr.add(i), ptr.add(kept), 1);
                    }
                    kept += 1;
                } else {
                    std::ptr::drop_in_place(ptr.add(i));
                }
            }
        }
        self.inner.len.store(kept, Ordering::Release);
    }
}

impl<T> Clone for StableVec<T> {
    #[inline]
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
        }
    }
}

impl<T: std::fmt::Debug> std::fmt::Debug for StableVec<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("StableVec").field(&self.len()).finish()
    }
}

impl<T> std::ops::Deref for StableVec<T> {
    type Target = [T];
    #[inline]
    fn deref(&self) -> &[T] {
        let len = self.len();
        unsafe { std::slice::from_raw_parts(self.inner.ptr.as_ptr(), len) }
    }
}

impl<T> std::ops::DerefMut for StableVec<T> {
    /// LATENT UB: `&mut [T]` aliases Arc-shared memory. Kept for
    /// Index/IndexMut ergonomics at call sites that write disjoint
    /// fields under the picker write lock. See module-level doc.
    #[inline]
    fn deref_mut(&mut self) -> &mut [T] {
        let len = self.inner.len.load(Ordering::Acquire);
        unsafe { std::slice::from_raw_parts_mut(self.inner.ptr.as_ptr(), len) }
    }
}
