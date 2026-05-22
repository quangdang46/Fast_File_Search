#Requires -Version 5.1
<#
.SYNOPSIS
    ffs installer for Windows — downloads the right binary from GitHub Releases
    and optionally registers ffs as an MCP server with detected AI assistants.
.DESCRIPTION
    Pipe usage (no parameters — uses defaults or env-var overrides):
        irm https://raw.githubusercontent.com/quangdang46/fast_file_search/main/install.ps1 | iex

    Direct usage (supports all parameters):
        iwr https://raw.githubusercontent.com/quangdang46/fast_file_search/main/install.ps1 -OutFile install.ps1
        .\install.ps1 -Version v0.7.3 -EasyMode

    Env-var fallbacks (for the piped form):
        $env:FFS_VERSION          - pin a specific release tag
        $env:FFS_INSTALL_DIR      - override install directory
        $env:FFS_PATH_SCOPE       - User | Profile | None
        $env:FFS_NO_MCP           - set to '1' to skip MCP registration
        $env:FFS_MCP_ONLY         - set to '1' for MCP-only (skip binary install)
        $env:FFS_MCP_PROVIDERS    - comma-separated list (default: all detected)
        $env:FFS_MCP_NAME         - server name (default: ffs)

.PARAMETER Version
    Release tag to install (e.g. 'v0.7.3'). Default: latest.
.PARAMETER InstallDir
    Target directory. Default: $env:LOCALAPPDATA\ffs\bin.
.PARAMETER PathScope
    How to persist PATH: 'User' (default), 'Profile' (append to $PROFILE), 'None'.
.PARAMETER EasyMode
    Persist PATH and verify after install.
.PARAMETER Verify
    Run ffs --version after install as a self-test.
.PARAMETER Uninstall
    Remove the ffs binary and PATH entries.
.PARAMETER NoMcp
    Skip MCP registration.
.PARAMETER McpOnly
    Skip binary install; only register MCP (assumes ffs is on PATH or in -InstallDir).
.PARAMETER McpProviders
    Comma-separated list of MCP providers to register with. Default: all detected.
.PARAMETER McpName
    Server name written into MCP configs. Default: ffs.
.PARAMETER McpDryRun
    Print MCP config writes without touching files.
.PARAMETER McpUninstall
    Remove the ffs MCP entry from every provider config.
#>
param(
    [string]$Version      = $env:FFS_VERSION,
    [string]$InstallDir   = $env:FFS_INSTALL_DIR,
    [ValidateSet('User', 'Profile', 'None', '')]
    [string]$PathScope,
    [switch]$EasyMode,
    [switch]$Verify,
    [switch]$Uninstall,
    [switch]$NoMcp,
    [switch]$McpOnly,
    [string]$McpProviders = $env:FFS_MCP_PROVIDERS,
    [string]$McpName      = $env:FFS_MCP_NAME,
    [switch]$McpDryRun,
    [switch]$McpUninstall
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# === Defaults ===
$Owner      = 'quangdang46'
$Repo       = 'fast_file_search'
$BinaryName = 'ffs'
if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'ffs\bin' }
if (-not $PathScope) {
    $PathScope = if ($env:FFS_PATH_SCOPE) { $env:FFS_PATH_SCOPE }
                 elseif ($EasyMode)       { 'User' }
                 else                     { 'User' }
}
if (-not $McpName) { $McpName = 'ffs' }
if (-not $McpProviders) { $McpProviders = 'all' }

# === Logging ===
function Write-Info    { param($m) Write-Host "[$BinaryName] $m" }
function Write-Success { param($m) Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Warn    { param($m) Write-Host "[$BinaryName] WARN: $m" -ForegroundColor Yellow }

# Run a native command, swallow all output, and prevent PowerShell 5.1's
# `NativeCommandError` from terminating the script under `Stop`. Returns
# `$LASTEXITCODE`. `2>$null` alone is not enough: PS 5.1 still surfaces a
# `RemoteException` (red text) and, with `$ErrorActionPreference = 'Stop'`,
# aborts the script the first time a native exe writes to stderr.
function Invoke-Quiet {
    param([Parameter(Mandatory)][scriptblock]$Block)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try { & $Block 2>&1 | Out-Null } finally { $ErrorActionPreference = $prev }
    return $LASTEXITCODE
}

# === Platform detection ===
function Get-Target {
    $arch = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE
    switch ($arch) {
        'AMD64' { return 'x86_64-pc-windows-msvc' }
        'ARM64' { return 'aarch64-pc-windows-msvc' }
        default { throw "Unsupported architecture: $arch" }
    }
}

# === Version resolution ===
function Resolve-LatestVersion {
    $headers = @{ 'User-Agent' = 'ffs-installer' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }

    # Try GitHub API first
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/releases/latest" -Headers $headers
        if ($release.tag_name -match '^v[\d]') { return $release.tag_name }
    } catch {}

    # Fallback: redirect trick
    try {
        $resp = Invoke-WebRequest -Uri "https://github.com/$Owner/$Repo/releases/latest" -MaximumRedirection 0 -ErrorAction SilentlyContinue -UseBasicParsing
        $loc = $resp.Headers.Location
        if (-not $loc) { $loc = $resp.Headers['Location'] }
        if ($loc -match '/tag/(v[\d].+)$') { return $Matches[1] }
    } catch {
        $loc = $_.Exception.Response.Headers.Location
        if ($loc -and "$loc" -match '/tag/(v[\d].+)$') { return $Matches[1] }
    }

    throw "Could not resolve latest version. Pass -Version explicitly."
}

