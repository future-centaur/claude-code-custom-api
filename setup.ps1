<#
.SYNOPSIS
  Sets up `ox` — a command that launches Claude Code against an OpenRouter
  model, without touching the normal `claude` command.

.DESCRIPTION
  Self-contained: does not depend on any other file existing. Run it once
  with your OpenRouter API key; it writes everything under $HOME\ox and
  adds that folder to your user PATH.

  See README.md in this same folder for WHY each step below exists — three
  separate, non-obvious bugs had to be found and worked around to make this
  reliable. Re-running this script is safe (it overwrites its own files and
  won't duplicate the PATH entry).

.PARAMETER ApiKey
  Your OpenRouter API key (starts with sk-or-v1-...). Required.

.PARAMETER Model
  The OpenRouter model ID to launch Claude Code against. Defaults to the
  model this was built for: stealth/ox-alpha. Any OpenRouter model ID works.

.EXAMPLE
  .\setup.ps1 -ApiKey "sk-or-v1-...."
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ApiKey,

    [string]$Model = 'stealth/ox-alpha'
)

$ErrorActionPreference = 'Stop'

# --- Prerequisite check -----------------------------------------------------
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
    Write-Error "Node.js is required (the launcher runs a small local proxy) but wasn't found on PATH. Install Node.js and re-run this script."
}
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claudeCmd) {
    Write-Error "Claude Code CLI ('claude') wasn't found on PATH. Install it and re-run this script."
}

# --- Step 1: store the key persistently -------------------------------------
$trimmedKey = $ApiKey.Trim()
[Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY', $trimmedKey, 'User')
Write-Output "[1/4] Stored OPENROUTER_API_KEY as a user environment variable."

# --- Step 2: create the launcher folder -------------------------------------
$oxDir = "$HOME\ox"
if (-not (Test-Path $oxDir)) {
    New-Item -ItemType Directory -Path $oxDir | Out-Null
}

# The forwarding proxy. Exists solely to delete one leaking header — see
# README.md "Bug 3". Deliberately logs nothing.
$proxyJs = @'
// Loopback-only forwarding proxy for OpenRouter.
// Claude Code sometimes attaches a stale Claude subscription credential to the
// x-api-key header even when ANTHROPIC_AUTH_TOKEN is set, which OpenRouter's
// gateway misroutes. This strips that one header and forwards everything else
// unchanged. No request/response content is logged anywhere.
const http = require('http');
const https = require('https');

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    const outHeaders = { ...req.headers };
    delete outHeaders.host;
    delete outHeaders['x-api-key'];
    outHeaders.host = 'openrouter.ai';

    const proxyReq = https.request(
      { hostname: 'openrouter.ai', path: '/api' + req.url, method: req.method, headers: outHeaders },
      (proxyRes) => {
        res.writeHead(proxyRes.statusCode, proxyRes.headers);
        proxyRes.pipe(res);
      }
    );
    proxyReq.on('error', () => {
      res.writeHead(502);
      res.end();
    });
    proxyReq.end(body);
  });
});

server.listen(0, '127.0.0.1', () => {
  console.log('PORT:' + server.address().port);
});
'@
Set-Content -Path (Join-Path $oxDir 'ox_proxy.js') -Value $proxyJs -Encoding ascii

# The launcher itself.
$oxPs1 = @"
`$ErrorActionPreference = 'Stop'

`$apiKey = [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'User')
if (-not `$apiKey) {
    `$apiKey = `$env:OPENROUTER_API_KEY
}
if (-not `$apiKey) {
    Write-Error "OPENROUTER_API_KEY is not set. Set it and try again."
    exit 1
}
`$apiKey = `$apiKey.Trim()

`$scriptDir = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$proxyScript = Join-Path `$scriptDir 'ox_proxy.js'
`$proxyOutFile = [System.IO.Path]::GetTempFileName()

`$proxyProcess = `$null
try {
    `$proxyProcess = Start-Process -FilePath 'node' -ArgumentList "```"`$proxyScript```"" ``
        -RedirectStandardOutput `$proxyOutFile -NoNewWindow -PassThru

    `$port = `$null
    for (`$i = 0; `$i -lt 50; `$i++) {
        Start-Sleep -Milliseconds 100
        `$line = Get-Content `$proxyOutFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if (`$line -match '^PORT:(\d+)`$') {
            `$port = `$Matches[1]
            break
        }
    }
    if (-not `$port) {
        Write-Error "Local proxy failed to start; falling back to direct connection."
        `$env:ANTHROPIC_BASE_URL = 'https://openrouter.ai/api'
    } else {
        `$env:ANTHROPIC_BASE_URL = "http://127.0.0.1:`$port"
    }

    `$env:ANTHROPIC_AUTH_TOKEN = `$apiKey
    `$env:ANTHROPIC_API_KEY = ''
    `$env:ANTHROPIC_MODEL = '$Model'
    `$env:ANTHROPIC_CUSTOM_MODEL_OPTION = '$Model'
    `$env:ANTHROPIC_DEFAULT_OPUS_MODEL = '$Model'
    `$env:ANTHROPIC_DEFAULT_SONNET_MODEL = '$Model'
    `$env:ANTHROPIC_DEFAULT_HAIKU_MODEL = '$Model'
    `$env:ANTHROPIC_SMALL_FAST_MODEL = '$Model'
    `$env:CLAUDE_CODE_SUBAGENT_MODEL = '$Model'

    claude @args
    exit `$LASTEXITCODE
} finally {
    if (`$proxyProcess -and -not `$proxyProcess.HasExited) {
        Stop-Process -Id `$proxyProcess.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item `$proxyOutFile -ErrorAction SilentlyContinue
}
"@
Set-Content -Path (Join-Path $oxDir 'ox.ps1') -Value $oxPs1 -Encoding ascii

$oxCmd = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ox.ps1" %*
'@
Set-Content -Path (Join-Path $oxDir 'ox.cmd') -Value $oxCmd -Encoding ascii

Write-Output "[2/4] Wrote launcher files to $oxDir"

# --- Step 3: add the folder to user PATH ------------------------------------
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$oxDir*") {
    $newPath = if ([string]::IsNullOrEmpty($userPath)) { $oxDir } else { "$userPath;$oxDir" }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Output "[3/4] Added $oxDir to user PATH."
} else {
    Write-Output "[3/4] $oxDir already on user PATH."
}

# --- Step 4: verify the key ---------------------------------------------------
try {
    $resp = Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/auth/key' -Headers @{ Authorization = "Bearer $trimmedKey" } -Method Get
    Write-Output "[4/4] Key verified against OpenRouter (label: $($resp.data.label))."
} catch {
    Write-Warning "[4/4] Could not verify the key against OpenRouter: $($_.Exception.Message)"
}

Write-Output ""
Write-Output "Done. Open a NEW terminal and run: ox"
Write-Output "(new terminal is required so the updated PATH takes effect)"
