# To Clankers

This repository contains **FFS**, a high-performance file search CLI and MCP server
with tree-sitter powered code navigation. It provides typo-resistant fuzzy matching,
frecency scoring, and token-budget aware file reading for AI agents.

## Development Commands

Always prefer Makefile commands listed to cargo directly when possible.

### Building

- `make build` - build everything

### Testing

This project uses inline Rust unit tests embedded in modules for standalone,
scoped functionality.

### Code Quality

- `make lint` - Rust linting with clippy
- `make format` - Format Rust code with rustfmt
- `make test` - Run workspace tests

Keep comments concise: 1-2 lines maximum, 4 lines only for complex concepts.

## Architecture

```
ffs-cli     (Rust binary - commands)
ffs-mcp     (Rust binary - MCP server over stdio)
ffs-c       (C ABI library)
─────────────────────────────────────────
ffs-engine  (dispatch, ranking, memory)
ffs-grep    (SIMD search)
ffs-symbol  (tree-sitter index)
ffs-budget  (token-aware reader)
ffs-query-parser  (query DSL)
─────────────────────────────────────────
ffs-core    (scan, frecency, scoring, git, watcher)
```

## Crates

| Crate | Role |
|-------|------|
| `ffs-core` | Filesystem scan, frecency, fuzzy scoring, git integration, watcher |
| `ffs-query-parser` | Parses query DSL (globs, negations, regex, fuzzy fallback) |
| `ffs-symbol` | Tree-sitter symbol index, bloom filter, outline cache |
| `ffs-grep` | SIMD literal & regex content search |
| `ffs-budget` | Token-aware reader with filters |
| `ffs-engine` | Unified scanner, dispatch, ranking |
| `ffs-cli` | CLI commands (find, grep, symbol, read, map, etc.) |
| `ffs-mcp` | MCP server speaking JSON-RPC over stdio |
| `ffs-c` | C ABI library for external bindings |

## Build System

- `Cargo.toml` - Rust workspace and dependencies
- `rust-toolchain.toml` - Rust toolchain specification
- `Cross.toml` - Cross-compilation via Zig

## Important coding rules

- Prefer struct methods over functions
- If there are more than 2 impl blocks in a file, extract to a new file
- Do not add doc comments to private structs and functions
- Be very careful around locking - prefer RwLock over Mutex for read-heavy workloads

## Top level API that can not introduce breaking changes under any circumstance

Rust, C, and MCP APIs can not be changed under any circumstance
