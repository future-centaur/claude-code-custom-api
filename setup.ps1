<#
.SYNOPSIS
  One-time setup for `ox`  -  configures your OpenRouter API key and model,
  then adds this folder to your PATH so `ox` launches Claude Code through it.

.DESCRIPTION
  This script does NOT generate ox.ps1, ox.cmd, or ox_proxy.js  -  those are
  static files that ship with the repo and never change. All this script
  does is: (1) resolve and store your OpenRouter API key as a user
  environment variable, (2) write the chosen model to ox-model.txt, which
  ox.ps1 reads fresh on every launch, and (3) add this folder to your user
  PATH.

  Because the model lives in ox-model.txt instead of being baked into a
  generated ox.ps1, switching models is just: .\setup.ps1 -Model "id"
   -  no files get overwritten, and nothing you customized in ox.ps1 or
  ox_proxy.js is ever touched.

  Run this from inside the cloned repo folder. Safe to re-run any time:
  running it with no arguments at all keeps your existing key and model
  exactly as they were.

.PARAMETER ApiKey
  Your OpenRouter API key. Optional  -  if omitted, you'll be prompted; just
  press Enter at that prompt to fall back to the OPENROUTER_API_KEY
  environment variable if you've already set one yourself. If neither is
  available, setup stops with an error instead of continuing silently.

.PARAMETER Model
  The OpenRouter model ID to use, e.g. "z-ai/glm-5.2". Optional  -  if
  omitted, keeps whatever model is already in ox-model.txt. On a
  first-ever run with no ox-model.txt yet, defaults to stealth/ox-alpha.

.EXAMPLE
  .\setup.ps1
  # First run: prompts for a key (or reuses OPENROUTER_API_KEY), defaults
  # model to stealth/ox-alpha. Later runs: keeps whatever was set before.

.EXAMPLE
  .\setup.ps1 -Model "z-ai/glm-5.2"
  # Switches the configured model. Key is untouched if already set.
#>
param(
    [string]$ApiKey,
    [string]$Model
)

$ErrorActionPreference = 'Stop'
$repoDir = $PSScriptRoot

# --- Prerequisite check: required tools --------------------------------------
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
    Write-Error "Node.js is required (the launcher runs a small local proxy) but wasn't found on PATH. Install Node.js and re-run this script."
}
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claudeCmd) {
    Write-Error "Claude Code CLI ('claude') wasn't found on PATH. Install it and re-run this script."
}

# --- Prerequisite check: required repo files ---------------------------------
$requiredFiles = @('ox.ps1', 'ox.cmd', 'ox_proxy.js')
$missing = $requiredFiles | Where-Object { -not (Test-Path (Join-Path $repoDir $_)) }
if ($missing) {
    Write-Error "This clone is missing required file(s): $($missing -join ', '). Re-clone or 'git pull' the repo and try again."
}
Write-Output "[1/4] Found ox.ps1, ox.cmd, ox_proxy.js in $repoDir  -  nothing to regenerate."

# --- Resolve API key ----------------------------------------------------------
if (-not $ApiKey) {
    $typed = Read-Host "Enter your OpenRouter API key (or press Enter to use OPENROUTER_API_KEY from your environment)"
    if ($typed) {
        $ApiKey = $typed
    } else {
        $ApiKey = [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'User')
        if (-not $ApiKey) { $ApiKey = $env:OPENROUTER_API_KEY }
        if (-not $ApiKey) {
            Write-Error "No key entered, and OPENROUTER_API_KEY isn't set in your environment. Either enter a key when prompted, or set the environment variable yourself first and re-run."
        }
    }
}
$trimmedKey = $ApiKey.Trim()
if (-not $trimmedKey) {
    Write-Error "API key resolved to empty after trimming."
}
[Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY', $trimmedKey, 'User')
Write-Output "[2/4] Stored OPENROUTER_API_KEY as a user environment variable."

# --- Resolve model -------------------------------------------------------------
$modelFile = Join-Path $repoDir 'ox-model.txt'
if (-not $Model) {
    if (Test-Path $modelFile) {
        $Model = (Get-Content $modelFile -Raw).Trim()
        Write-Output "No -Model given; keeping previously configured model: $Model"
    } else {
        $Model = 'stealth/ox-alpha'
        Write-Output "No -Model given and no previous config found; defaulting to $Model"
    }
}
Set-Content -Path $modelFile -Value $Model -Encoding ascii -NoNewline
Write-Output "[3/4] Model set to $Model (stored in ox-model.txt)"

# --- Add repo folder to PATH ----------------------------------------------------
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$repoDir*") {
    $newPath = if ([string]::IsNullOrEmpty($userPath)) { $repoDir } else { "$userPath;$repoDir" }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Output "[4/4] Added $repoDir to user PATH."
} else {
    Write-Output "[4/4] $repoDir already on user PATH."
}

# --- Verify the key -------------------------------------------------------------
try {
    $resp = Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/auth/key' -Headers @{ Authorization = "Bearer $trimmedKey" } -Method Get
    Write-Output "Key verified against OpenRouter (label: $($resp.data.label))."
} catch {
    Write-Warning "Could not verify the key against OpenRouter: $($_.Exception.Message)"
}

Write-Output ""
Write-Output "Done. Open a NEW terminal and run: ox"
Write-Output "(new terminal is required so the updated PATH takes effect)"
