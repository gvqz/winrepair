<# :
@echo off
cls
setlocal
cd /d "%~dp0"

:: Pass this script's full path to PowerShell through the environment.
:: This avoids all quoting problems (spaces, apostrophes, etc.) in paths.
set "WINREPAIR_SELF=%~f0"

:: Check for administrator rights (fltmc requires elevation and exists on all Windows editions)
fltmc >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "try { Start-Process -FilePath $env:WINREPAIR_SELF -Verb RunAs } catch { exit 1 }"
    if errorlevel 1 (
        echo.
        echo Elevation was canceled. This tool needs administrator rights to run.
        echo.
        pause
    )
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
"$ErrorActionPreference = 'Stop'; if ($PSVersionTable.PSVersion.Major -lt 3) { Write-Host 'This tool requires Windows PowerShell 3.0 or newer.' -ForegroundColor Red; exit 1 }; $content = [System.IO.File]::ReadAllText($env:WINREPAIR_SELF); $marker = '# --- POWERSHELL CODE STARTS HERE ---'; $idx = $content.LastIndexOf($marker); if ($idx -lt 0) { throw 'PowerShell section marker not found in this file.' }; Invoke-Expression $content.Substring($idx + $marker.Length)"

if errorlevel 1 pause
exit /b
#>

# --- POWERSHELL CODE STARTS HERE ---

 $ErrorActionPreference = 'Continue'

 $DesktopPath = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace($DesktopPath)) {
    $DesktopPath = Join-Path $env:USERPROFILE 'Desktop'
}

 $ReportFolder = Join-Path $DesktopPath 'WinRepair_Logs'
New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null

 $LogPath = Join-Path $ReportFolder 'ActionLog.txt'
 $SystemErrorExportPath = Join-Path $ReportFolder 'RecentErrors.txt'
 $BatteryReportPath = Join-Path $ReportFolder 'Battery_Report.html'
 $DriverCleanupReportPath = Join-Path $ReportFolder 'Driver_Store_Cleanup.txt'
 $SummaryPath = Join-Path $ReportFolder 'Last_Run_Summary.txt'

 $SystemRoot = $env:SystemRoot
if ([string]::IsNullOrWhiteSpace($SystemRoot)) {
    $SystemRoot = Join-Path $env:SystemDrive 'Windows'
}

# Script-level state. Always read/write these with the $script: scope so that
# updates inside functions are visible everywhere (fixes the restart-prompt bug).
 $script:NeedsRestart = $false
 $script:RunFailures = @()
 $script:FullRepairMode = $false
 $script:RestorePointPrompted = $false

function Write-Log {
    param([string]$Message)
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8
}

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('Info','Step','Success','Warning','Error')]
        [string]$Level = 'Info'
    )

    switch ($Level) {
        'Info'    { $color = 'Gray';   $prefix = '[INFO]' }
        'Step'    { $color = 'Cyan';   $prefix = '[STEP]' }
        'Success' { $color = 'Green';  $prefix = '[ OK ]' }
        'Warning' { $color = 'Yellow'; $prefix = '[WARN]' }
        'Error'   { $color = 'Red';    $prefix = '[FAIL]' }
    }

    Write-Host "$prefix $Message" -ForegroundColor $color
    Write-Log "$prefix $Message"
}

function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$DefaultYes = $true
    )

    $suffix = if ($DefaultYes) { '(Y/n)' } else { '(y/N)' }

    while ($true) {
        $answer = (Read-Host "$Prompt $suffix").Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $DefaultYes
        }

        switch -Regex ($answer) {
            '^(y|yes)$'                { return $true }
            '^(n|no|b|back|c|cancel)$' { return $false }
            default                    { Write-Status 'Please answer yes, no, back, or cancel.' 'Warning' }
        }
    }
}

function Confirm-TaskStart {
    param(
        [string]$Name,
        [string]$Details
    )

    if ($script:FullRepairMode) {
        return $true
    }

    Write-Host ''
    Write-Status $Details 'Warning'
    if (Read-YesNo -Prompt "Start $Name now? Type no, back, or cancel to return to the menu." -DefaultYes $false) {
        return $true
    }

    Write-Status "$Name canceled. Returning to the menu." 'Info'
    return $false
}

function Read-MenuChoice {
    $aliases = @{
        '0' = '0'; 'HEALTH' = '0'
        '1' = '1'; 'TEMP' = '1'; 'CLEAN' = '1'; 'CACHE' = '1'
        '2' = '2'; 'REPAIR' = '2'; 'SFC' = '2'; 'DISM' = '2'
        '3' = '3'; 'UPDATE' = '3'
        '4' = '4'; 'NETWORK' = '4'; 'NET' = '4'
        '5' = '5'; 'E' = '5'; 'ERRORS' = '5'; 'EVENTS' = '5'; 'LOGS' = '5'
        '6' = '6'; 'DISK' = '6'
        '7' = '7'; 'CHKDSK' = '7'
        '8' = '8'; 'FULL' = '8'; 'ALL' = '8'
        'D' = 'D'; 'DRIVER' = 'D'; 'DRIVERS' = 'D'
        'R' = 'R'; 'RESTORE' = 'R'
        'G' = 'G'; 'GUIDE' = 'G'; 'HELP' = 'G'
        'Q' = 'Q'; 'QUIT' = 'Q'; 'EXIT' = 'Q'
    }

    while ($true) {
        $choice = (Read-Host 'Select an option').Trim().ToUpperInvariant()
        if ($aliases.ContainsKey($choice)) {
            return $aliases[$choice]
        }

        Write-Status 'Invalid option. Choose a menu number (0-8) or D, R, G, Q.' 'Warning'
    }
}

