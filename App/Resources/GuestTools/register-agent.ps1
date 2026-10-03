# Sets up SiliconWin's guest agent:
#   * "SiliconWin Host" scheduled task: agent-host.ps1 as SYSTEM at startup (owns the serial port)
#   * Run key: agent.ps1 in every user's session at sign-in (clipboard, files)
param([Parameter(Mandatory = $true)][string] $InstallDir)

$hostArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\agent-host.ps1`""
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $hostArgs
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'SiliconWin Host' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

# Earlier versions used an elevated per-user task.
Unregister-ScheduledTask -TaskName 'SiliconWin Agent' -Confirm:$false -ErrorAction SilentlyContinue

Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'SiliconWinAgent' `
    -Value "conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\agent.ps1`""

Stop-ScheduledTask -TaskName 'SiliconWin Host' -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName 'SiliconWin Host'
Write-Output 'SiliconWin agent registered (host relay started).'