# === Download helper ===
function Invoke-Download {
    param([string]$Url, [string]$OutFile)
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source -fsSL --retry 3 --connect-timeout 30 --max-time 120 -o $OutFile $Url
        if ($LASTEXITCODE -ne 0) { throw "curl.exe exited with $LASTEXITCODE for $Url" }
    } else {
        $prev = $ProgressPreference
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
        } finally {
            $ProgressPreference = $prev
        }
    }
}

# === SHA256 verification ===
function Test-Checksum {
    param([string]$File, [string]$ChecksumFile)
    if (-not (Test-Path $ChecksumFile)) { return }
    $expected = (Get-Content $ChecksumFile -Raw).Trim().Split(' ')[0]
    $actual = (Get-FileHash $File -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) {
        throw "Checksum mismatch! Expected $expected, got $actual"
    }
    Write-Info "Checksum verified."
}

# === PATH management ===
function Test-OnPath {
    param([string]$Dir)
    $paths = $env:PATH -split ';'
    return ($paths -contains $Dir) -or ($paths -contains $Dir.TrimEnd('\'))
}

function Add-ToUserPath {
    param([string]$Dir)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    $entries = $userPath -split ';' | Where-Object { $_ -ne '' -and $_ -ne $Dir -and $_ -ne $Dir.TrimEnd('\') }
    # Prepend rather than append so the freshly installed binary always wins
    # PATH resolution. Appending leaves us shadowed by any stale `ffs.exe` (or
    # zero-byte WindowsApps stub) earlier on PATH, which is the classic cause
    # of "not a valid application for this OS platform" right after install.
    $newPath = (@(@($Dir) + $entries) -join ';')
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Success "Added $Dir to user PATH (prepended)."
}

function Add-ToProfilePath {
    param([string]$Dir)
    $profilePath = $PROFILE.CurrentUserAllHosts
    $line = "`$env:PATH += `";$Dir`"  # ffs installer"
    if (Test-Path $profilePath) {
        $existing = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
        if ($existing -and $existing.Contains($Dir)) { return }
    } else {
        New-Item -ItemType File -Force -Path $profilePath | Out-Null
    }
    Add-Content -Path $profilePath -Value "`n$line"
    Write-Success "Appended PATH update to $profilePath."
}

function Set-PathPersistence {
    param([string]$Dir, [string]$Scope)
    switch ($Scope) {
        'User'    { Add-ToUserPath $Dir }
        'Profile' { Add-ToProfilePath $Dir }
        'None'    { Write-Info "Skipping PATH persistence (-PathScope None)." }
    }
    # Mirror the prepend in the *current* session so the rest of this script
    # (and the user's next command, if they don't open a new shell) resolves
    # `ffs` to the binary we just wrote.
    if (-not (Test-OnPath $Dir)) { $env:PATH = "$Dir;$env:PATH" }
}

# === Uninstall ===
function Invoke-Uninstall {
    $target = Join-Path $InstallDir "$BinaryName.exe"
    if (Test-Path $target) {
        Remove-Item -Force $target
        Write-Success "Removed $target"
    } else {
        Write-Warn "Not found at $target"
    }
    # Remove from user PATH
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) {
        $entries = $userPath -split ';' | Where-Object { $_ -ne $InstallDir -and $_ -ne $InstallDir.TrimEnd('\') -and $_ -ne '' }
        [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
    }
    # Remove from profile
    $profilePath = $PROFILE.CurrentUserAllHosts
    if (Test-Path $profilePath) {
        $content = Get-Content $profilePath | Where-Object { $_ -notmatch 'ffs installer' }
        Set-Content -Path $profilePath -Value $content
    }
}

# === MCP registration ===
function Get-McpFfsCommand {
    $path = Join-Path $InstallDir "$BinaryName.exe"
    if (Test-Path $path) { return $path }
    $onPath = Get-Command $BinaryName -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $path
}

function Test-HasJq {
    return [bool](Get-Command jq -ErrorAction SilentlyContinue)
}

function Invoke-JqMerge {
    param([string]$File, [string]$Filter)
    if (-not (Test-HasJq)) {
        Write-Warn "jq not installed - skipping $File"
        return
    }
    $dir = Split-Path $File -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $existing = '{}'
    if (Test-Path $File) { $existing = Get-Content $File -Raw }
    if (-not $existing -or $existing.Trim() -eq '') { $existing = '{}' }

    $merged = $existing | & jq $Filter 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "jq merge failed for $File"
        return
    }
    if ($McpDryRun) {
        Write-Info "[mcp dry-run] would write $File"
        Write-Host $merged
    } else {
        Set-Content -Path $File -Value $merged -Encoding UTF8
        Write-Success "[mcp] wrote $File"
    }
}

function Register-McpClaude {
    $claude = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claude) { Write-Info "claude CLI not detected - skipping Claude Code"; return }
    $cmd = Get-McpFfsCommand
    if ($McpDryRun) {
        Write-Info "[mcp dry-run] claude mcp add -s user $McpName -- $cmd mcp"
        return
    }
    [void](Invoke-Quiet { & claude mcp remove -s user $McpName })
    $rc = Invoke-Quiet { & claude mcp add -s user $McpName -- $cmd mcp }
    if ($rc -eq 0) {
        Write-Success "[mcp] registered with Claude Code"
    } else {
        Write-Warn "claude mcp add failed (exit $rc)"
    }
}

function Register-McpCodex {
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codex) { Write-Info "codex CLI not detected - skipping Codex"; return }
    $cmd = Get-McpFfsCommand
    if ($McpDryRun) {
        Write-Info "[mcp dry-run] codex mcp add $McpName -- $cmd mcp"
        return
    }
    [void](Invoke-Quiet { & codex mcp remove $McpName })
    $rc = Invoke-Quiet { & codex mcp add $McpName -- $cmd mcp }
    if ($rc -eq 0) {
        Write-Success "[mcp] registered with Codex"
    } else {
        Write-Warn "codex mcp add failed (exit $rc)"
    }
}

function Register-McpCursor {
    $cursorDir = Join-Path $env:USERPROFILE '.cursor'
    if (-not (Test-Path $cursorDir) -and -not (Get-Command cursor -ErrorAction SilentlyContinue)) {
        Write-Info "Cursor not detected - skipping"
        return
    }
    $cmd = Get-McpFfsCommand
    $file = Join-Path $cursorDir 'mcp.json'
    Invoke-JqMerge -File $file -Filter ".mcpServers = (.mcpServers // {}) | .mcpServers[\`"$McpName\`"] = {\`"command\`":\`"$($cmd -replace '\\', '\\\\')\`",\`"args\`":[\`"mcp\`"],\`"type\`":\`"stdio\`"}"
}

function Register-McpCline {
    $base = Join-Path $env:APPDATA 'Code\User\globalStorage\saoudrizwan.claude-dev\settings'
    $file = Join-Path $base 'cline_mcp_settings.json'
    if (-not (Test-Path (Split-Path $file -Parent))) {
        Write-Info "Cline storage dir not found - skipping"
        return
    }
    $cmd = Get-McpFfsCommand
    Invoke-JqMerge -File $file -Filter ".mcpServers = (.mcpServers // {}) | .mcpServers[\`"$McpName\`"] = {\`"command\`":\`"$($cmd -replace '\\', '\\\\')\`",\`"args\`":[\`"mcp\`"],\`"transportType\`":\`"stdio\`"}"
}

function Register-McpOpenCode {
    $dir = Join-Path $env:USERPROFILE '.config\opencode'
    if (-not (Get-Command opencode -ErrorAction SilentlyContinue) -and -not (Test-Path $dir)) {
        Write-Info "OpenCode not detected - skipping"
        return
    }
    $cmd = Get-McpFfsCommand
    $file = Join-Path $dir 'opencode.json'
    Invoke-JqMerge -File $file -Filter ".mcp = (.mcp // {}) | .mcp[\`"$McpName\`"] = {\`"type\`":\`"local\`",\`"command\`":[\`"$($cmd -replace '\\', '\\\\')\`",\`"mcp\`"],\`"enabled\`":true}"
}

function Register-McpContinue {
    $continueDir = Join-Path $env:USERPROFILE '.continue'
    if (-not (Test-Path $continueDir)) {
        Write-Info "Continue not detected - skipping"
        return
    }
    $dir = Join-Path $continueDir 'mcpServers'
    $file = Join-Path $dir "$McpName.yaml"
    $cmd = Get-McpFfsCommand
    $body = @"
name: $McpName
version: 0.0.1
schema: v1
mcpServers:
  - name: $McpName
    command: $cmd
    args:
      - mcp
"@
    if ($McpDryRun) {
        Write-Info "[mcp dry-run] would write $file"
        Write-Host $body
    } else {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Set-Content -Path $file -Value $body -Encoding UTF8
        Write-Success "[mcp] wrote $file"
    }
}

function Invoke-McpRegistration {
    $providers = if ($McpProviders -eq 'all') {
        @('claude', 'codex', 'cursor', 'cline', 'opencode', 'continue')
    } else {
        $McpProviders -split ','
    }
    Write-Info "Registering '$McpName' with MCP providers ($($providers -join ', '))..."
    foreach ($p in $providers) {
        switch ($p.Trim()) {
            'claude'   { Register-McpClaude }
            'codex'    { Register-McpCodex }
            'cursor'   { Register-McpCursor }
            'cline'    { Register-McpCline }
            'opencode' { Register-McpOpenCode }
            'continue' { Register-McpContinue }
            default    { Write-Warn "Unknown MCP provider: $p" }
        }
    }
}

function Invoke-McpUninstall {
    Write-Info "Removing '$McpName' from MCP providers..."
    # Claude
    if (Get-Command claude -ErrorAction SilentlyContinue) {
        [void](Invoke-Quiet { & claude mcp remove -s user $McpName })
        Write-Success "[mcp] removed $McpName from Claude Code"
    }
    # Codex
    if (Get-Command codex -ErrorAction SilentlyContinue) {
        [void](Invoke-Quiet { & codex mcp remove $McpName })
        Write-Success "[mcp] removed $McpName from Codex"
    }
    # Cursor
    $cursorMcp = Join-Path $env:USERPROFILE '.cursor\mcp.json'
    if ((Test-Path $cursorMcp) -and (Test-HasJq)) {
        Get-Content $cursorMcp -Raw | & jq "del(.mcpServers[\`"$McpName\`"])" | Set-Content $cursorMcp -Encoding UTF8
    }
    # Continue
    $continueFile = Join-Path $env:USERPROFILE ".continue\mcpServers\$McpName.yaml"
    if (Test-Path $continueFile) { Remove-Item -Force $continueFile }
}

# === Main ===
function Main {
    # Uninstall short-circuits
    if ($Uninstall -or $McpUninstall) {
        if ($McpUninstall) { Invoke-McpUninstall }
        if ($Uninstall) { Invoke-Uninstall }
        return
    }

    if (-not $McpOnly) {
        $target = Get-Target
        Write-Info "Detected platform: $target"

        # Resolve version
        if ($Version) {
            $tag = $Version
            Write-Info "Using pinned version: $tag"
        } else {
            $tag = Resolve-LatestVersion
            Write-Info "Latest version: $tag"
        }

        # Download
        $asset = "ffs-$target.exe"
        $url = "https://github.com/$Owner/$Repo/releases/download/$tag/$asset"
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            $tmpFile = Join-Path $tmp $asset
            Write-Info "Downloading $asset..."
            try {
                Invoke-Download -Url $url -OutFile $tmpFile
            } catch {
                Write-Host ""
                Write-Host "Error: Failed to download binary." -ForegroundColor Red
                Write-Host "  URL: $url"
                Write-Host "  Platform: $target"
                Write-Host "  Release: $tag"
                Write-Host "Check available releases: https://github.com/$Owner/$Repo/releases"
                throw
            }

            # SHA256 verification
            $sha256File = Join-Path $tmp "$asset.sha256"
            try {
                Invoke-Download -Url "$url.sha256" -OutFile $sha256File
                Test-Checksum -File $tmpFile -ChecksumFile $sha256File
            } catch {
                Write-Warn "No sha256 sidecar or verification failed - skipping checksum"
            }

            # Install. Atomic-ish: stage as `<dest>.tmp.<pid>` *inside* the
            # destination directory (same volume, so Move-Item is a rename,
            # never a copy-and-delete that an AV scanner could intercept
            # mid-write), then atomically rename onto the final path.
            New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
            $dest = Join-Path $InstallDir "$BinaryName.exe"
            $stage = "$dest.tmp.$PID"
            if (Test-Path $stage) { Remove-Item -Force $stage }
            Copy-Item -LiteralPath $tmpFile -Destination $stage -Force
            try {
                Move-Item -LiteralPath $stage -Destination $dest -Force
            } catch {
                Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
                throw
            }
            # Strip the Zone.Identifier ADS so SmartScreen / WDAC doesn't
            # block downstream invocations with a generic "not a valid
            # application for this OS platform" error.
            try { Unblock-File -LiteralPath $dest -ErrorAction SilentlyContinue } catch {}
            Write-Success "Installed $dest"

            # Fail loudly if Defender / an EDR has already replaced the
            # file with a quarantine stub. The published Windows asset is
            # ~35 MB; anything dramatically smaller is almost certainly a
            # stub or a truncated download.
            $installed = Get-Item -LiteralPath $dest
            if ($installed.Length -lt 1MB) {
                throw "Installed $dest is only $($installed.Length) bytes - this is almost certainly an antivirus quarantine stub. Check Get-MpThreatDetection or your EDR console, then add an exclusion for $InstallDir and re-run the installer."
            }
            # Quick PE-header sanity check: byte 0/1 must be 'MZ' (0x4D 0x5A).
            $head = [System.IO.File]::ReadAllBytes($dest)[0..1]
            if (-not ($head[0] -eq 0x4D -and $head[1] -eq 0x5A)) {
                throw "Installed $dest does not have a valid PE header (first bytes: $('{0:X2}{1:X2}' -f $head[0], $head[1])). The download was corrupted or modified post-install."
            }
        } finally {
            Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        }

        Set-PathPersistence -Dir $InstallDir -Scope $PathScope

        # Always run a self-test. The cost is a single `--version` invocation;
        # the benefit is that we catch the "installed but won't run" failure
        # mode (AV quarantine, WindowsApps stub shadowing, wrong-arch binary,
        # Mark-of-the-Web blocking) *before* the script exits and the user is
        # left staring at a confusing error from their next prompt.
        Write-Info "Running self-test..."
        $selfTest = & $dest --version 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $selfTest) {
            Write-Host ""
            Write-Host "Self-test FAILED for $dest" -ForegroundColor Red
            Write-Host "  Output: $selfTest"
            try {
                $f = Get-Item -LiteralPath $dest
                $h = [System.IO.File]::ReadAllBytes($dest)[0..1]
                Write-Host "  File size: $($f.Length) bytes"
                Write-Host "  PE magic:  $('{0:X2}{1:X2}' -f $h[0], $h[1]) (must be 4D5A)"
                Write-Host "  SHA256:    $((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash)"
            } catch {}
            # Show whether some other ffs.exe is shadowing ours on PATH.
            Write-Host "  All ffs in PATH:"
            try {
                Get-Command $BinaryName -All -ErrorAction SilentlyContinue |
                    ForEach-Object { Write-Host "    $($_.Source)" }
            } catch {}
            Write-Host ""
            Write-Host "Likely causes:"
            Write-Host "  1. Antivirus/EDR quarantined the binary (Defender, CrowdStrike, etc)."
            Write-Host "     Run:  Get-MpThreatDetection | Where-Object Resources -match 'ffs'"
            Write-Host "     Then add an exclusion for $InstallDir and re-run."
            Write-Host "  2. Another ffs.exe earlier on PATH is shadowing ours."
            Write-Host "     Run:  where.exe ffs"
            Write-Host "  3. Mark-of-the-Web is blocking execution."
            Write-Host "     Run:  Unblock-File '$dest'"
            throw "Self-test failed - see diagnostics above."
        }
        Write-Success "Self-test passed: $($selfTest | Select-Object -First 1)"
    } else {
        Write-Info "Skipping binary install (-McpOnly)"
    }

    # MCP registration (default ON unless -NoMcp)
    if (-not $NoMcp) {
        Invoke-McpRegistration
    }

    # Summary
    if (-not $McpOnly) {
        $dest = Join-Path $InstallDir "$BinaryName.exe"
        Write-Host ""
        Write-Success "ffs installed to $dest"
        Write-Host ""
        Write-Host "Quick start (open a new PowerShell window for PATH changes):"
        Write-Host "  ffs --help"
        Write-Host "  ffs index           # one-time warm-up"
        Write-Host "  ffs find <query>"
        Write-Host "  ffs grep <pattern>"
        Write-Host "  ffs symbol <name>"
        if (-not $NoMcp) {
            Write-Host "  ffs mcp             # MCP server (registered with detected agents)"
        }
    } else {
        Write-Host ""
        Write-Success "ffs MCP registration complete."
    }
}

Main