function Write-TaskBreak {
    param([string]$Title)

    Write-Host ''
    Write-Host ('=' * 58) -ForegroundColor DarkCyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ('=' * 58) -ForegroundColor DarkCyan
    Write-Log "---- $Title ----"
}

function Add-RunFailure {
    param(
        [string]$Name,
        [string]$Reason = 'Review the repair log for details.'
    )

    $script:RunFailures += [pscustomobject]@{
        Name = $Name
        Reason = $Reason
    }
}

function Invoke-TrackedTask {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    Write-TaskBreak $Name
    $success = $true

    try {
        $result = & $Action
        if ($result -is [array]) {
            $success = -not ($result -contains $false)
        } else {
            $success = ($result -ne $false)
        }
    } catch {
        $success = $false
        Write-Status "$Name failed. $($_.Exception.Message)" 'Error'
    }

    if (-not $success) {
        Add-RunFailure -Name $Name
    }

    return $success
}

function Show-RunSummary {
    param([string]$Title = 'Run Summary')

    Write-Host ''
    Write-Host '==========================================' -ForegroundColor Cyan
    Write-Host "   $Title" -ForegroundColor Green
    Write-Host '==========================================' -ForegroundColor Cyan

    $summaryLines = @(
        "$Title - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Log folder: $ReportFolder",
        ''
    )

    if ($script:RunFailures.Count -eq 0) {
        Write-Host 'Failed components: none' -ForegroundColor Green
        $summaryLines += 'Failed components: none'
    } else {
        Write-Host 'Failed components:' -ForegroundColor Red
        $summaryLines += 'Failed components:'
        foreach ($failure in $script:RunFailures) {
            Write-Host " - $($failure.Name)" -ForegroundColor Red
            $summaryLines += " - $($failure.Name): $($failure.Reason)"
        }
    }

    $detailedLogs = @(
        'Detailed logs for this run:',
        " - Script action log: $LogPath",
        " - SFC/DISM detail:   $SystemRoot\Logs\CBS\CBS.log",
        " - DISM detail:       $SystemRoot\Logs\DISM\dism.log",
        " - Driver activity:   $SystemRoot\INF\setupapi.dev.log",
        ' - Windows Update:    run "Get-WindowsUpdateLog" in PowerShell to build a readable copy'
    )

    Write-Host ''
    foreach ($line in $detailedLogs) {
        Write-Host $line -ForegroundColor DarkGray
    }

    $summaryLines += ''
    $summaryLines += $detailedLogs

    $summaryLines | Out-File -FilePath $SummaryPath -Encoding UTF8
    Write-Status "Summary saved to $SummaryPath" 'Info'
}

function Invoke-ExternalCommandWithSpinner {
    param(
        [string]$Activity,
        [string]$FilePath,
        [string[]]$Arguments,
        [string[]]$WarningPatterns = @('error', 'failed')
    )

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $spinner = @('|', '/', '-', '\')
    $index = 0
    $started = Get-Date

    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop

        while (-not $process.HasExited) {
            $elapsed = (Get-Date) - $started
            $elapsedText = '{0:00}:{1:00}' -f [int]$elapsed.TotalMinutes, $elapsed.Seconds
            $frame = $spinner[$index % $spinner.Length]
            Write-Host ("`r     {0} {1} ({2} elapsed)" -f $frame, $Activity, $elapsedText) -NoNewline -ForegroundColor DarkCyan
            Write-Progress -Activity $Activity -Status "Still running ($elapsedText elapsed)"
            Start-Sleep -Milliseconds 500
            $index++
            $process.Refresh()
        }

        $process.WaitForExit()
        Write-Host ("`r     {0} finished.                    " -f $Activity) -ForegroundColor DarkCyan

        $lines = @()
        foreach ($path in @($stdoutPath, $stderrPath)) {
            if (Test-Path -LiteralPath $path) {
                $lines += Get-Content -LiteralPath $path -ErrorAction SilentlyContinue
            }
        }

        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            $isWarning = $false
            foreach ($pattern in $WarningPatterns) {
                if ($line -match $pattern) {
                    $isWarning = $true
                    break
                }
            }

            if ($isWarning) {
                Write-Status $line 'Warning'
            } else {
                Write-Host $line
                Write-Log $line
            }
        }

        return $process.ExitCode
    } finally {
        Write-Progress -Activity $Activity -Completed
        foreach ($path in @($stdoutPath, $stderrPath)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    try {
        Write-Status $Name 'Step'
        & $Action
        Write-Status "$Name completed." 'Success'
        return $true
    } catch {
        Write-Status "$Name failed. $($_.Exception.Message)" 'Error'
        return $false
    }
}

function Pause-ForReview {
    param([string]$Message = 'Review the output above, then press Enter to continue')
    Read-Host $Message | Out-Null
}

function Test-DismExitCode {
    # DISM returns 3010 when the operation succeeded but a restart is required.
    param([int]$ExitCode)

    if ($ExitCode -eq 0) { return $true }

    if ($ExitCode -eq 3010) {
        Write-Status 'The operation succeeded, but Windows must restart to finish it.' 'Warning'
        $script:NeedsRestart = $true
        return $true
    }

    return $false
}

function Invoke-RestorePoint {
    Write-Status 'Creating System Restore Point: Before Repair.' 'Step'
    $restoreDrive = [System.IO.Path]::GetPathRoot($SystemRoot)

    try {
        Write-Status "Enabling System Protection on $restoreDrive if needed." 'Info'
        Enable-ComputerRestore -Drive $restoreDrive -ErrorAction Stop
    } catch {
        Write-Status "Could not enable System Protection automatically. $($_.Exception.Message)" 'Warning'
    }

    try {
        Checkpoint-Computer -Description 'Before Repair' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Status 'System Restore Point created.' 'Success'
        return $true
    } catch {
        Write-Status "Could not create a restore point. $($_.Exception.Message)" 'Warning'
        Write-Status 'System Restore may be disabled, or Windows may be enforcing restore-point frequency limits.' 'Warning'
        return $false
    }
}

function Prompt-RestorePoint {
    if (Read-YesNo -Prompt 'Create a System Restore Point before repairs?' -DefaultYes $true) {
        Invoke-RestorePoint | Out-Null
    } else {
        Write-Status 'User skipped System Restore Point creation.' 'Warning'
    }
}

function Request-RestorePointBeforeRepair {
    if ($script:RestorePointPrompted) {
        return
    }

    $script:RestorePointPrompted = $true
    Prompt-RestorePoint
}

function Offer-RestartIfNeeded {
    param([string]$Reason = 'A restart is recommended for the repairs you ran.')

    if (-not $script:NeedsRestart) {
        return
    }

    if (Read-YesNo -Prompt "$Reason Restart your PC now?" -DefaultYes $false) {
        Write-Log 'System restart initiated by user.'
        Restart-Computer -Force
    } else {
        Write-Status 'Restart skipped. Some repairs may not fully apply until the next restart.' 'Warning'
    }

    $script:NeedsRestart = $false
}

function Get-PendingRebootState {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    )

    if (Test-Path $paths[0] -ErrorAction Ignore) { return $true }
    if (Test-Path $paths[1] -ErrorAction Ignore) { return $true }

    try {
        $sessionMgr = Get-ItemProperty -Path $paths[2] -Name PendingFileRenameOperations -ErrorAction Stop
        if ($null -ne $sessionMgr.PendingFileRenameOperations) { return $true }
    } catch {}

    return $false
}

