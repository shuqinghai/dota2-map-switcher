@echo off
setlocal

REM Always run from the folder containing this BAT file.
cd /d "%~dp0"

REM Run the PowerShell one-click build script.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Release.ps1"

set "EXITCODE=%ERRORLEVEL%"
echo.

if "%EXITCODE%"=="0" (
    echo Build completed successfully.
    echo Output folder: %~dp0dist
) else (
    echo Build failed. Exit code: %EXITCODE%
)

echo.
pause
exit /b %EXITCODE%
