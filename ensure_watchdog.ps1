param(
    [switch]$VerboseLog
)

$ErrorActionPreference = "Stop"

$projectRoot = $PSScriptRoot
$watchdogScript = Join-Path $projectRoot "run_robust.ps1"
$logsDir = Join-Path $projectRoot "logs"
$logFile = Join-Path $logsDir "guardian.log"
$heartbeatFile = Join-Path $logsDir "runtime_heartbeat.json"
$mutex = New-Object System.Threading.Mutex($false, "AlgorithmCreedGuardianMutex")
$hasMutex = $false
$startupGraceSeconds = 90
$forcedRestartPauseSeconds = 2
$defaultHeartbeatStaleSeconds = 15
$defaultWorkStallSeconds = 120

if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
}

function Write-GuardianLog {
    param(
        [string]$Level,
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$timestamp] [$Level] [pid=$PID] $Message" -Encoding UTF8
}

function Convert-ToSafeDateTime {
    param(
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [datetime]) {
        return $Value
    }
    try {
        return [System.Management.ManagementDateTimeConverter]::ToDateTime($Value)
    } catch {
        try {
            return [datetime]$Value
        } catch {
            return $null
        }
    }
}

function Get-UnixAgeSeconds {
    param(
        $EpochSeconds
    )

    if ($null -eq $EpochSeconds) {
        return [double]::PositiveInfinity
    }

    try {
        $timestamp = ([datetime]"1970-01-01T00:00:00Z").AddSeconds([double]$EpochSeconds)
        return ((Get-Date).ToUniversalTime() - $timestamp).TotalSeconds
    } catch {
        return [double]::PositiveInfinity
    }
}

function Get-ProjectProcesses {
    param(
        [string]$ProjectRoot
    )

    $escapedProjectRoot = [System.Management.Automation.WildcardPattern]::Escape($ProjectRoot)
    $matchedProcesses = @()
    $processes = Get-CimInstance Win32_Process -Filter "Name='cmd.exe' OR Name='powershell.exe' OR Name='pwsh.exe' OR Name='python.exe' OR Name='pythonw.exe'"

    foreach ($process in $processes) {
        $cmd = $process.CommandLine
        if ([string]::IsNullOrWhiteSpace($cmd)) {
            continue
        }
        if (
            (
                $cmd -like "*run_robust.bat*" -or
                $cmd -like "*run_robust.ps1*" -or
                $cmd -like "*main.py*"
            ) -and $cmd -like "*$escapedProjectRoot*"
        ) {
            $matchedProcesses += $process
        }
    }

    return $matchedProcesses
}

function Get-YoungestProcessAgeSeconds {
    param(
        [array]$Processes
    )

    $youngestAge = $null
    foreach ($process in $Processes) {
        $startedAt = Convert-ToSafeDateTime $process.CreationDate
        if ($null -eq $startedAt) {
            continue
        }
        $ageSeconds = ((Get-Date) - $startedAt).TotalSeconds
        if ($null -eq $youngestAge -or $ageSeconds -lt $youngestAge) {
            $youngestAge = $ageSeconds
        }
    }

    return $youngestAge
}

function Get-HeartbeatData {
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    try {
        return Get-Content -Path $Path -Raw | ConvertFrom-Json
    } catch {
        Write-GuardianLog -Level "WARN" -Message "Heartbeat non leggibile: $($_.Exception.Message)"
        return $null
    }
}