function Write-RemoveItemError {
    param(
        [string]$Target,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $message = $ErrorRecord.Exception.Message
    if ($message -match 'Access.*denied|being used|in use|cannot access the file') {
        Write-Status "Could not clean $Target because one or more files are locked or access was denied." 'Warning'
        Write-Status 'Close any programs using those files, then run this cleanup again if needed.' 'Warning'
    } else {
        Write-Status "Could not clean $Target. $message" 'Warning'
    }
}

function Clear-FolderContents {
    param(
        [string]$Folder,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Folder)) {
        Write-Status "$Label was not found; skipping." 'Info'
        return $true
    }

    try {
        $firstChild = Get-ChildItem -LiteralPath $Folder -Force -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $firstChild) {
            Write-Status "$Label is already empty." 'Info'
            return $true
        }
    } catch {
        Write-Status "Could not read $Label. $($_.Exception.Message)" 'Warning'
        return $false
    }

    # Remove items one at a time so a single locked file does not abort the whole cleanup.
    $failedCount = 0
    $failedNames = @()

    Get-ChildItem -LiteralPath $Folder -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            $failedCount++
            if ($failedNames.Count -lt 3) { $failedNames += $_.Name }
        }
    }

    if ($failedCount -eq 0) {
        Write-Status "Cleaned $Label." 'Success'
        return $true
    }

    $examples = if ($failedNames.Count -gt 0) { " Examples: $($failedNames -join ', ')." } else { '' }
    Write-Status "Cleaned $Label, but $failedCount item(s) were locked or in use and were skipped.$examples" 'Warning'
    Write-Status 'Locked files are normal in temp folders. Close other programs and re-run this cleanup to remove them.' 'Info'
    return $false
}

