@echo off
echo Requesting administrator privileges...
powershell.exe -ExecutionPolicy Bypass -NoProfile -Command "try { $p = Start-Process powershell.exe -ArgumentList '-ExecutionPolicy Bypass -NoProfile -File ""%~dp0Set-BitLockerRDVPolicy.ps1""' -Verb RunAs -Wait -PassThru; exit $p.ExitCode } catch { Write-Host 'Elevation was denied or failed.' -ForegroundColor Red; exit 1 }"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ERROR: Elevation was denied or the script encountered an error.
    pause
)
