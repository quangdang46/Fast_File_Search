PREFIX ?= /usr/local
LIBDIR ?= $(PREFIX)/lib
INCLUDEDIR ?= $(PREFIX)/include

# Compile-time cfg that gates the watcher + git-status fuzz stress test.
STRESS_RUSTFLAGS := --cfg stress
FFS_STRESS_DEFAULT_SEED ?= 0xDEADBEEFCAFEBABE

.PHONY: build build-c-lib install uninstall test test-rust header test-stress test-stress-seeded test-stress-random

all: format test lint

build:
	cargo build --release --features zlob

build-c-lib:
	cargo build --release -p ffs-c --features zlob

header:
	cbindgen --config crates/ffs-c/cbindgen.toml --crate ffs-c --output crates/ffs-c/include/ffs.h

# Install the C library and header under $(PREFIX) (default /usr/local).
# Override PREFIX for user-local installs, e.g. `make install PREFIX=$$HOME/.local`.
# DESTDIR is honoured for packagers.
install: build-c-lib
	install -d $(DESTDIR)$(LIBDIR)
	install -d $(DESTDIR)$(INCLUDEDIR)
	install -m 0644 crates/ffs-c/include/ffs.h $(DESTDIR)$(INCLUDEDIR)/ffs.h
	@if [ -f target/release/libffs_c.dylib ]; then \
		install -m 0755 target/release/libffs_c.dylib $(DESTDIR)$(LIBDIR)/libffs_c.dylib; \
		echo "Installed $(DESTDIR)$(LIBDIR)/libffs_c.dylib"; \
	fi
	@if [ -f target/release/libffs_c.so ]; then \
		install -m 0755 target/release/libffs_c.so $(DESTDIR)$(LIBDIR)/libffs_c.so; \
		echo "Installed $(DESTDIR)$(LIBDIR)/libffs_c.so"; \
	fi
	@if [ -f target/release/ffs_c.dll ]; then \
		install -m 0755 target/release/ffs_c.dll $(DESTDIR)$(LIBDIR)/ffs_c.dll; \
		echo "Installed $(DESTDIR)$(LIBDIR)/ffs_c.dll"; \
	fi
	@echo "Installed header $(DESTDIR)$(INCLUDEDIR)/ffs.h"

uninstall:
	rm -f $(DESTDIR)$(LIBDIR)/libffs_c.dylib
	rm -f $(DESTDIR)$(LIBDIR)/libffs_c.so
	rm -f $(DESTDIR)$(LIBDIR)/ffs_c.dll
	rm -f $(DESTDIR)$(INCLUDEDIR)/ffs.h
	@echo "Removed ffs-c from $(DESTDIR)$(PREFIX)"

test-rust:
	cargo test --workspace --features zlob

test-stress-seeded:
	FFS_STRESS_SEED="$${FFS_STRESS_SEED:-$(FFS_STRESS_DEFAULT_SEED)}" \
	RUSTFLAGS="$(STRESS_RUSTFLAGS)" \
	cargo test \
		-p ffs-core \
		--test fuzz_git_watcher_stress \
		--features zlob \
		-- --nocapture stress_seeded

test-stress-random:
	RUSTFLAGS="$(STRESS_RUSTFLAGS)" \
	cargo test \
		-p ffs-core \
		--test fuzz_git_watcher_stress \
		--features zlob \
		-- --nocapture stress_random

test-stress: test-stress-seeded test-stress-random

test: test-rust

format-rust:
	cargo fmt --all

format: format-rust

lint-rust:
	cargo clippy --workspace --features zlob -- -D warnings

lint: lint-rust

check: format lint

CRATES_TO_PUBLISH= ffs-grep ffs-query-parser ffs-budget ffs-engine

set-version:
	@test -n "$(V)" || (echo "V is required. Usage: make set-version V=0.2.0" && exit 1)
	cargo install cargo-edit
	cargo set-version $(V) || lua scripts/set-rust-version.lua "$(V)"

publish-crates:
	@test -n "$(V)" || (echo "V is required. Usage: make publish-crates V=0.2.0" && exit 1)
	$(MAKE) set-version V=$(V)
	@for crate in $(CRATES_TO_PUBLISH); do \
		cargo publish -p $$crate --allow-dirty $$(if [ -n "$$CI" ]; then echo "--no-verify"; fi) || exit 1; \
	done
