param(
    [switch]$Remove,
    [switch]$SkipScheduledTask
)

$ErrorActionPreference = "Stop"

$projectRoot = $PSScriptRoot
$targetFile = Join-Path $projectRoot "run_robust.bat"
$guardianFile = Join-Path $projectRoot "ensure_watchdog.ps1"
$startupFolder = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$shortcutFile = Join-Path $startupFolder "AlgorithmCreed.lnk"
$legacyTaskName = "AlgorithmCreedWatchdog"
$guardianLogonTaskName = "AlgorithmCreedGuardianLogon"
$guardianMinuteTaskName = "AlgorithmCreedGuardianMinute"
$guardianTaskCommand = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$guardianFile`""
$guardianTaskCommandForSchtasks = "`"$guardianTaskCommand`""

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Remove-StartupShortcut {
    if (Test-Path $shortcutFile) {
        Remove-Item $shortcutFile -Force
        Write-Host "Autostart shortcut removed: $shortcutFile" -ForegroundColor Yellow
    } else {
        Write-Host "No shortcut found to remove: $shortcutFile" -ForegroundColor DarkYellow
    }
}

function Remove-ScheduledTaskSafe {
    param(
        [string]$TaskName
    )

    # Query task existence via Start-Process to avoid native-command stderr
    # being promoted to terminating errors in some PowerShell setups.
    $tmpOut = Join-Path $env:TEMP ([System.IO.Path]::GetRandomFileName())
    $tmpErr = Join-Path $env:TEMP ([System.IO.Path]::GetRandomFileName())
    try {
        $queryArgs = @("/Query", "/TN", $TaskName)
        $queryProc = Start-Process -FilePath "schtasks.exe" -ArgumentList $queryArgs -NoNewWindow -PassThru -Wait -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        if ($queryProc.ExitCode -ne 0) {
            Write-Host "No scheduled task found: $TaskName" -ForegroundColor DarkYellow
            return
        }
    } finally {
        if (Test-Path $tmpOut) { Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tmpErr) { Remove-Item $tmpErr -Force -ErrorAction SilentlyContinue }
    }

    $deleteArgs = @("/Delete", "/TN", $TaskName, "/F")
    $tmpDeleteOut = Join-Path $env:TEMP ([System.IO.Path]::GetRandomFileName())
    $tmpDeleteErr = Join-Path $env:TEMP ([System.IO.Path]::GetRandomFileName())
    try {
        $proc = Start-Process -FilePath "schtasks.exe" -ArgumentList $deleteArgs -NoNewWindow -PassThru -Wait -RedirectStandardOutput $tmpDeleteOut -RedirectStandardError $tmpDeleteErr
        if ($proc.ExitCode -eq 0) {
            Write-Host "Scheduled task removed: $TaskName" -ForegroundColor Yellow
        } else {
            $errLine = ""
            if (Test-Path $tmpDeleteErr) {
                $errLine = (Get-Content $tmpDeleteErr -ErrorAction SilentlyContinue | Select-Object -First 1)
            }
            if ([string]::IsNullOrWhiteSpace($errLine)) {
                Write-Host "No scheduled task removed (exit code $($proc.ExitCode)): $TaskName" -ForegroundColor DarkYellow
            } else {
                Write-Host "No scheduled task removed (exit code $($proc.ExitCode)): $TaskName | $errLine" -ForegroundColor DarkYellow
            }
        }
    } finally {
        if (Test-Path $tmpDeleteOut) { Remove-Item $tmpDeleteOut -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tmpDeleteErr) { Remove-Item $tmpDeleteErr -Force -ErrorAction SilentlyContinue }
    }
}

