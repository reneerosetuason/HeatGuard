[CmdletBinding()]
param(
    [switch]$WebServer,
    [ValidateRange(1024, 65535)]
    [int]$WebPort = 7357
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$pythonPath = Join-Path $projectRoot '.venv\Scripts\python.exe'
$flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
$flutterRoot = Join-Path $projectRoot 'frontend\flutter'
$logDirectory = Join-Path $projectRoot 'logs'
$apiAddress = 'http://localhost:5000'
$previewOrigin = "http://localhost:$WebPort"
$backendProcess = $null
$savedEnvironment = @{}

if (-not (Test-Path -LiteralPath $pythonPath)) {
    throw 'Python environment missing. Create .venv and install requirements.txt first.'
}
if ($null -eq $flutterCommand) {
    throw 'Flutter was not found. Add the Flutter bin directory to PATH and reopen PowerShell.'
}

function Get-ApiConfiguration {
    try {
        $response = Invoke-WebRequest -Uri "$apiAddress/api/mobile/config" `
            -Headers @{ Origin = $previewOrigin } -UseBasicParsing -TimeoutSec 3
        $configuration = $response.Content | ConvertFrom-Json
        if ($configuration.ok -eq $true) { return $response }
    }
    catch {
        return $null
    }
    return $null
}

Push-Location -LiteralPath $projectRoot
try {
    # These settings apply only to this local development session.
    foreach ($name in @('HOST', 'PORT', 'WEB_CORS_ORIGINS')) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    # Respect HOST from .env so phone access survives a launcher restart.
    $configuredHost = & $pythonPath -c "import config, os; print(os.getenv('HOST', '127.0.0.1'))"
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the API host configuration.' }
    $env:HOST = $configuredHost.Trim()
    $env:PORT = '5000'
    $env:WEB_CORS_ORIGINS = "$previewOrigin,http://127.0.0.1:$WebPort"

    $configurationResponse = Get-ApiConfiguration
    if ($null -eq $configurationResponse) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        Write-Host 'Starting the HeatGuard API...'
        $backendProcess = Start-Process -FilePath $pythonPath -ArgumentList 'run.py' `
            -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput (Join-Path $logDirectory 'mobile-api.out.log') `
            -RedirectStandardError (Join-Path $logDirectory 'mobile-api.err.log')
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            if ($backendProcess.HasExited) {
                throw 'The API could not start. See logs/mobile-api.err.log.'
            }
            Start-Sleep -Milliseconds 500
            $configurationResponse = Get-ApiConfiguration
        } while ($null -eq $configurationResponse -and [DateTime]::UtcNow -lt $deadline)
        if ($null -eq $configurationResponse) {
            throw 'The API did not become ready. See logs/mobile-api.err.log.'
        }
    }

    if ($configurationResponse.Headers['Access-Control-Allow-Origin'] -ne $previewOrigin) {
        throw "The API is running with different browser settings. Stop its terminal and rerun this command, or set WEB_CORS_ORIGINS=$env:WEB_CORS_ORIGINS in .env and restart the API."
    }
    try {
        $health = Invoke-RestMethod -Uri "$apiAddress/api/health" -TimeoutSec 10
        if ($health.database -ne 'ok') { throw 'Database unavailable.' }
    }
    catch {
        throw 'The API cannot reach MySQL. Start MySQL and check the database settings in .env.'
    }

    Set-Location -LiteralPath $flutterRoot
    & $flutterCommand.Source pub get
    if ($LASTEXITCODE -ne 0) { throw 'Flutter could not install its packages.' }

    Write-Host "API ready: $apiAddress"
    Write-Host "Mobile preview: $previewOrigin"
    Write-Host 'Keep this terminal open. Press q to stop the preview.'
    $device = if ($WebServer) { 'web-server' } else { 'chrome' }
    & $flutterCommand.Source run --no-pub -d $device --web-hostname localhost `
        --web-port $WebPort "--dart-define=HEATGUARD_API_BASE_URL=$apiAddress"
    if ($LASTEXITCODE -ne 0) { throw 'The Flutter preview stopped with an error.' }
}
finally {
    if ($null -ne $backendProcess -and -not $backendProcess.HasExited) {
        Stop-Process -Id $backendProcess.Id -ErrorAction SilentlyContinue
    }
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    Pop-Location
}
