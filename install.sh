#!/usr/bin/env bash
# ffs installer — downloads the right native binary from GitHub Releases
# and atomically installs it to $DEST (default ~/.local/bin). By default
# also registers the `ffs mcp` subcommand with every detected MCP-capable
# AI assistant in one shot. Pass --no-mcp for binary-only.
#
#   curl -fsSL https://raw.githubusercontent.com/quangdang46/fast_file_search/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/quangdang46/fast_file_search/main/install.sh | bash -s -- --easy-mode
#   curl -fsSL https://raw.githubusercontent.com/quangdang46/fast_file_search/main/install.sh | bash -s -- --version v0.1.0
#   curl -fsSL https://raw.githubusercontent.com/quangdang46/fast_file_search/main/install.sh | bash -s -- --uninstall
#   curl -fsSL https://raw.githubusercontent.com/quangdang46/fast_file_search/main/install.sh | bash -s -- --no-mcp
#   curl -fsSL https://raw.githubusercontent.com/quangdang46/fast_file_search/main/install.sh | bash -s -- --mcp-only --mcp-providers cursor,opencode
#
# Flags (binary install):
#   --dest <dir>            install location (default ~/.local/bin)
#   --system                install to /usr/local/bin (needs sudo)
#   --version <tag>         pin to a specific release tag (e.g. v0.1.0); default: latest
#   --easy-mode             auto-append PATH export to ~/.bashrc and ~/.zshrc
#   --verify                run `ffs --version` after install as a self-test
#   --from-source           skip download, build with cargo (slow)
#   --quiet, -q             silence informational output
#   --uninstall             remove the binary and the easy-mode PATH lines
#   -h, --help              show this help and exit
#
# Flags (MCP registration; default ON):
#   --no-mcp                skip MCP registration entirely
#   --mcp                   force MCP registration on (default; kept for back-compat)
#   --mcp-only              skip binary install; only run MCP registration
#                           (assumes ffs is already on PATH or under --dest)
#   --mcp-providers <list>  restrict registration to a comma-separated subset
#                           (e.g. cursor,opencode). Default: all detected
#   --mcp-name <id>         server name written into MCP configs (default: ffs)
#   --mcp-dry-run           print the writes without touching any config file
#   --mcp-uninstall         remove the ffs MCP entry from every provider config
#                           (binary stays — pair with --uninstall to remove both)
#
# Detected providers: Claude Code, Codex, Cursor, Cline, OpenCode, Continue.
# Each is silently skipped when its CLI / config dir is not present, so the
# default-on flow is safe even on machines with no AI agents installed.
# Providers that need `jq` (Cursor, Cline, OpenCode) auto-skip when jq is
# missing — they don't fail the install.

set -euo pipefail
umask 022

# === Config ===
BINARY_NAME="ffs"
OWNER="quangdang46"
REPO="fast_file_search"
DEST="${DEST:-$HOME/.local/bin}"
VERSION="${VERSION:-}"
QUIET=0
EASY=0
VERIFY=0
FROM_SOURCE=0
UNINSTALL=0
MCP=1                    # default ON; --no-mcp to disable
MCP_ONLY=0
MCP_UNINSTALL=0
MCP_PROVIDERS="all"
MCP_DRY_RUN=0
MCP_NAME="ffs"
MAX_RETRIES=3
DOWNLOAD_TIMEOUT=120
LOCK_DIR="/tmp/${BINARY_NAME}-install.lock.d"
TMP=""