function Wait-ServiceStatus {
    param(
        [string]$Name,
        [ValidateSet('Running','Stopped')]
        [string]$TargetStatus,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $service = Get-Service -Name $Name -ErrorAction Stop
        if ($service.Status -eq $TargetStatus) {
            return $true
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Stop-ServiceAndWait {
    param([string]$Name)

    try {
        $service = Get-Service -Name $Name -ErrorAction Stop
        if ($service.Status -ne 'Stopped') {
            Write-Status "Stopping service: $Name" 'Info'
            Stop-Service -Name $Name -Force -ErrorAction Stop
        }

        if (Wait-ServiceStatus -Name $Name -TargetStatus 'Stopped') {
            Write-Status "Service stopped: $Name" 'Success'
            return $true
        }

        Write-Status "Timed out waiting for service to stop: $Name" 'Error'
        return $false
    } catch {
        Write-Status "Unable to stop service $Name. $($_.Exception.Message)" 'Error'
        return $false
    }
}

function Start-ServiceAndWait {
    param([string]$Name)

    try {
        $service = Get-Service -Name $Name -ErrorAction Stop
        if ($service.Status -ne 'Running') {
            Write-Status "Starting service: $Name" 'Info'
            Start-Service -Name $Name -ErrorAction Stop
        }

        if (Wait-ServiceStatus -Name $Name -TargetStatus 'Running') {
            Write-Status "Service running: $Name" 'Success'
            return $true
        }

        Write-Status "Timed out waiting for service to start: $Name" 'Warning'
        return $false
    } catch {
        Write-Status "Unable to start service $Name. $($_.Exception.Message)" 'Warning'
        return $false
    }
}

function Rename-WindowsUpdateFolder {
    param([string]$RelativePath)

    $path = Join-Path $SystemRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Status "$RelativePath was not found; skipping." 'Info'
        return $true
    }

    $backupPath = "$path.old"
    if (Test-Path -LiteralPath $backupPath) {
        $backupPath = "$path.old.$(Get-Date -Format 'yyyyMMddHHmmss')"
    }

    try {
        Rename-Item -LiteralPath $path -NewName (Split-Path $backupPath -Leaf) -ErrorAction Stop
        Write-Status "Renamed $path to $backupPath." 'Success'
        return $true
    } catch {
        Write-Status "Could not rename $path. $($_.Exception.Message)" 'Error'
        return $false
    }
}

function Remove-StaleUpdateFolders {
    Write-Status 'Removing stale update cache backups from previous resets.' 'Step'

    $patterns = @('SoftwareDistribution.old*', 'System32\catroot2.old*')
    $staleFolders = @()
    foreach ($pattern in $patterns) {
        $staleFolders += @(Get-ChildItem -Path (Join-Path $SystemRoot $pattern) -Directory -Force -ErrorAction SilentlyContinue)
    }

    if ($staleFolders.Count -eq 0) {
        Write-Status 'No stale update cache backups found.' 'Success'
        return $true
    }

    $bytes = 0
    foreach ($folder in $staleFolders) {
        $files = @(Get-ChildItem -LiteralPath $folder.FullName -Recurse -Force -File -ErrorAction SilentlyContinue)
        $sum = ($files | Measure-Object -Property Length -Sum).Sum
        if ($null -ne $sum) { $bytes += $sum }
    }

    $purgeOk = $true
    foreach ($folder in $staleFolders) {
        try {
            Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction Stop
            Write-Status "Removed stale backup: $($folder.FullName)" 'Success'
        } catch {
            $purgeOk = $false
            Write-RemoveItemError -Target $folder.FullName -ErrorRecord $_
        }
    }

    $freedText = '{0:N2} GB' -f ($bytes / 1GB)
    if ($purgeOk) {
        Write-Status "Stale update backups removed. Recovered approximately $freedText." 'Success'
    } else {
        Write-Status "Stale update backup cleanup finished with warnings. Recovered approximately $freedText so far." 'Warning'
    }

    return $purgeOk
}

function Invoke-UptimeCheck {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $bootTime = $os.LastBootUpTime
        $uptime = (Get-Date) - $bootTime
        $uptimeText = '{0} day(s), {1} hour(s), {2} minute(s)' -f [int][math]::Floor($uptime.TotalDays), $uptime.Hours, $uptime.Minutes

        Write-Status "Real shutdown uptime: $uptimeText since $($bootTime.ToString('yyyy-MM-dd HH:mm'))." 'Info'

        if ($uptime.TotalDays -ge 1) {
            Write-Status 'Windows Fast Startup can keep the kernel running for days. A restart may clear stale repair/update state.' 'Warning'
            $script:NeedsRestart = $true

            if (-not $script:FullRepairMode) {
                Offer-RestartIfNeeded -Reason 'Kernel uptime is over one day.'
            }
        }

        return $true
    } catch {
        Write-Status "Unable to check uptime. $($_.Exception.Message)" 'Warning'
        return $false
    }
}

function Invoke-PendingUpdateCheck {
    Write-Status 'Checking for pending Windows updates. This can take a few minutes.' 'Step'

    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search("IsInstalled=0 and Type='Software'")
        $count = $result.Updates.Count

        if ($count -eq 0) {
            Write-Status 'No pending software updates were reported by Windows Update.' 'Success'
            return $true
        }

        Write-Status "$count pending software update(s) found." 'Warning'
        $maxToShow = [Math]::Min($count, 5)
        for ($i = 0; $i -lt $maxToShow; $i++) {
            Write-Status "Pending update: $($result.Updates.Item($i).Title)" 'Info'
        }

        if ($count -gt $maxToShow) {
            Write-Status "Only showing the first $maxToShow pending updates." 'Info'
        }

        return $true
    } catch {
        Write-Status "Unable to query Windows Update. $($_.Exception.Message)" 'Warning'
        return $false
    }
}

function Invoke-BatteryHealthCheck {
    $batteries = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
    if ($batteries.Count -eq 0) {
        return $true
    }

    $statusText = @{
        1 = 'Discharging'
        2 = 'AC power'
        3 = 'Fully charged'
        4 = 'Low'
        5 = 'Critical'
        6 = 'Charging'
        7 = 'Charging and high'
        8 = 'Charging and low'
        9 = 'Charging and critical'
        10 = 'Undefined'
        11 = 'Partially charged'
    }

    foreach ($battery in $batteries) {
        $status = $statusText[[int]$battery.BatteryStatus]
        if ([string]::IsNullOrWhiteSpace($status)) {
            $status = "Status code $($battery.BatteryStatus)"
        }

        Write-Status "Battery: $status, estimated charge $($battery.EstimatedChargeRemaining)%." 'Info'
    }

    try {
        $exitCode = Invoke-ExternalCommandWithSpinner -Activity 'Battery health report' -FilePath 'powercfg.exe' -Arguments @('/batteryreport', '/output', $BatteryReportPath) -WarningPatterns @('error', 'failed')
        if ($exitCode -ne 0) {
            throw "powercfg exited with code $exitCode."
        }

        Write-Status "Battery health report saved to $BatteryReportPath" 'Success'
        return $true
    } catch {
        Write-Status "Unable to create battery health report. $($_.Exception.Message)" 'Warning'
        return $false
    }
}

function Invoke-StoreCacheReset {
    Write-Status 'Resetting Microsoft Store cache.' 'Step'

    try {
        Write-Status 'A Microsoft Store reset window may open and close automatically. This can take up to a minute.' 'Info'
        Start-Process -FilePath 'wsreset.exe' -Wait -ErrorAction Stop
        Write-Status 'Microsoft Store cache reset completed.' 'Success'
        return $true
    } catch {
        Write-Status "Microsoft Store cache reset failed. $($_.Exception.Message)" 'Warning'
        return $false
    }
}

