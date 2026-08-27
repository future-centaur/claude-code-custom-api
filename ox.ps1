$ErrorActionPreference = 'Stop'

$apiKey = [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'User')
if (-not $apiKey) {
    $apiKey = $env:OPENROUTER_API_KEY
}
if (-not $apiKey) {
    Write-Error "OPENROUTER_API_KEY is not set. Set it and try again."
    exit 1
}
$apiKey = $apiKey.Trim()

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$proxyScript = Join-Path $scriptDir 'ox_proxy.js'
$proxyOutFile = [System.IO.Path]::GetTempFileName()

$proxyProcess = $null
try {
    $proxyProcess = Start-Process -FilePath 'node' -ArgumentList "`"$proxyScript`"" `
        -RedirectStandardOutput $proxyOutFile -NoNewWindow -PassThru

    $port = $null
    for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 100
        $line = Get-Content $proxyOutFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($line -match '^PORT:(\d+)$') {
            $port = $Matches[1]
            break
        }
    }
    if (-not $port) {
        Write-Error "Local proxy failed to start; falling back to direct connection."
        $env:ANTHROPIC_BASE_URL = 'https://openrouter.ai/api'
    } else {
        $env:ANTHROPIC_BASE_URL = "http://127.0.0.1:$port"
    }

    $env:ANTHROPIC_AUTH_TOKEN = $apiKey
    $env:ANTHROPIC_API_KEY = ''
    $env:ANTHROPIC_MODEL = 'z-ai/glm-5.2:free'
    $env:ANTHROPIC_CUSTOM_MODEL_OPTION = 'z-ai/glm-5.2:free'
    $env:ANTHROPIC_DEFAULT_OPUS_MODEL = 'z-ai/glm-5.2:free'
    $env:ANTHROPIC_DEFAULT_SONNET_MODEL = 'z-ai/glm-5.2:free'
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = 'z-ai/glm-5.2:free'
    $env:ANTHROPIC_SMALL_FAST_MODEL = 'z-ai/glm-5.2:free'
    $env:CLAUDE_CODE_SUBAGENT_MODEL = 'z-ai/glm-5.2:free'

    claude @args
    exit $LASTEXITCODE
} finally {
    if ($proxyProcess -and -not $proxyProcess.HasExited) {
        Stop-Process -Id $proxyProcess.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $proxyOutFile -ErrorAction SilentlyContinue
}
