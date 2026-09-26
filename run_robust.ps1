param()

$ErrorActionPreference = "Stop"

$projectRoot = $PSScriptRoot
$logsDir = Join-Path $projectRoot "logs"
$logFile = Join-Path $logsDir "watchdog.log"
$pythonExe = Join-Path $projectRoot ".venv\Scripts\python.exe"
$mainFile = Join-Path $projectRoot "main.py"
$mutex = New-Object System.Threading.Mutex($false, "AlgorithmCreedWatchdogMutex")
$hasMutex = $false
$alwaysGracefulExitCodes = @(10)
$consecutiveFailures = 0

if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
}

function Write-WatchdogLog {
    param(
        [string]$Level,
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$timestamp] [$Level] [pid=$PID] $Message" -Encoding UTF8
}

function Append-ProcessOutputToLog {
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return
    }

    try {
        $content = Get-Content -Path $Path -Raw -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrEmpty($content)) {
            Add-Content -Path $logFile -Value $content -Encoding UTF8
        }
    } finally {
        Remove-Item $Path -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-MainProcess {
    $stdoutPath = Join-Path $env:TEMP ([System.IO.Path]::GetRandomFileName())
    $stderrPath = Join-Path $env:TEMP ([System.IO.Path]::GetRandomFileName())

    try {
        $process = Start-Process `
            -FilePath $pythonExe `
            -ArgumentList @("`"$mainFile`"") `
            -WorkingDirectory $projectRoot `
            -PassThru `
            -Wait `
            -NoNewWindow `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath

        Append-ProcessOutputToLog -Path $stdoutPath
        Append-ProcessOutputToLog -Path $stderrPath

        if ($null -ne $process.ExitCode) {
            return [int]$process.ExitCode
        }
        return 0
    } finally {
        Remove-Item $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Set-DefaultEnv {
    param(
        [string]$Name,
        [string]$Value
    )

    $current = [Environment]::GetEnvironmentVariable($Name, "Process")
    if ([string]::IsNullOrWhiteSpace($current)) {
        Set-Item -Path "Env:$Name" -Value $Value
    }
}

function Get-RestartDelaySeconds {
    param(
        [int]$FailureCount,
        [double]$UptimeSeconds
    )

    if ($UptimeSeconds -ge 300) {
        return 5
    }

    $delay = [int][Math]::Min(60, 5 * [Math]::Pow(2, [Math]::Min([Math]::Max($FailureCount - 1, 0), 4)))
    if ($FailureCount -ge 10) {
        return 300
    }
    if ($FailureCount -ge 5) {
        return [Math]::Max($delay, 60)
    }
    return $delay
}

function Test-ShouldStopWatchdog {
    param(
        [int]$ExitCode
    )

    if ($alwaysGracefulExitCodes -contains $ExitCode) {
        return $true
    }

    # Exit code 0 is acceptable only for one-shot runs. In persistent modes
    # (hotkey/auto) a clean exit is still unexpected and should be recovered.
    if ($ExitCode -eq 0 -and $env:ALGOCREED_MODE -eq "once") {
        return $true
    }

    return $false
}

try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) {
        Write-WatchdogLog -Level "INFO" -Message "Un'altra istanza del watchdog e' gia attiva. Uscita."
        exit 0
    }

    if (-not (Test-Path $mainFile)) {
        Write-WatchdogLog -Level "ERROR" -Message "main.py non trovato: $mainFile"
        exit 1
    }

    if (-not (Test-Path $pythonExe)) {
        $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
        if ($null -eq $pythonCommand) {
            Write-WatchdogLog -Level "ERROR" -Message "Python non trovato. Installa Python o crea .venv\Scripts\python.exe"
            exit 9009
        }
        $pythonExe = $pythonCommand.Source
    }

    Set-DefaultEnv -Name "PYTHONUNBUFFERED" -Value "1"
    Set-DefaultEnv -Name "PYTHONIOENCODING" -Value "utf-8"
    Set-DefaultEnv -Name "ALGOCREED_MODE" -Value "hotkey"
    Set-DefaultEnv -Name "ALGOCREED_TRIGGER_KEY" -Value "a"
    Set-DefaultEnv -Name "ALGOCREED_SKIP_LANG_SELECTION" -Value "0"
    Set-DefaultEnv -Name "ALGOCREED_DEFAULT_LANG" -Value "it"
    Set-DefaultEnv -Name "ALGOCREED_AUTO_COOLDOWN_S" -Value "0"
    Set-DefaultEnv -Name "ALGOCREED_MIC_RETRY_S" -Value "8"
    Set-DefaultEnv -Name "ALGOCREED_MAX_LISTEN_ATTEMPTS" -Value "3"
    Set-DefaultEnv -Name "ALGOCREED_MIC_CALIBRATION_S" -Value "0.8"
    Set-DefaultEnv -Name "ALGOCREED_PHRASE_TIME_LIMIT_S" -Value "12"
    Set-DefaultEnv -Name "ALGOCREED_LISTEN_RESULT_TIMEOUT_S" -Value "12"
    Set-DefaultEnv -Name "ALGOCREED_GROQ_RETRIES" -Value "3"
    Set-DefaultEnv -Name "ALGOCREED_GROQ_RETRY_DELAY_S" -Value "3"
    Set-DefaultEnv -Name "ALGOCREED_TTS_PRIMARY" -Value "elevenlabs"

    Write-WatchdogLog -Level "INFO" -Message "Bootstrap. Python=$pythonExe Mode=$env:ALGOCREED_MODE SkipLang=$env:ALGOCREED_SKIP_LANG_SELECTION DefaultLang=$env:ALGOCREED_DEFAULT_LANG"

    while ($true) {
        $startedAt = Get-Date
        Write-WatchdogLog -Level "INFO" -Message "Starting AlgorithmCreed..."

        $exitCode = Invoke-MainProcess
        $uptimeSeconds = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)

        if (Test-ShouldStopWatchdog -ExitCode $exitCode) {
            Write-WatchdogLog -Level "INFO" -Message "main.py uscito in modo controllato con codice $exitCode dopo ${uptimeSeconds}s. Stop del watchdog."
            break
        }

        if ($uptimeSeconds -ge 300) {
            $consecutiveFailures = 0
        }

        $consecutiveFailures++
        $delaySeconds = Get-RestartDelaySeconds -FailureCount $consecutiveFailures -UptimeSeconds $uptimeSeconds

        Write-WatchdogLog -Level "WARN" -Message "main.py uscito con codice $exitCode dopo ${uptimeSeconds}s. Restart #$consecutiveFailures tra ${delaySeconds}s."
        Start-Sleep -Seconds $delaySeconds
    }

    exit 0
} catch {
    Write-WatchdogLog -Level "ERROR" -Message "Watchdog failure: $($_.Exception.Message)"
    exit 1
} finally {
    if ($hasMutex) {
        $mutex.ReleaseMutex() | Out-Null
    }
    $mutex.Dispose()
}
