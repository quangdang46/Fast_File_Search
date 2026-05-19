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
    [ValidateSet('User', 'Profile', 'None')]
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
    $entries = $userPath -split ';' | Where-Object { $_ -ne '' }
    if ($entries -notcontains $Dir -and $entries -notcontains $Dir.TrimEnd('\')) {
        $newPath = (@($entries + $Dir) -join ';')
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Success "Added $Dir to user PATH."
    }
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
    if (-not (Test-OnPath $Dir)) { $env:PATH = "$env:PATH;$Dir" }
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
    & claude mcp remove -s user $McpName 2>$null
    try {
        & claude mcp add -s user $McpName -- $cmd mcp 2>$null
        Write-Success "[mcp] registered with Claude Code"
    } catch {
        Write-Warn "claude mcp add failed"
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
    & codex mcp remove $McpName 2>$null
    try {
        & codex mcp add $McpName -- $cmd mcp 2>$null
        Write-Success "[mcp] registered with Codex"
    } catch {
        Write-Warn "codex mcp add failed"
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
        & claude mcp remove -s user $McpName 2>$null
        Write-Success "[mcp] removed $McpName from Claude Code"
    }
    # Codex
    if (Get-Command codex -ErrorAction SilentlyContinue) {
        & codex mcp remove $McpName 2>$null
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

            # Install
            New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
            $dest = Join-Path $InstallDir "$BinaryName.exe"
            Move-Item -Force -Path $tmpFile -Destination $dest
            Write-Success "Installed $dest"
        } finally {
            Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        }

        Set-PathPersistence -Dir $InstallDir -Scope $PathScope

        if ($Verify -or $EasyMode) {
            Write-Info "Running self-test..."
            & $dest --version
            if ($LASTEXITCODE -ne 0) { throw "Self-test failed" }
        }
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
        try { & $dest --version 2>$null } catch {}
        Write-Host ""
        Write-Host "Quick start:"
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