# === Logging ===
log_info()    { [ "$QUIET" -eq 1 ] && return 0; printf '[%s] %s\n' "$BINARY_NAME" "$*" >&2; }
log_warn()    { printf '[%s] WARN: %s\n' "$BINARY_NAME" "$*" >&2; }
log_success() { [ "$QUIET" -eq 1 ] && return 0; printf '\xE2\x9C\x93 %s\n' "$*" >&2; }
die()         { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# === Cleanup & lock ===
cleanup() { rm -rf "$TMP" "$LOCK_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid"
        return 0
    fi
    die "Another install is running. If stuck: rm -rf $LOCK_DIR"
}

# === Args ===
while [ $# -gt 0 ]; do
    case "$1" in
        --dest)            DEST="$2";          shift 2;;
        --dest=*)          DEST="${1#*=}";     shift;;
        --version)         VERSION="$2";       shift 2;;
        --version=*)       VERSION="${1#*=}";  shift;;
        --system)          DEST="/usr/local/bin"; shift;;
        --easy-mode)       EASY=1;             shift;;
        --verify)          VERIFY=1;           shift;;
        --from-source)     FROM_SOURCE=1;      shift;;
        --quiet|-q)        QUIET=1;            shift;;
        --uninstall)       UNINSTALL=1;        shift;;
        --mcp)             MCP=1;              shift;;
        --no-mcp)          MCP=0;              shift;;
        --mcp-only)        MCP=1; MCP_ONLY=1;  shift;;
        --mcp-uninstall)   MCP_UNINSTALL=1;    shift;;
        --mcp-providers)   MCP=1; MCP_PROVIDERS="$2"; shift 2;;
        --mcp-providers=*) MCP=1; MCP_PROVIDERS="${1#*=}"; shift;;
        --mcp-name)        MCP_NAME="$2";      shift 2;;
        --mcp-name=*)      MCP_NAME="${1#*=}"; shift;;
        --mcp-dry-run)     MCP=1; MCP_DRY_RUN=1; shift;;
        -h|--help)         usage;;
        *) log_warn "Unknown flag: $1"; shift;;
    esac
done

# === Uninstall path ===
do_uninstall() {
    local target="$DEST/$BINARY_NAME"
    if [ -f "$target" ]; then
        rm -f "$target"
        log_success "Removed $target"
    else
        log_warn "Not found at $target — nothing to remove"
    fi
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$rc" ] || continue
        sed -i.bak "/${BINARY_NAME} installer/d" "$rc" 2>/dev/null \
            || sed -i '' "/${BINARY_NAME} installer/d" "$rc" 2>/dev/null \
            || true
        rm -f "$rc.bak" 2>/dev/null || true
    done
    log_success "Uninstalled binary"
}

# === Platform → asset suffix ===
# The release.yaml uploads bare ffs binaries named ffs-<rust-triple>{.exe}.
# We prefer musl on Linux for portability across glibc versions.
detect_target() {
    local os arch
    case "$(uname -s)" in
        Linux*)               os="linux";;
        Darwin*)              os="darwin";;
        MINGW*|MSYS*|CYGWIN*) os="windows";;
        *) die "Unsupported OS: $(uname -s)";;
    esac
    case "$(uname -m)" in
        x86_64|amd64)   arch="x86_64";;
        aarch64|arm64)  arch="aarch64";;
        *) die "Unsupported arch: $(uname -m)";;
    esac

    case "${os}_${arch}" in
        linux_x86_64)    echo "x86_64-unknown-linux-musl";;
        linux_aarch64)   echo "aarch64-unknown-linux-musl";;
        darwin_x86_64)   echo "x86_64-apple-darwin";;
        darwin_aarch64)  echo "aarch64-apple-darwin";;
        windows_x86_64)  echo "x86_64-pc-windows-msvc";;
        windows_aarch64) echo "aarch64-pc-windows-msvc";;
        *) die "Unsupported platform: ${os}_${arch}";;
    esac
}

is_windows() { [[ "$(uname -s)" =~ ^(MINGW|MSYS|CYGWIN) ]]; }

# === Version resolution ===
resolve_version() {
    [ -n "$VERSION" ] && { log_info "Using pinned version: $VERSION"; return 0; }

    # 1st try: GitHub API
    VERSION=$(curl -fsSL --connect-timeout 10 --max-time 30 \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${OWNER}/${REPO}/releases/latest" 2>/dev/null \
        | grep '"tag_name":' | head -1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/') || true

    # 2nd fallback: redirect trick (works without API rate limit)
    if ! [[ "${VERSION:-}" =~ ^v[0-9] ]]; then
        VERSION=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
            "https://github.com/${OWNER}/${REPO}/releases/latest" 2>/dev/null \
            | sed -E 's|.*/tag/||') || true
    fi

    [[ "${VERSION:-}" =~ ^v[0-9] ]] || die "Could not resolve latest version"
    log_info "Latest version: $VERSION"
}