function Export-SystemErrors {
    Write-Status 'Exporting recent System errors.' 'Info'

    $startTime = (Get-Date).AddHours(-24)
    $lines = @(
        "System Error Events - Last 24 Hours",
        "This report lists Windows System log entries marked as Error or Critical during the last 24 hours.",
        "Use it to spot failing drivers, services, hardware warnings, update failures, and other clues before or after repairs.",
        "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Source log: System",
        ''
    )

    $events = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $startTime } -ErrorAction Stop)
    } catch {
        # FullyQualifiedErrorId is locale-independent; the exception message text is not.
        if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound') {
            Write-Status "Could not export System errors. $($_.Exception.Message)" 'Warning'
            return $false
        }
    }

    if ($events.Count -eq 0) {
        $lines += 'No System error or critical events were found in the last 24 hours.'
        Write-Status 'No System error or critical events found in the last 24 hours.' 'Success'
    } else {
        foreach ($event in $events) {
            $message = ($event.Message -replace '\s+', ' ').Trim()
            $lines += "[$($event.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] $($event.ProviderName) - Event ID $($event.Id)"
            $lines += $message
            $lines += ''
        }

        Write-Status "$($events.Count) System error/critical event(s) exported." 'Success'
    }

    $lines | Out-File -FilePath $SystemErrorExportPath -Encoding UTF8
    Write-Status "System error export saved to $SystemErrorExportPath" 'Success'
    return $true
}

function Invoke-DriverStoreCleanup {
    if (-not (Confirm-TaskStart -Name 'Driver Store Cleanup' -Details 'Driver Store Cleanup removes old driver packages for non-present devices without using force. Windows may refuse any package still in use.')) {
        return $true
    }

    Request-RestorePointBeforeRepair
    Write-Status 'Looking for old driver packages tied to non-present devices.' 'Step'
    $report = @(
        "Driver Store Cleanup - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        'Mode: pnputil delete-driver without /force',
        ''
    )

    try {
        $devices = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.ConfigManagerErrorCode -eq 45 })
    } catch {
        Write-Status "Unable to enumerate non-present devices. $($_.Exception.Message)" 'Warning'
        return $false
    }

    if ($devices.Count -eq 0) {
        $report += 'No non-present devices were reported by Windows.'
        $report | Out-File -FilePath $DriverCleanupReportPath -Encoding UTF8
        Write-Status 'No non-present devices found.' 'Success'
        return $true
    }

    $driverInfs = @()
    foreach ($device in $devices) {
        try {
            $property = Get-PnpDeviceProperty -InstanceId $device.PNPDeviceID -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction Stop
            $infName = [string]$property.Data
            if ($infName -match '^oem\d+\.inf$') {
                $driverInfs += $infName
            }
        } catch {}
    }

    $driverInfs = @($driverInfs | Sort-Object -Unique)
    if ($driverInfs.Count -eq 0) {
        $report += 'Non-present devices were found, but no removable oem*.inf driver packages were identified.'
        $report | Out-File -FilePath $DriverCleanupReportPath -Encoding UTF8
        Write-Status 'No removable old driver packages were identified.' 'Success'
        return $true
    }

    $cleanupOk = $true
    foreach ($infName in $driverInfs) {
        $report += "Attempting: pnputil /delete-driver $infName /uninstall"
        $exitCode = Invoke-ExternalCommandWithSpinner -Activity "Remove old driver package $infName" -FilePath 'pnputil.exe' -Arguments @('/delete-driver', $infName, '/uninstall') -WarningPatterns @('failed', 'error', 'not deleted')

        if ($exitCode -eq 0) {
            $report += "Result: removed $infName"
            Write-Status "Removed old driver package: $infName" 'Success'
        } else {
            $cleanupOk = $false
            $report += "Result: pnputil exited with code $exitCode for $infName"
            Write-Status "Could not remove $infName. Windows may still need it." 'Warning'
        }

        $report += ''
    }

    $report | Out-File -FilePath $DriverCleanupReportPath -Encoding UTF8
    Write-Status "Driver cleanup report saved to $DriverCleanupReportPath" 'Info'
    return $cleanupOk
}

function Show-Menu {
    # ASCII banner (avoids all Unicode/encoding problems; keep this file ANSI or UTF-8 without BOM)
    $banner = @'
 ==============================================================
 |            W I N   R E P A I R   U T I L I T Y             |
 |      Windows maintenance, repair, and cleanup toolkit      |
 ==============================================================
'@

    Write-Host "$banner" -ForegroundColor Cyan
    Write-Host ' Note: this tool requires Windows 8.1 or newer and administrator rights.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [0] Review System Health and Updates' -ForegroundColor DarkCyan
    Write-Host '  [1] Clear Temporary and Store Caches'
    Write-Host '  [2] Repair Windows System Files and Component Store'
    Write-Host '  [3] Fix Windows Update Problems (Reset Update Cache)'
    Write-Host '  [4] Fix Internet Connection Issues (DNS/Winsock/TCP/IP Reset)'
    Write-Host '  [5] Export System Errors from Last 24 Hours' -ForegroundColor DarkCyan
    Write-Host '  [6] Free Up Disk Space (Disk Cleanup)'
    Write-Host '  [7] Check Disk for Errors (Read-Only chkdsk /scan)'
    Write-Host '  [8] Run Full Repair Checklist' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  [D] Remove Old Non-Present Drivers' -ForegroundColor Yellow
    Write-Host '  [R] Create Restore Point (Backup)' -ForegroundColor Yellow
    Write-Host '  [G] Open Command Guide' -ForegroundColor Yellow
    Write-Host '  [Q] Quit Script' -ForegroundColor Red
    Write-Host ''
    Write-Host "  Logs: $ReportFolder" -ForegroundColor DarkCyan
}

