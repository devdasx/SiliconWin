@echo off
rem SiliconWin guest tools installer.
rem Runs automatically at the end of Windows Setup; you can also run it again
rem as administrator from the SILICONWIN disc.
setlocal
set "SRC=%~dp0"
set "DEST=%ProgramFiles%\SiliconWin"

echo Installing SiliconWin guest tools from %SRC%
if not exist "%DEST%" mkdir "%DEST%"
copy /y "%SRC%agent.ps1" "%DEST%\agent.ps1" >nul
copy /y "%SRC%agent-host.ps1" "%DEST%\agent-host.ps1" >nul
copy /y "%SRC%register-agent.ps1" "%DEST%\register-agent.ps1" >nul
copy /y "%SRC%README.txt" "%DEST%\README.txt" >nul

rem VirtIO drivers (network, entropy, serial, balloon, ...) that are not installed yet.
if exist "%SRC%..\$WinPEDriver$" pnputil /add-driver "%SRC%..\$WinPEDriver$\*.inf" /subdirs /install

rem A virtual machine should not sleep, hibernate or turn its screen off by itself.
powercfg /hibernate off
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change disk-timeout-ac 0

rem Tell SiliconWin on the Mac that Windows finished installing (before the
rem host relay below takes over the serial port).
echo install-complete> \\.\Global\org.siliconwin.agent.0

rem Host relay (SYSTEM, owns the serial port) + per-user agent (clipboard, files from the Mac).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DEST%\register-agent.ps1" -InstallDir "%DEST%"
echo Done.
exit /b 0