# === Download with retry/resume ===
download_file() {
    local url="$1" dest="$2"
    local partial="${dest}.part"
    local attempt=0
    local progress="-sS"
    [ "$QUIET" -eq 0 ] && [ -t 2 ] && progress="--progress-bar"

    while [ $attempt -lt $MAX_RETRIES ]; do
        attempt=$((attempt + 1))
        local resume=""
        [ -s "$partial" ] && resume="--continue-at -"
        # shellcheck disable=SC2086
        if curl -fL --connect-timeout 30 --max-time "$DOWNLOAD_TIMEOUT" \
                $progress --retry 2 $resume \
                -o "$partial" "$url"; then
            mv -f "$partial" "$dest"
            return 0
        fi
        [ $attempt -lt $MAX_RETRIES ] && { log_warn "Retrying in 3s ($attempt/$MAX_RETRIES)..."; sleep 3; }
    done
    rm -f "$partial" 2>/dev/null || true
    return 1
}

# === Atomic install ===
install_binary_atomic() {
    local src="$1" dst="$2"
    local tmp="${dst}.tmp.$$"
    install -m 0755 "$src" "$tmp" || { rm -f "$tmp"; die "install(1) failed"; }
    mv -f "$tmp" "$dst" || { rm -f "$tmp"; die "Failed to move into place"; }
}

# === sha256 verify ===
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        echo ""
    fi
}

verify_checksum() {
    local file="$1" checksum_file="$2"
    [ -f "$checksum_file" ] || return 0  # no sidecar = skip
    local expected actual
    expected=$(awk '{print $1}' "$checksum_file")
    actual=$(sha256_of "$file")
    if [ -z "$actual" ]; then
        log_warn "No sha256 tool available; skipping checksum verification"
        return 0
    fi
    [ "$expected" = "$actual" ] || die "Checksum mismatch (expected $expected, got $actual)"
    log_info "Checksum verified"
}

# === PATH ===
maybe_add_path() {
    case ":$PATH:" in *":$DEST:"*) return 0;; esac
    if [ "$EASY" -eq 1 ]; then
        local appended=0
        for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
            [ -f "$rc" ] && [ -w "$rc" ] || continue
            grep -qF "$DEST" "$rc" && continue
            printf '\nexport PATH="%s:$PATH"  # %s installer\n' "$DEST" "$BINARY_NAME" >> "$rc"
            appended=1
            log_info "Added PATH export to $rc"
        done
        if [ $appended -eq 1 ]; then
            log_warn "Restart your shell or run: export PATH=\"$DEST:\$PATH\""
        fi
    else
        log_warn "Not on PATH. Add to your shell rc, or rerun with --easy-mode:"
        log_warn "  export PATH=\"$DEST:\$PATH\""
    fi
}

# === From-source build ===
build_from_source() {
    command -v cargo >/dev/null 2>&1 \
        || die "cargo not found. Install Rust: https://rustup.rs"
    command -v git >/dev/null 2>&1 \
        || die "git not found"

    log_info "Cloning ${OWNER}/${REPO}..."
    git clone --depth 1 "https://github.com/${OWNER}/${REPO}.git" "$TMP/src"

    log_info "Building (this may take several minutes)..."
    (cd "$TMP/src" && CARGO_TARGET_DIR="$TMP/target" \
        cargo build --release --locked -p ffs-cli)

    install_binary_atomic "$TMP/target/release/$BINARY_NAME" "$DEST/$BINARY_NAME"
    log_success "Built from source: $DEST/$BINARY_NAME"
}

# === MCP registration ===========================================
#
# Inlined from the legacy install-mcp.sh. Six providers; for each, we
# detect installation, then merge `command=$DEST/ffs args=["mcp"]` into
# the provider's MCP config. Idempotent — re-runs do not duplicate or
# clobber unrelated entries.

# Resolve the absolute path of the ffs binary we should register. Prefer
# the binary at $DEST (just installed); fall back to whatever's on PATH.
mcp_ffs_command() {
    if [ -x "$DEST/$BINARY_NAME" ]; then
        printf '%s' "$DEST/$BINARY_NAME"
    elif command -v "$BINARY_NAME" >/dev/null 2>&1; then
        command -v "$BINARY_NAME"
    else
        printf '%s' "$DEST/$BINARY_NAME"
    fi
}

mcp_require_jq() {
    command -v jq >/dev/null 2>&1
}