function Invoke-QuickClean {
    Write-Status 'Removing temporary files and cache locations.' 'Step'
    $paths = @(
        @{ Folder = $env:TEMP; Label = 'current user temp files' },
        @{ Folder = (Join-Path $SystemRoot 'Temp'); Label = 'Windows temp files' }
    )

    $cleanOk = $true
    foreach ($path in $paths) {
        if (-not (Clear-FolderContents -Folder $path.Folder -Label $path.Label)) {
            $cleanOk = $false
        }
    }

    if (-not (Invoke-StoreCacheReset)) {
        $cleanOk = $false
    }

    if ($cleanOk) {
        Write-Status 'Cache cleanup finished.' 'Success'
    } else {
        Write-Status 'Cache cleanup finished with warnings.' 'Warning'
    }

    return $cleanOk
}

function Invoke-SystemRepair {
    if (-not (Confirm-TaskStart -Name 'System Repair' -Details 'System Repair can take 10-30 minutes. You can cancel here before DISM starts.')) {
        return $true
    }

    Request-RestorePointBeforeRepair
    Write-Status 'Running DISM and SFC to repair Windows system files.' 'Step'
    $repairOk = $true

    if (-not (Invoke-Step 'DISM RestoreHealth scan' {
        $exitCode = Invoke-ExternalCommandWithSpinner -Activity 'DISM RestoreHealth scan' -FilePath 'dism.exe' -Arguments @('/online', '/cleanup-image', '/restorehealth') -WarningPatterns @('error', 'failed')
        if (-not (Test-DismExitCode -ExitCode $exitCode)) {
            throw "DISM exited with code $exitCode."
        }
    })) {
        $repairOk = $false
    }

    if (-not (Invoke-Step 'SFC system file scan' {
        $exitCode = Invoke-ExternalCommandWithSpinner -Activity 'SFC system file scan' -FilePath 'sfc.exe' -Arguments @('/scannow') -WarningPatterns @('could not repair', 'failed')

        switch ($exitCode) {
            0 { Write-Status 'SFC found no integrity violations.' 'Success' }
            1 { Write-Status 'SFC found corruption and repaired it.' 'Success' }
            2 { throw 'SFC found corruption but could not repair it.' }
            default { throw "SFC exited with code $exitCode." }
        }
    })) {
        $repairOk = $false
    }

    $useResetBase = $false
    if ($script:FullRepairMode) {
        Write-Status 'Deep component cleanup (/ResetBase) skipped in Full Repair mode. Run option 2 alone to opt in.' 'Info'
    } else {
        Write-Host ''
        Write-Status 'Optional deep cleanup: /ResetBase removes all superseded update components permanently.' 'Warning'
        Write-Status 'After it runs, currently installed Windows updates can no longer be uninstalled.' 'Warning'
        Write-Status 'Skip it unless Windows is stable and you need the extra disk space.' 'Info'
        $useResetBase = Read-YesNo -Prompt 'Include /ResetBase deep cleanup?' -DefaultYes $false
    }

    $cleanupArgs = @('/online', '/cleanup-image', '/startcomponentcleanup')
    if ($useResetBase) {
        $cleanupArgs += '/resetbase'
    }

    if (-not (Invoke-Step 'Component Store Cleanup' {
        $exitCode = Invoke-ExternalCommandWithSpinner -Activity 'Component Store Cleanup' -FilePath 'dism.exe' -Arguments $cleanupArgs -WarningPatterns @('error', 'failed')
        if (-not (Test-DismExitCode -ExitCode $exitCode)) {
            throw "DISM component cleanup exited with code $exitCode."
        }
    })) {
        $repairOk = $false
    }

    if ($repairOk) {
        if ($useResetBase) {
            Write-Status 'Deep component cleanup was applied. Installed updates can no longer be uninstalled.' 'Warning'
        }
        Write-Status 'System file integrity work finished.' 'Success'
    } else {
        Write-Status 'System file integrity work finished with errors. Review the output above.' 'Error'
    }

    return $repairOk
}

function Invoke-UpdateReset {
    if (-not (Confirm-TaskStart -Name 'Windows Update Reset' -Details 'Windows Update Reset stops update services, purges old cache backups, and renames update cache folders so Windows rebuilds them. You can cancel here before changes begin.')) {
        return $true
    }

    Request-RestorePointBeforeRepair
    Write-Status 'Resetting Windows Update services and cache.' 'Step'

    Remove-StaleUpdateFolders | Out-Null

    $services = @('wuauserv', 'bits', 'cryptsvc')
    $stopped = $true
    foreach ($service in $services) {
        if (-not (Stop-ServiceAndWait -Name $service)) {
            $stopped = $false
        }
    }

    if ($stopped) {
        if (-not (Rename-WindowsUpdateFolder -RelativePath 'SoftwareDistribution')) {
            $stopped = $false
        }
        if (-not (Rename-WindowsUpdateFolder -RelativePath 'System32\catroot2')) {
            $stopped = $false
        }
    } else {
        Write-Status 'Skipping cache rename because one or more update services did not stop.' 'Error'
    }

    $started = $true
    foreach ($service in @('cryptsvc', 'bits', 'wuauserv')) {
        if (-not (Start-ServiceAndWait -Name $service)) {
            $started = $false
        }
    }

    $script:NeedsRestart = $true
    if ($stopped -and $started) {
        Write-Status 'Windows Update reset completed.' 'Success'
        return $true
    }

    Write-Status 'Windows Update reset finished with errors.' 'Error'
    return $false
}

