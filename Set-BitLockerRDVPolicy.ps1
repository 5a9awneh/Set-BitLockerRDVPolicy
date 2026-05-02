#Requires -RunAsAdministrator

param(
    [switch]$SkipTaskReg,
    [switch]$Uninstall
)

$TaskName = "Fix-BitLockerRDVPolicy"
$InstallDir = "$env:ProgramData\Fix-BitLockerRDV"
$ScriptDest = "$InstallDir\Fix-BitLockerRDV.ps1"
$LogFile = "$InstallDir\fix.log"

# --- Persistent logging (captures output under SYSTEM and interactive runs) ---
$null = New-Item -ItemType Directory -Path $InstallDir -Force -ErrorAction SilentlyContinue
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 5MB) {
    Rename-Item -Path $LogFile -NewName 'fix.log.old' -Force -ErrorAction SilentlyContinue
}
Start-Transcript -Path $LogFile -Append

# --- Ensure Windows Event Log source exists ---
$EventSource = 'Fix-BitLockerRDV'
if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
    New-EventLog -Source $EventSource -LogName 'Application' -ErrorAction SilentlyContinue
}

# --- Uninstall ---
if ($Uninstall) {
    Write-Host 'Uninstalling Fix-BitLockerRDV...' -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-EventLog -Source $EventSource -ErrorAction SilentlyContinue
    Write-Host 'Task and event source removed.' -ForegroundColor Green
    Stop-Transcript
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}

# --- Apply the fix ---
function Invoke-BitLockerFix {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FVE"
    $key = "RDVDenyWriteAccess"
    try {
        $current = (Get-ItemProperty -Path $regPath -Name $key -ErrorAction Stop).$key
        if ($current -ne 0) {
            Set-ItemProperty -Path $regPath -Name $key -Value 0 -Type DWord -Force
            $msg = "$key set to 0 (was $current)."
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" -ForegroundColor Green
            Write-EventLog -LogName Application -Source $EventSource -EntryType Information -EventId 1000 -Message $msg -ErrorAction SilentlyContinue
        }
        else {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $key already 0, no change needed." -ForegroundColor Cyan
        }
        return $true
    }
    catch [System.Security.SecurityException] {
        $msg = "Access denied writing registry key: $($_.Exception.Message)"
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" -ForegroundColor Red
        Write-EventLog -LogName Application -Source $EventSource -EntryType Error -EventId 1001 -Message $msg -ErrorAction SilentlyContinue
        return $false
    }
    catch [System.UnauthorizedAccessException] {
        $msg = "Access denied writing registry key: $($_.Exception.Message)"
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" -ForegroundColor Red
        Write-EventLog -LogName Application -Source $EventSource -EntryType Error -EventId 1001 -Message $msg -ErrorAction SilentlyContinue
        return $false
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        $msg = "Registry key not found: $regPath\$key"
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" -ForegroundColor Yellow
        Write-EventLog -LogName Application -Source $EventSource -EntryType Warning -EventId 1002 -Message $msg -ErrorAction SilentlyContinue
        return $false
    }
    catch {
        $msg = "Unexpected error [$($_.Exception.GetType().Name)]: $($_.Exception.Message)"
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" -ForegroundColor Yellow
        Write-EventLog -LogName Application -Source $EventSource -EntryType Error -EventId 1001 -Message $msg -ErrorAction SilentlyContinue
        return $false
    }
}

# --- Register scheduled task (30-min poll + device-arrival trigger, runs as SYSTEM) ---
function Register-Task {
    if ([string]::IsNullOrEmpty($PSCommandPath)) {
        Write-Host "Cannot install: script path unknown (run via -File, not -Command)." -ForegroundColor Red
        return
    }

    # Self-copy to permanent location so the original source file can be deleted
    if ($PSCommandPath -ine $ScriptDest) {
        Copy-Item -Path $PSCommandPath -Destination $ScriptDest -Force
        Write-Host "Script installed to '$ScriptDest' - the original source file can now be deleted." -ForegroundColor Cyan
    }

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Write-Host "Scheduled task '$TaskName' already exists. Skipping creation." -ForegroundColor Cyan
        return
    }

    # Enable Kernel-PnP/Configuration log so the device-arrival event trigger fires
    try {
        $pnpLog = New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration 'Microsoft-Windows-Kernel-PnP/Configuration'
        if (-not $pnpLog.IsEnabled) {
            $pnpLog.IsEnabled = $true
            $pnpLog.SaveChanges()
            Write-Host "Enabled 'Microsoft-Windows-Kernel-PnP/Configuration' log for device-arrival trigger." -ForegroundColor Cyan
        }
    }
    catch {
        Write-Host "Note: Could not enable Kernel-PnP/Configuration log - device-arrival trigger may not fire." -ForegroundColor Yellow
    }

    # Task XML: dual triggers - 30-min repetition + device-arrival (Kernel-PnP EventID 400, 5s delay)
    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Resets RDVDenyWriteAccess after Intune policy re-tattoo. Fires every 30 min and on storage device arrival.</Description>
  </RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <Repetition>
        <Interval>PT30M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>2000-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-Kernel-PnP/Configuration"&gt;&lt;Select Path="Microsoft-Windows-Kernel-PnP/Configuration"&gt;*[System[EventID=400]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
      <Delay>PT5S</Delay>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "$ScriptDest" -SkipTaskReg</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    Register-ScheduledTask -TaskName $TaskName -Xml $taskXml -Force | Out-Null
    Write-Host "Scheduled task '$TaskName' registered (30-min poll + device-arrival trigger, runs as SYSTEM)." -ForegroundColor Green
}

# --- Entry point ---
$success = Invoke-BitLockerFix

if (-not $SkipTaskReg) {
    Register-Task
    Write-Host ""
    Write-Host "Done. Reconnect your external drive now if it's already plugged in." -ForegroundColor White
    Start-Sleep -Seconds 3
}

Stop-Transcript
if (-not $success) { exit 1 }