# Atomic JSON merge: read source (or default to {}), apply jq filter, write back.
# Returns non-zero (and skips with a warning) when jq is missing — callers can
# treat that as "skip this provider" rather than aborting the whole install.
mcp_jq_merge() {
    local file="$1" filter="$2"
    if ! mcp_require_jq; then
        log_warn "jq not installed — skipping $file (install jq via apt-get/brew/dnf to enable)"
        return 1
    fi
    mkdir -p "$(dirname "$file")"
    local existing="{}"
    [ -f "$file" ] && existing="$(cat "$file")"
    local merged
    if ! merged=$(printf '%s' "$existing" | jq "$filter"); then
        log_warn "jq merge failed for $file — skipping"
        return 1
    fi
    if [ "$MCP_DRY_RUN" -eq 1 ]; then
        log_info "[mcp dry-run] would write $file:"
        printf '%s\n' "$merged"
    else
        printf '%s\n' "$merged" > "$file"
        log_success "[mcp] wrote $file"
    fi
}

# Selectively remove a key inside an MCP config file.
mcp_jq_unset() {
    local file="$1" filter="$2"
    [ -f "$file" ] || return 0
    if ! mcp_require_jq; then
        log_warn "jq not installed — skipping cleanup of $file"
        return 1
    fi
    local merged
    if ! merged=$(jq "$filter" "$file"); then
        log_warn "jq unset failed for $file — skipping"
        return 1
    fi
    if [ "$MCP_DRY_RUN" -eq 1 ]; then
        log_info "[mcp dry-run] would remove ${MCP_NAME} from $file"
    else
        printf '%s\n' "$merged" > "$file"
        log_success "[mcp] removed ${MCP_NAME} from $file"
    fi
}

# --- Claude Code (CLI-managed) ---
mcp_register_claude() {
    command -v claude >/dev/null 2>&1 || { log_info "claude CLI not detected — skipping Claude Code"; return; }
    local cmd; cmd=$(mcp_ffs_command)
    if [ "$MCP_DRY_RUN" -eq 1 ]; then
        log_info "[mcp dry-run] claude mcp add -s user $MCP_NAME -- $cmd mcp"
        return
    fi
    claude mcp remove -s user "$MCP_NAME" >/dev/null 2>&1 || true
    if claude mcp add -s user "$MCP_NAME" -- "$cmd" mcp >/dev/null 2>&1; then
        log_success "[mcp] registered with Claude Code"
    else
        log_warn "claude mcp add failed; falling back to ~/.claude.json edit"
        mcp_jq_merge "$HOME/.claude.json" \
            ".mcpServers[\"$MCP_NAME\"] = {\"type\":\"stdio\",\"command\":\"$cmd\",\"args\":[\"mcp\"]}"
    fi
}

mcp_unregister_claude() {
    command -v claude >/dev/null 2>&1 || return
    if [ "$MCP_DRY_RUN" -eq 1 ]; then
        log_info "[mcp dry-run] claude mcp remove -s user $MCP_NAME"
        return
    fi
    claude mcp remove -s user "$MCP_NAME" >/dev/null 2>&1 \
        && log_success "[mcp] removed ${MCP_NAME} from Claude Code"
}

# --- Codex (CLI-managed) ---
mcp_register_codex() {
    command -v codex >/dev/null 2>&1 || { log_info "codex CLI not detected — skipping Codex"; return; }
    local cmd; cmd=$(mcp_ffs_command)
    if [ "$MCP_DRY_RUN" -eq 1 ]; then
        log_info "[mcp dry-run] codex mcp add $MCP_NAME -- $cmd mcp"
        return
    fi
    codex mcp remove "$MCP_NAME" >/dev/null 2>&1 || true
    if codex mcp add "$MCP_NAME" -- "$cmd" mcp >/dev/null 2>&1; then
        log_success "[mcp] registered with Codex"
    else
        log_warn "codex mcp add failed; check ~/.codex/config.toml manually"
    fi
}

mcp_unregister_codex() {
    command -v codex >/dev/null 2>&1 || return
    if [ "$MCP_DRY_RUN" -eq 1 ]; then
        log_info "[mcp dry-run] codex mcp remove $MCP_NAME"
        return
    fi
    codex mcp remove "$MCP_NAME" >/dev/null 2>&1 \
        && log_success "[mcp] removed ${MCP_NAME} from Codex"
}

# --- Cursor (~/.cursor/mcp.json) ---
mcp_register_cursor() {
    if [ ! -d "$HOME/.cursor" ] && ! command -v cursor >/dev/null 2>&1; then
        log_info "Cursor not detected — skipping"
        return
    fi
    local cmd; cmd=$(mcp_ffs_command)
    mcp_jq_merge "$HOME/.cursor/mcp.json" \
        ".mcpServers = (.mcpServers // {}) | .mcpServers[\"$MCP_NAME\"] = {\"command\":\"$cmd\",\"args\":[\"mcp\"],\"type\":\"stdio\"}"
}