function Invoke-NetworkReset {
    if (-not (Confirm-TaskStart -Name 'Network Reset' -Details 'Network Reset flushes the DNS cache and resets Winsock and TCP/IP. Your internet may drop briefly. VPN or remote desktop sessions can be interrupted, and static IP/DNS settings may be reset to automatic.')) {
        return $true
    }

    Request-RestorePointBeforeRepair
    Write-Status 'Your internet may disconnect for a few seconds while networking resets.' 'Warning'
    Write-Status 'If you use a static IP address or custom DNS servers, you may need to re-enter them afterwards.' 'Warning'
    Write-Status 'Flushing DNS, Winsock, and TCP/IP stack.' 'Step'

    $dnsOk = Invoke-Step 'Flush DNS cache' {
        ipconfig /flushdns | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "ipconfig exited with code $LASTEXITCODE." }
    }
    $winsockOk = Invoke-Step 'Fix Internet Connection Issues (Winsock Reset)' {
        netsh winsock reset | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "netsh winsock exited with code $LASTEXITCODE." }
    }
    $tcpOk = Invoke-Step 'Repair TCP/IP Network Stack' {
        netsh int ip reset | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "netsh int ip exited with code $LASTEXITCODE." }
    }

    $script:NeedsRestart = $true
    if ($dnsOk -and $winsockOk -and $tcpOk) {
        Write-Status 'Network reset completed. A reboot may be required.' 'Success'
        return $true
    }

    Write-Status 'Network reset finished with errors. A reboot may still be required.' 'Error'
    return $false
}

function Invoke-DiskCleanup {
    try {
        if ($script:FullRepairMode) {
            Write-Status 'Running automatic Disk Cleanup. Note: this silently empties the Recycle Bin.' 'Warning'
            Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/verylowdisk' -Wait -ErrorAction Stop
            return $true
        }

        Write-Status 'Opening Disk Cleanup setup in a new window. Select what to clean, then click OK.' 'Info'
        Start-Process -FilePath 'cleanmgr.exe' -ErrorAction Stop
        return $true
    } catch {
        Write-Status "Could not open Disk Cleanup. $($_.Exception.Message)" 'Error'
        return $false
    }
}

function Invoke-DiskCheck {
    if (-not (Confirm-TaskStart -Name 'Disk Error Scan' -Details 'Disk Error Scan runs a read-only online check (chkdsk /scan) of the system drive. It does not lock or modify the disk during the scan.')) {
        return $true
    }

    Write-Status 'Running read-only disk scan. This can take several minutes.' 'Step'
    $exitCode = Invoke-ExternalCommandWithSpinner -Activity 'chkdsk online scan' -FilePath 'chkdsk.exe' -Arguments @($env:SystemDrive, '/scan') -WarningPatterns @('error', 'corrupt', 'failed')

    if ($exitCode -eq 0) {
        Write-Status 'chkdsk found no file system errors.' 'Success'
        return $true
    }

    # Exit code 2 means minor cleanup items only (e.g. unused index entries), not corruption.
    if ($exitCode -eq 2) {
        Write-Status 'chkdsk completed; only minor cleanup items were reported, no corruption was found.' 'Success'
        return $true
    }

    Write-Status "chkdsk detected issues (exit code $exitCode)." 'Warning'

    $scheduleFix = $false
    if ($script:FullRepairMode) {
        $scheduleFix = $true
    } else {
        $scheduleFix = Read-YesNo -Prompt 'Schedule an automatic spot fix at the next restart?' -DefaultYes $false
    }

    if (-not $scheduleFix) {
        Write-Status 'No fix scheduled. You can re-run this option later.' 'Warning'
        return $false
    }

    Write-Status 'Scheduling the spot fix. The chkdsk confirmation prompt is answered automatically.' 'Info'
    & cmd.exe /c "echo y| chkdsk.exe $env:SystemDrive /spotfix"
    $spotfixExit = $LASTEXITCODE
    $script:NeedsRestart = $true

    if ($spotfixExit -eq 0) {
        Write-Status 'Disk spot fix scheduled for the next restart.' 'Success'
        return $true
    }

    Write-Status "chkdsk spot fix exited with code $spotfixExit. Review the chkdsk messages above." 'Warning'
    return $true
}