function Get-HealthStatus {
    param(
        [array]$ProjectProcesses,
        [string]$HeartbeatPath
    )

    $heartbeat = Get-HeartbeatData -Path $HeartbeatPath
    $youngestAge = Get-YoungestProcessAgeSeconds -Processes $ProjectProcesses
    $processIds = @($ProjectProcesses | ForEach-Object { [int]$_.ProcessId })

    if ($ProjectProcesses.Count -eq 0) {
        return @{
            Healthy = $false
            Reason = "nessun processo del progetto trovato"
            Heartbeat = $heartbeat
        }
    }

    if ($null -eq $heartbeat) {
        if ($null -ne $youngestAge -and $youngestAge -le $startupGraceSeconds) {
            return @{
                Healthy = $true
                Reason = "heartbeat non ancora disponibile ma processo in avvio"
                Heartbeat = $null
            }
        }
        return @{
            Healthy = $false
            Reason = "heartbeat assente o illeggibile"
            Heartbeat = $null
        }
    }

    $heartbeatPid = $null
    try {
        $heartbeatPid = [int]$heartbeat.pid
    } catch {
        $heartbeatPid = $null
    }

    if ($null -ne $heartbeatPid -and $processIds -notcontains $heartbeatPid) {
        if ($null -ne $youngestAge -and $youngestAge -le $startupGraceSeconds) {
            return @{
                Healthy = $true
                Reason = "heartbeat precedente durante fase di bootstrap"
                Heartbeat = $heartbeat
            }
        }
        return @{
            Healthy = $false
            Reason = "heartbeat riferito a pid non piu' attivo ($heartbeatPid)"
            Heartbeat = $heartbeat
        }
    }

    $heartbeatAge = Get-UnixAgeSeconds -EpochSeconds $heartbeat.last_heartbeat_time
    $progressAge = Get-UnixAgeSeconds -EpochSeconds $heartbeat.last_progress_time
    $heartbeatStaleSeconds = $defaultHeartbeatStaleSeconds
    $workStallSeconds = $defaultWorkStallSeconds
    $state = ""

    try {
        if ($heartbeat.heartbeat_stale_s) {
            $heartbeatStaleSeconds = [double]$heartbeat.heartbeat_stale_s
        }
    } catch {
    }
    try {
        if ($heartbeat.work_stall_timeout_s) {
            $workStallSeconds = [double]$heartbeat.work_stall_timeout_s
        }
    } catch {
    }
    try {
        if ($heartbeat.state) {
            $state = [string]$heartbeat.state
        }
    } catch {
        $state = ""
    }

    if ($heartbeatAge -gt $heartbeatStaleSeconds) {
        return @{
            Healthy = $false
            Reason = "heartbeat fermo da $([math]::Round($heartbeatAge, 1))s"
            Heartbeat = $heartbeat
        }
    }

    if ($state -in @("STARTING", "RUNNING", "STOPPING") -and $progressAge -gt $workStallSeconds) {
        $reasonText = ""
        try {
            if ($heartbeat.last_progress_reason) {
                $reasonText = [string]$heartbeat.last_progress_reason
            }
        } catch {
            $reasonText = ""
        }
        if ([string]::IsNullOrWhiteSpace($reasonText)) {
            $reasonText = "n/d"
        }
        return @{
            Healthy = $false
            Reason = "progresso fermo da $([math]::Round($progressAge, 1))s in stato $state (ultimo: $reasonText)"
            Heartbeat = $heartbeat
        }
    }

    return @{
        Healthy = $true
        Reason = "heartbeat sano (state=$state)"
        Heartbeat = $heartbeat
    }
}

function Stop-ProjectProcesses {
    param(
        [array]$Processes
    )

    $seen = @{}
    foreach ($process in ($Processes | Sort-Object ProcessId -Descending)) {
        $targetPid = [int]$process.ProcessId
        if ($seen.ContainsKey($targetPid)) {
            continue
        }
        $seen[$targetPid] = $true
        if ($targetPid -eq $PID) {
            continue
        }
        try {
            Stop-Process -Id $targetPid -Force -ErrorAction Stop
            Write-GuardianLog -Level "WARN" -Message "Processo terminato per recovery: pid=$targetPid"
        } catch {
            Write-GuardianLog -Level "WARN" -Message "Impossibile terminare pid=${targetPid}: $($_.Exception.Message)"
        }
    }
}

function Start-Watchdog {
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$watchdogScript`""
    ) -WorkingDirectory $projectRoot -WindowStyle Hidden
}

try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) {
        exit 0
    }

    if (-not (Test-Path $watchdogScript)) {
        Write-GuardianLog -Level "ERROR" -Message "Watchdog script non trovato: $watchdogScript"
        exit 1
    }

    $projectProcesses = @(Get-ProjectProcesses -ProjectRoot $projectRoot)
    if ($projectProcesses.Count -eq 0) {
        Start-Watchdog
        Write-GuardianLog -Level "WARN" -Message "Nessun processo del progetto trovato: riavvio automatico eseguito."
        exit 0
    }

    $health = Get-HealthStatus -ProjectProcesses $projectProcesses -HeartbeatPath $heartbeatFile
    if ($health.Healthy) {
        if ($VerboseLog) {
            Write-GuardianLog -Level "INFO" -Message $health.Reason
        }
        exit 0
    }

    Write-GuardianLog -Level "ERROR" -Message "Runtime non sano rilevato: $($health.Reason). Riavvio forzato in corso."
    Stop-ProjectProcesses -Processes $projectProcesses
    Start-Sleep -Seconds $forcedRestartPauseSeconds
    if (Test-Path $heartbeatFile) {
        Remove-Item $heartbeatFile -Force -ErrorAction SilentlyContinue
    }
    Start-Watchdog
    Write-GuardianLog -Level "WARN" -Message "Recovery completato: watchdog rilanciato."
    exit 0
} catch {
    Write-GuardianLog -Level "ERROR" -Message "Guardian failure: $($_.Exception.Message)"
    exit 1
} finally {
    if ($hasMutex) {
        $mutex.ReleaseMutex() | Out-Null
    }
    $mutex.Dispose()
}