mcp_unregister_cursor() {
    mcp_jq_unset "$HOME/.cursor/mcp.json" "del(.mcpServers[\"$MCP_NAME\"])"
}

# --- Cline (VSCode extension storage) ---
mcp_cline_settings_path() {
    if [ -n "${CLINE_MCP_SETTINGS:-}" ]; then
        printf '%s' "$CLINE_MCP_SETTINGS"; return
    fi
    local base
    case "$(uname -s)" in
        Darwin)               base="$HOME/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings" ;;
        MINGW*|MSYS*|CYGWIN*) base="${APPDATA:-$HOME}/Code/User/globalStorage/saoudrizwan.claude-dev/settings" ;;
        *)                    base="$HOME/.config/Code/User/globalStorage/saoudrizwan.claude-dev/settings" ;;
    esac
    printf '%s' "$base/cline_mcp_settings.json"
}

mcp_register_cline() {
    local cfg; cfg="$(mcp_cline_settings_path)"
    if [ ! -d "$(dirname "$cfg")" ] && [ -z "${CLINE_MCP_SETTINGS:-}" ]; then
        log_info "Cline storage dir not found — skipping (set CLINE_MCP_SETTINGS to override)"
        return
    fi
    local cmd; cmd=$(mcp_ffs_command)
    mcp_jq_merge "$cfg" \
        ".mcpServers = (.mcpServers // {}) | .mcpServers[\"$MCP_NAME\"] = {\"command\":\"$cmd\",\"args\":[\"mcp\"],\"transportType\":\"stdio\"}"
}

mcp_unregister_cline() {
    mcp_jq_unset "$(mcp_cline_settings_path)" "del(.mcpServers[\"$MCP_NAME\"])"
}

# --- OpenCode (~/.config/opencode/opencode.json) ---
mcp_register_opencode() {
    if ! command -v opencode >/dev/null 2>&1 && [ ! -d "$HOME/.config/opencode" ]; then
        log_info "OpenCode not detected — skipping"
        return
    fi
    local cmd; cmd=$(mcp_ffs_command)
    mcp_jq_merge "$HOME/.config/opencode/opencode.json" \
        ".mcp = (.mcp // {}) | .mcp[\"$MCP_NAME\"] = {\"type\":\"local\",\"command\":[\"$cmd\",\"mcp\"],\"enabled\":true}"
}

mcp_unregister_opencode() {
    mcp_jq_unset "$HOME/.config/opencode/opencode.json" "del(.mcp[\"$MCP_NAME\"])"
}

# --- Continue (~/.continue/mcpServers/<name>.yaml) ---
mcp_register_continue() {
    if [ ! -d "$HOME/.continue" ]; then
        log_info "Continue not detected — skipping"
        return
    fi
    local dir="$HOME/.continue/mcpServers"
    local file="${dir}/${MCP_NAME}.yaml"
    local cmd; cmd=$(mcp_ffs_command)
    local body
    body=$(cat <<EOF
name: ${MCP_NAME}
version: 0.0.1
schema: v1
mcpServers:
  - name: ${MCP_NAME}
    command: ${cmd}
    args:
      - mcp
EOF
)
    if [ "$MCP_DRY_RUN" -eq 1 ]; then
        log_info "[mcp dry-run] would write $file:"
        printf '%s\n' "$body"
    else
        mkdir -p "$dir"
        printf '%s\n' "$body" > "$file"
        log_success "[mcp] wrote $file"
    fi
}

mcp_unregister_continue() {
    local file="$HOME/.continue/mcpServers/${MCP_NAME}.yaml"
    [ -f "$file" ] || return 0
    if [ "$MCP_DRY_RUN" -eq 1 ]; then
        log_info "[mcp dry-run] would delete $file"
    else
        rm -f "$file"
        log_success "[mcp] deleted $file"
    fi
}

mcp_provider_list() {
    if [ "$MCP_PROVIDERS" = "all" ]; then
        echo "claude codex cursor cline opencode continue"
    else
        echo "$MCP_PROVIDERS" | tr ',' ' '
    fi
}