function New-ScheduledTaskSafe {
    param(
        [string[]]$TaskArgs,
        [string]$TaskName
    )
    $tmpCreateOut = Join-Path $env:TEMP ([System.IO.Path]::GetRandomFileName())
    $tmpCreateErr = Join-Path $env:TEMP ([System.IO.Path]::GetRandomFileName())
    try {
        $proc = Start-Process -FilePath "schtasks.exe" -ArgumentList $TaskArgs -NoNewWindow -PassThru -Wait -RedirectStandardOutput $tmpCreateOut -RedirectStandardError $tmpCreateErr
        if ($proc.ExitCode -eq 0) {
            Write-Host "Scheduled task created/updated: $TaskName" -ForegroundColor Green
            return $true
        }

        $errLine = ""
        if (Test-Path $tmpCreateErr) {
            $errLine = (Get-Content $tmpCreateErr -ErrorAction SilentlyContinue | Select-Object -First 1)
        }
        if ([string]::IsNullOrWhiteSpace($errLine)) {
            Write-Host "Unable to create scheduled task (exit code $($proc.ExitCode)): $TaskName" -ForegroundColor DarkYellow
        } else {
            Write-Host "Unable to create scheduled task (exit code $($proc.ExitCode)): $TaskName | $errLine" -ForegroundColor DarkYellow
        }
        return $false
    } finally {
        if (Test-Path $tmpCreateOut) { Remove-Item $tmpCreateOut -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tmpCreateErr) { Remove-Item $tmpCreateErr -Force -ErrorAction SilentlyContinue }
    }
}

if ($Remove) {
    Remove-StartupShortcut
    if (-not $SkipScheduledTask) {
        Remove-ScheduledTaskSafe -TaskName $legacyTaskName
        Remove-ScheduledTaskSafe -TaskName $guardianLogonTaskName
        Remove-ScheduledTaskSafe -TaskName $guardianMinuteTaskName
    }
    exit 0
}

if (-not (Test-Path $targetFile)) {
    throw "File not found: $targetFile"
}
if (-not (Test-Path $guardianFile)) {
    throw "File not found: $guardianFile"
}

$isAdmin = Test-IsAdministrator
# This app needs the interactive desktop for global hotkeys, mic and audio.
# Running it at HIGHEST can put it in a different integrity context than normal apps.
$taskRunLevel = "LIMITED"

try {
    $wScriptShell = New-Object -ComObject WScript.Shell
    $shortcut = $wScriptShell.CreateShortcut($shortcutFile)
    $shortcut.TargetPath = $targetFile
    $shortcut.Arguments = ""
    $shortcut.WorkingDirectory = $projectRoot
    $shortcut.WindowStyle = 7
    $shortcut.Description = "AlgorithmCreed autostart"
    $shortcut.Save()
    Write-Host "Shortcut created/updated in Startup folder: $shortcutFile" -ForegroundColor Green
} catch {
    Write-Host "Impossibile creare shortcut Startup: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Avvio automatico solo tramite Task Scheduler (se configurato)." -ForegroundColor DarkYellow
}

if (-not $SkipScheduledTask) {
    if (-not $isAdmin) {
        Write-Host "PowerShell non elevata: creo task con permessi LIMITED (consigliato)." -ForegroundColor DarkYellow
    }

    # Cleanup old single-task setup if present.
    Remove-ScheduledTaskSafe -TaskName $legacyTaskName

    $guardianLogonArgs = @(
        "/Create",
        "/TN", $guardianLogonTaskName,
        "/SC", "ONLOGON",
        "/TR", $guardianTaskCommandForSchtasks,
        "/IT",
        "/RL", $taskRunLevel,
        "/F"
    )
    $createdLogon = New-ScheduledTaskSafe -TaskArgs $guardianLogonArgs -TaskName $guardianLogonTaskName

    $guardianMinuteArgs = @(
        "/Create",
        "/TN", $guardianMinuteTaskName,
        "/SC", "MINUTE",
        "/MO", "1",
        "/TR", $guardianTaskCommandForSchtasks,
        "/IT",
        "/RL", $taskRunLevel,
        "/F"
    )
    $createdMinute = New-ScheduledTaskSafe -TaskArgs $guardianMinuteArgs -TaskName $guardianMinuteTaskName

    # Start the runtime immediately using the same launcher used by Startup.
    # The scheduled guardian tasks remain the recovery layer.
    try {
        Start-Process -FilePath $targetFile -WorkingDirectory $projectRoot -WindowStyle Hidden
        Write-Host "Runtime bootstrap executed." -ForegroundColor Green
    } catch {
        Write-Host "Runtime bootstrap non avviato: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    if (-not $createdLogon -or -not $createdMinute) {
        Write-Host "Task Scheduler non completamente configurato. Lo shortcut Startup rimane attivo." -ForegroundColor DarkYellow
        Write-Host "Per task affidabili al 100%, riesegui lo script come Amministratore." -ForegroundColor DarkYellow
    }
}
