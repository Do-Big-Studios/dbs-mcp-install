# -- dbs-mcp installer (Windows) ------------------------------------------------
#
# One-line install (PowerShell):
#   Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://raw.githubusercontent.com/Do-Big-Studios/dbs-mcp-install/main/install.ps1 | iex
#
# What it does:
#   1. Installs git and bun if they are missing (via winget / bun.sh).
#   2. Signs you in with GitHub (browser, one-time). Access is granted only if
#      your GitHub account is in the Do Big Studios organisation.
#   3. Clones the private Do-Big-Studios/dbs-mcp repo to ~/.dbs-mcp so you can
#      read exactly what runs on your machine.
#   4. Installs dependencies and registers the "dbs" MCP server with every
#      supported client found on this machine: Cursor, Claude Code, Claude
#      Desktop and Codex.
#
# Re-running is safe: it updates the existing install and skips finished steps.
#
# Environment overrides:
#   DBS_MCP_DIR=<path>              install somewhere other than ~/.dbs-mcp
#   DBS_MCP_REAUTH=1                force a fresh GitHub sign-in
#   DBS_MCP_CLIENTS=cursor,codex    only register with these clients
#                                   (cursor, claude, claude-desktop, codex, all)
# ------------------------------------------------------------------------------

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$ORG             = "Do-Big-Studios"
$REPO            = "dbs-mcp"
$NPM_SCOPE       = "@do-big-studios"
$NPM_REGISTRY    = "https://npm.pkg.github.com"
$OAUTH_CLIENT_ID = "Ov23ligfaE4p3HgYZXI0"
$PAT_URL         = "https://github.com/settings/tokens/new?scopes=repo,read:packages&description=dbs-mcp"
$INSTALL_DIR     = if ($env:DBS_MCP_DIR) { $env:DBS_MCP_DIR } else { Join-Path $env:USERPROFILE ".dbs-mcp" }

# Mutable state shared with functions (a hashtable, so scope rules don't matter
# whether this file is run directly or piped through iex).
$State = @{ RepoUrl = "https://github.com/$ORG/$REPO.git" }

# -- Helpers -------------------------------------------------------------------

function Write-Step { param([string]$Msg) Write-Host "[dbs-mcp] " -ForegroundColor Cyan -NoNewline; Write-Host $Msg }
function Write-Ok   { param([string]$Msg) Write-Host "[dbs-mcp] " -ForegroundColor Green -NoNewline; Write-Host $Msg }
function Write-Warn { param([string]$Msg) Write-Host "[dbs-mcp] " -ForegroundColor Yellow -NoNewline; Write-Host $Msg }
function Write-Err  { param([string]$Msg) Write-Host "[dbs-mcp] " -ForegroundColor Red -NoNewline; Write-Host $Msg }

# `exit` inside `irm | iex` would close the user's terminal before they can read
# the error, so failures throw instead.
function Fail { param([string]$Msg) Write-Err $Msg; throw "dbs-mcp install failed: $Msg" }

function Test-Command { param([string]$Name) $null -ne (Get-Command $Name -ErrorAction SilentlyContinue) }

function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [Environment]::GetEnvironmentVariable("Path", "User")
    $fresh       = "$machinePath;$userPath"
    # Keep process-level entries that are not in the registry.
    $known = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in ($fresh -split ";")) { if ($p) { [void]$known.Add($p) } }
    $extras = foreach ($p in ($env:Path -split ";")) { if ($p -and -not $known.Contains($p)) { $p } }
    if ($extras) { $fresh += ";" + ($extras -join ";") }
    $env:Path = $fresh
}

# Windows command-line quoting for one argument.
function Quote-Arg {
    param([string]$Arg)
    if ($Arg -notmatch '[\s"]') { return $Arg }
    return '"' + ($Arg -replace '(\\*)"', '$1$1\"') + '"'
}