function Invoke-SystemHealthOverview {
    Write-Status 'Running system health, uptime, battery, and update checks.' 'Step'
    $healthOk = $true

    $systemDriveName = ([System.IO.Path]::GetPathRoot($SystemRoot)).TrimEnd('\').TrimEnd(':')
    $systemDrive = Get-PSDrive -Name $systemDriveName -ErrorAction Ignore
    if ($null -ne $systemDrive) {
        $freeGB = [math]::Round($systemDrive.Free / 1GB, 2)
        Write-Status "$($systemDrive.Name): free space is $freeGB GB." 'Info'
        if ($freeGB -lt 8) {
            Write-Status 'Low disk space can cause update and repair failures.' 'Warning'
        }
    }

    if (Get-PendingRebootState) {
        Write-Status 'Pending reboot detected. Restarting first may prevent repair errors.' 'Warning'
    } else {
        Write-Status 'No pending reboot markers found.' 'Success'
    }

    if (-not (Invoke-UptimeCheck)) {
        $healthOk = $false
    }

    if (-not (Invoke-PendingUpdateCheck)) {
        $healthOk = $false
    }

    if (-not (Invoke-BatteryHealthCheck)) {
        $healthOk = $false
    }

    try {
        $disks = Get-PhysicalDisk -ErrorAction Stop | Select-Object FriendlyName, HealthStatus, OperationalStatus
        $diskText = $disks | Format-Table -AutoSize | Out-String
        Write-Host $diskText -ForegroundColor Yellow
        Write-Log "Disk Health:`n$diskText"
    } catch {
        $healthOk = $false
        Write-Status "Unable to retrieve physical disk info. $($_.Exception.Message)" 'Warning'
    }

    return $healthOk
}

"Repair Session Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | User: $env:USERDOMAIN\$env:USERNAME" | Out-File -FilePath $LogPath -Encoding UTF8

# Warn if the tool was elevated under a different administrator account
try {
    $consoleUser = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
    if (-not [string]::IsNullOrWhiteSpace($consoleUser) -and ($consoleUser -ne "$env:USERDOMAIN\$env:USERNAME")) {
        Write-Status "You elevated this tool as a different administrator account ($env:USERNAME)." 'Warning'
        Write-Status "Logs will be saved to THIS account's Desktop, and the logged-on user's temp files will not be cleaned." 'Warning'
    }
} catch {}

do {
    Clear-Host
    Show-Menu
    $choice = Read-MenuChoice
    $skipPause = $false

    switch ($choice) {
        '0' { Invoke-SystemHealthOverview | Out-Null }
        '1' { Invoke-QuickClean | Out-Null }
        '2' { Invoke-SystemRepair | Out-Null }
        '3' { Invoke-UpdateReset | Out-Null }
        '4' { Invoke-NetworkReset | Out-Null }
        '5' { Export-SystemErrors | Out-Null }
        '6' {
            Invoke-DiskCleanup | Out-Null
            $skipPause = $true
        }
        '7' { Invoke-DiskCheck | Out-Null }
        '8' {
            $skipPause = $true

            Write-Host ''
            Write-Status 'The Full Repair Checklist will run all of the following automatically:' 'Warning'
            Write-Status ' - System health, disk health, and pending update checks' 'Info'
            Write-Status ' - Temp file and Microsoft Store cache cleanup' 'Info'
            Write-Status ' - DISM RestoreHealth, SFC scan, and component store cleanup' 'Info'
            Write-Status ' - Windows Update cache reset (services stopped and folders renamed)' 'Info'
            Write-Status ' - Network reset: DNS, Winsock, TCP/IP (may drop VPN/remote sessions and reset static IP/DNS settings)' 'Warning'
            Write-Status ' - Read-only disk scan; if errors are found, a chkdsk spot fix is scheduled for the next restart' 'Warning'
            Write-Status ' - Automatic Disk Cleanup, which silently empties the Recycle Bin and other caches' 'Warning'
            Write-Status ' - Removal of old driver packages for devices that are not currently present' 'Warning'
            Write-Status ' - Export of System error events from the last 24 hours' 'Info'
            Write-Host ''
            Write-Status 'The full run can take 30 to 90 minutes. A restart is recommended afterwards.' 'Warning'

            if (-not (Read-YesNo -Prompt 'Start the Full Repair Checklist now?' -DefaultYes $false)) {
                Write-Status 'Full Repair Checklist canceled. Returning to the menu.' 'Info'
                break
            }

            $script:RunFailures = @()
            Request-RestorePointBeforeRepair

            try {
                $script:FullRepairMode = $true
                Invoke-TrackedTask 'Review System Health and Updates' { Invoke-SystemHealthOverview } | Out-Null
                Invoke-TrackedTask 'Clear Temporary and Store Caches' { Invoke-QuickClean } | Out-Null
                Invoke-TrackedTask 'Repair Windows System Files (DISM/SFC and Component Cleanup)' { Invoke-SystemRepair } | Out-Null
                Invoke-TrackedTask 'Fix Windows Update Problems (Reset Update Cache)' { Invoke-UpdateReset } | Out-Null
                Invoke-TrackedTask 'Fix Internet Connection Issues (DNS/Winsock/TCP/IP Reset)' { Invoke-NetworkReset } | Out-Null
                Invoke-TrackedTask 'Check Disk for Errors (Read-Only chkdsk /scan)' { Invoke-DiskCheck } | Out-Null
                Invoke-TrackedTask 'Free Up Disk Space (Windows Disk Cleanup)' { Invoke-DiskCleanup } | Out-Null
                Invoke-TrackedTask 'Remove Old Non-Present Drivers' { Invoke-DriverStoreCleanup } | Out-Null
                Invoke-TrackedTask 'Export System Errors from Last 24 Hours' { Export-SystemErrors } | Out-Null
            } finally {
                $script:FullRepairMode = $false
            }

            Show-RunSummary -Title 'Full Repair Checklist Summary'
            Offer-RestartIfNeeded
        }
        'D' { Invoke-DriverStoreCleanup | Out-Null }
        'R' {
            Invoke-RestorePoint | Out-Null
            $script:RestorePointPrompted = $true
        }
        'G' {
            Start-Process 'https://github.com/gvqz/winrepair'
            $skipPause = $true
        }
        'Q' {
            Write-Status 'Exiting repair utility.' 'Info'
            break
        }
    }

    if (($choice -ne 'Q') -and (-not $skipPause)) {
        Pause-ForReview "`nTask finished. Review the output above, then press Enter to return to menu"
    }
} while ($choice -ne 'Q')

Offer-RestartIfNeeded
Pause-ForReview 'Press Enter to close this window'