mcp_run_provider() {
    local provider="$1" action="$2"
    case "$provider:$action" in
        claude:register)   mcp_register_claude ;;
        claude:remove)     mcp_unregister_claude ;;
        codex:register)    mcp_register_codex ;;
        codex:remove)      mcp_unregister_codex ;;
        cursor:register)   mcp_register_cursor ;;
        cursor:remove)     mcp_unregister_cursor ;;
        cline:register)    mcp_register_cline ;;
        cline:remove)      mcp_unregister_cline ;;
        opencode:register) mcp_register_opencode ;;
        opencode:remove)   mcp_unregister_opencode ;;
        continue:register) mcp_register_continue ;;
        continue:remove)   mcp_unregister_continue ;;
        *) log_warn "unknown MCP provider: $provider" ;;
    esac
}

do_mcp_register() {
    log_info "Registering '$MCP_NAME' with MCP providers ($MCP_PROVIDERS)..."
    for p in $(mcp_provider_list); do mcp_run_provider "$p" register; done
}

do_mcp_uninstall() {
    log_info "Removing '$MCP_NAME' from MCP providers ($MCP_PROVIDERS)..."
    for p in $(mcp_provider_list); do mcp_run_provider "$p" remove; done
}

# === Main ===
main() {
    acquire_lock
    TMP=$(mktemp -d)

    # Uninstall short-circuits — supports --uninstall, --mcp-uninstall, or both.
    if [ "$UNINSTALL" -eq 1 ] || [ "$MCP_UNINSTALL" -eq 1 ]; then
        [ "$MCP_UNINSTALL" -eq 1 ] && do_mcp_uninstall
        [ "$UNINSTALL" -eq 1 ] && do_uninstall
        exit 0
    fi

    if [ "$MCP_ONLY" -eq 1 ]; then
        log_info "Skipping binary install (--mcp-only)"
    else
        mkdir -p "$DEST"

        if [ "$FROM_SOURCE" -eq 1 ]; then
            build_from_source
        else
            local target asset url
            target=$(detect_target)
            log_info "Detected target: $target | Dest: $DEST"

            resolve_version

            if is_windows; then
                asset="ffs-${target}.exe"
            else
                asset="ffs-${target}"
            fi
            url="https://github.com/${OWNER}/${REPO}/releases/download/${VERSION}/${asset}"

            log_info "Downloading $asset..."
            if download_file "$url" "$TMP/$asset"; then
                # Try sha256 sidecar; non-fatal if missing.
                download_file "${url}.sha256" "$TMP/${asset}.sha256" 2>/dev/null \
                    && verify_checksum "$TMP/$asset" "$TMP/${asset}.sha256" \
                    || log_warn "No sha256 sidecar at ${url}.sha256 — skipping verification"

                local install_name="$BINARY_NAME"
                is_windows && install_name="${BINARY_NAME}.exe"
                install_binary_atomic "$TMP/$asset" "$DEST/$install_name"
                log_success "Installed $DEST/$install_name"
            else
                log_warn "Binary download failed — falling back to from-source build"
                build_from_source
            fi
        fi

        maybe_add_path

        if [ "$VERIFY" -eq 1 ]; then
            log_info "Running self-test..."
            "$DEST/$BINARY_NAME" --version || die "Self-test failed"
        fi
    fi

    if [ "$MCP" -eq 1 ]; then
        do_mcp_register
    fi

    # The summary footer is opt-out via --quiet; the conditional `echo` for the
    # MCP line must NOT be the final statement of the function — with `set -e`
    # a falsy short-circuit would propagate as a non-zero exit code even after
    # a successful install.
    if [ "$QUIET" -eq 0 ]; then
        echo ""
        if [ "$MCP_ONLY" -eq 1 ]; then
            echo "ffs MCP registration complete."
        else
            echo "ffs installed to $DEST/$BINARY_NAME"
            "$DEST/$BINARY_NAME" --version 2>/dev/null || true
        fi
        echo ""
        echo "Quick start:"
        echo "  ffs --help"
        echo "  ffs index           # one-time warm-up"
        echo "  ffs find <query>"
        echo "  ffs grep <pattern>"
        echo "  ffs symbol <name>"
        if [ "$MCP" -eq 1 ]; then
            echo "  ffs mcp             # MCP server (registered with detected agents)"
        fi
    fi
    return 0
}

# curl|bash safety: buffer the whole script before running so a truncated
# pipe can't half-execute the installer.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]] || [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    { main "$@"; }
fi