# Run a native command, capturing output, without tripping $ErrorActionPreference
# on stderr chatter. Returns @{ Code; Output }. Works on Windows PowerShell 5.1.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments, [string]$Cwd, [hashtable]$Env, [string]$Stdin)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Exe
    $psi.Arguments = ($Arguments | ForEach-Object { Quote-Arg $_ }) -join " "
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $hasStdin = $PSBoundParameters.ContainsKey("Stdin")
    $psi.RedirectStandardInput = $hasStdin
    if ($Cwd) { $psi.WorkingDirectory = $Cwd }
    if ($Env) { foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = [string]$Env[$k] } }
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($hasStdin) {
        $p.StandardInput.NewLine = "`n"
        $p.StandardInput.Write($Stdin)
        $p.StandardInput.Close()
    }
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return @{ Code = $p.ExitCode; Output = ("$out$err").Trim() }
}

# -- git -----------------------------------------------------------------------

function Ensure-Git {
    if (Test-Command "git") { Write-Ok "git found ($(git --version))."; return }

    if (-not (Test-Command "winget")) {
        Fail "git is not installed and winget is unavailable. Install git from https://git-scm.com and re-run."
    }
    Write-Step "Installing git via winget..."
    winget install --id Git.Git -e --source winget --accept-source-agreements --accept-package-agreements
    Refresh-Path
    if (-not (Test-Command "git")) {
        $gitCmd = "C:\Program Files\Git\cmd"
        if (Test-Path $gitCmd) { $env:Path += ";$gitCmd" }
    }
    if (-not (Test-Command "git")) { Fail "git installation failed. Install it from https://git-scm.com and re-run." }
    Write-Ok "git installed."
}

# -- bun -----------------------------------------------------------------------

function Ensure-Bun {
    if (Test-Command "bun") { Write-Ok "bun found (v$(bun --version))."; return }

    Write-Step "Installing bun..."
    $script = Invoke-RestMethod -Uri "https://bun.sh/install.ps1"
    & ([scriptblock]::Create($script)) | Out-Host
    Refresh-Path
    if (-not (Test-Command "bun")) {
        $bunBin = if ($env:BUN_INSTALL) { Join-Path $env:BUN_INSTALL "bin" } else { Join-Path $env:USERPROFILE ".bun\bin" }
        if (Test-Path $bunBin) { $env:Path += ";$bunBin" }
    }
    if (-not (Test-Command "bun")) { Fail "bun installation failed. Install it from https://bun.sh and re-run." }
    Write-Ok "bun installed (v$(bun --version))."
}

# -- GitHub auth ---------------------------------------------------------------
#
# One token does two jobs: git needs it to clone/pull the private repo, and bun
# needs it to fetch @do-big-studios packages from GitHub Packages. It is stored
# in ~/.npmrc and in git's credential helper (Windows Credential Manager).

function Get-NpmrcPath { Join-Path $env:USERPROFILE ".npmrc" }

function Get-NpmrcToken {
    $npmrc = Get-NpmrcPath
    if (-not (Test-Path $npmrc)) { return $null }
    foreach ($line in Get-Content $npmrc) {
        if ($line -match '^\s*//npm\.pkg\.github\.com/:_authToken=(.+?)\s*$') { return $Matches[1] }
    }
    return $null
}

function Save-NpmrcToken {
    param([string]$Token)
    $npmrc = Get-NpmrcPath
    $lines = @()
    if (Test-Path $npmrc) {
        $lines = @(Get-Content $npmrc | Where-Object {
            $_ -notmatch '^\s*//npm\.pkg\.github\.com/:_authToken=' -and
            $_ -notmatch "^\s*$([regex]::Escape($NPM_SCOPE)):registry="
        })
    }
    $lines += "${NPM_SCOPE}:registry=$NPM_REGISTRY"
    $lines += "//npm.pkg.github.com/:_authToken=$Token"
    [System.IO.File]::WriteAllLines($npmrc, [string[]]$lines)
}

# Does this token see the private repo? "ok" / "denied" / "error".
function Test-RepoAccess {
    param([string]$Token)
    if (-not $Token) { return "denied" }
    try {
        $null = Invoke-RestMethod -Uri "https://api.github.com/repos/$ORG/$REPO" -Headers @{
            Authorization = "Bearer $Token"; Accept = "application/vnd.github+json"; "User-Agent" = "dbs-mcp-install"
        }
        return "ok"
    } catch {
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -in 401, 403, 404) { return "denied" }
        Write-Warn "Could not reach api.github.com ($($_.Exception.Message))."
        return "error"
    }
}

# Can git already reach the repo without asking anything? (Existing sign-in.)
function Test-GitAccess {
    $r = Invoke-Native "git" @("ls-remote", "--exit-code", $State.RepoUrl, "HEAD") $null @{ GIT_TERMINAL_PROMPT = "0"; GCM_INTERACTIVE = "never" }
    return $r.Code -eq 0
}

function Save-GitCredential {
    param([string]$Token)
    $helper = (Invoke-Native "git" @("config", "--get", "credential.helper")).Output
    if (-not $helper) {
        Write-Warn "No git credential helper configured; enabling Git Credential Manager."
        $r = Invoke-Native "git" @("config", "--global", "credential.helper", "manager")
        if ($r.Code -ne 0) { Fail "Could not configure git credential helper: $($r.Output)" }
    }
    $r = Invoke-Native "git" @("credential", "approve") $null $null "protocol=https`nhost=github.com`nusername=x-access-token`npassword=$Token`n`n"
    if ($r.Code -ne 0) { Fail "Could not store the GitHub credential for git: $($r.Output)" }
}

function Invoke-DeviceFlow {
    param([string]$Scope)
    try {
        $code = Invoke-RestMethod -Uri "https://github.com/login/device/code" -Method Post `
            -Body "client_id=$OAUTH_CLIENT_ID&scope=$([uri]::EscapeDataString($Scope))" `
            -Headers @{ Accept = "application/json" }
    } catch { return $null }
    if (-not $code.device_code -or -not $code.user_code) { return $null }

    $interval  = if ($code.interval) { [int]$code.interval } else { 5 }
    $expiresIn = if ($code.expires_in) { [int]$code.expires_in } else { 900 }

    Write-Host ""
    Write-Step "Sign in with GitHub to continue. Open this page and enter the code:"
    Write-Host ""
    Write-Host "    $($code.verification_uri)" -ForegroundColor Cyan
    Write-Host "    Code: " -NoNewline; Write-Host $code.user_code -ForegroundColor Green
    Write-Host ""
    try { Start-Process $code.verification_uri } catch { }
    Write-Step "Waiting for you to approve in the browser..."

    $elapsed = 0
    while ($elapsed -lt $expiresIn) {
        Start-Sleep -Seconds $interval
        $elapsed += $interval
        try {
            $res = Invoke-RestMethod -Uri "https://github.com/login/oauth/access_token" -Method Post `
                -Body "client_id=$OAUTH_CLIENT_ID&device_code=$($code.device_code)&grant_type=urn:ietf:params:oauth:grant-type:device_code" `
                -Headers @{ Accept = "application/json" }
        } catch { continue }
        if ($res.access_token) { return $res.access_token }
        switch ($res.error) {
            "authorization_pending" { }
            "slow_down"     { $interval += 5 }
            "expired_token" { Write-Warn "Sign-in timed out."; return $null }
            "access_denied" { Write-Warn "Sign-in was denied."; return $null }
            default         { Write-Warn "Unexpected response from GitHub: $($res.error)"; return $null }
        }
    }
    Write-Warn "Sign-in timed out."
    return $null
}

function Read-ManualToken {
    Write-Host ""
    Write-Step "Falling back to a personal access token. In the page that opens:"
    Write-Step "  1. Keep 'repo' and 'read:packages' checked, click 'Generate token'"
    Write-Step "  2. Copy the token and paste it below"
    Write-Host ""
    try { Start-Process $PAT_URL } catch { }
    $secure = Read-Host -Prompt "[dbs-mcp] Paste your GitHub token (input is hidden)" -AsSecureString
    $token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    if ([string]::IsNullOrWhiteSpace($token)) { Fail "No token provided." }
    return $token.Trim()
}

function Ensure-GitHubAccess {
    $reauth   = $env:DBS_MCP_REAUTH -eq "1"
    $gitOk    = (-not $reauth) -and (Test-GitAccess)
    $npmToken = if ($reauth) { $null } else { Get-NpmrcToken }
    $npmOk    = $npmToken -and ((Test-RepoAccess $npmToken) -eq "ok")

    if ($gitOk -and $npmOk) { Write-Ok "GitHub access already configured."; return }

    # Get one token that covers whatever is missing.
    $scope = if ($gitOk) { "read:packages" } else { "repo read:packages" }
    Write-Host ""
    Write-Step "dbs-mcp is private to the Do Big Studios GitHub organisation."
    $token = Invoke-DeviceFlow $scope
    if (-not $token) { $token = Read-ManualToken }

    switch (Test-RepoAccess $token) {
        "denied" {
            Write-Host ""
            Write-Err "Your GitHub account cannot see $ORG/$REPO."
            Write-Err "Ask your team lead to add you to the Do Big Studios organisation, then re-run this installer."
            Fail "No access to $ORG/$REPO."
        }
        "error" { Fail "Could not verify access with GitHub. Check your connection and re-run." }
    }
    Write-Ok "GitHub access confirmed."

    Save-NpmrcToken $token
    if (-not $gitOk) {
        Save-GitCredential $token
        # Pin the username so the credential helper never has to pick between accounts.
        $State.RepoUrl = "https://x-access-token@github.com/$ORG/$REPO.git"
    }
}

# -- Install -------------------------------------------------------------------

function Ensure-Checkout {
    if (Test-Path (Join-Path $INSTALL_DIR ".git")) {
        Write-Step "Updating existing install at $INSTALL_DIR..."
        $r = Invoke-Native "git" @("pull", "--ff-only") $INSTALL_DIR @{ GIT_TERMINAL_PROMPT = "0" }
        if ($r.Code -ne 0) { Write-Warn "git pull failed, continuing with the current version: $($r.Output)" }
        return
    }
    if (Test-Path $INSTALL_DIR) { Fail "$INSTALL_DIR exists but is not a git checkout. Move it aside and re-run." }
    Write-Step "Cloning $ORG/$REPO into $INSTALL_DIR..."
    $r = Invoke-Native "git" @("clone", "--quiet", $State.RepoUrl, $INSTALL_DIR) $null @{ GIT_TERMINAL_PROMPT = "0" }
    if ($r.Code -ne 0) { Fail "git clone failed: $($r.Output)" }
    Write-Ok "Cloned."
}

function Install-Server {
    Write-Step "Installing dependencies..."
    $r = Invoke-Native "bun" @("install") $INSTALL_DIR
    if ($r.Code -ne 0) { Fail "bun install failed: $($r.Output)" }

    Write-Step "Registering the dbs MCP server..."
    # --here: register this checkout (already cloned above) instead of letting
    # setup clone its own copy.
    $r = Invoke-Native "bun" @("run", "scripts/install.ts", "--here") $INSTALL_DIR
    if ($r.Code -ne 0) { Fail "setup failed: $($r.Output)" }
    Write-Host $r.Output
}

# -- Main ----------------------------------------------------------------------

Write-Host ""
Write-Host "  dbs-mcp installer" -ForegroundColor White
Write-Host ""

Ensure-Git
Ensure-Bun
Ensure-GitHubAccess
Ensure-Checkout
Install-Server

Write-Host ""
Write-Ok "Done."
Write-Step "Restart the clients listed above; each will show a 'dbs' MCP server."
Write-Step "See the README in $INSTALL_DIR for what it can do and how sign-in works."
Write-Host ""
