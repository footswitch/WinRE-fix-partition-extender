@echo off
setlocal EnableExtensions
title Move WinRE and Extend C:

rem ---------------------------------------------------------------------------
rem Move-WinRE-And-Extend launcher
rem
rem Keep this .BAT file in the same folder as:
rem     Move-WinRE-And-Extend.ps1
rem
rem Options:
rem   1 - Dry run
rem   2 - Execute (PowerShell script still requires RELAYOUT confirmation)
rem   3 - WinRE confirmation / recovery
rem   4 - Unblock the PowerShell script
rem ---------------------------------------------------------------------------

set "SCRIPT=%~dp0Move-WinRE-And-Extend.ps1"

rem --- Ensure the PowerShell script exists -----------------------------------
if not exist "%SCRIPT%" (
    echo.
    echo ERROR: PowerShell script not found:
    echo   "%SCRIPT%"
    echo.
    echo Keep this BAT file in the same folder as Move-WinRE-And-Extend.ps1
    echo.
    pause
    exit /b 1
)

rem --- Ensure Administrator rights -------------------------------------------
net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo Requesting Administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
        "Start-Process -FilePath '%ComSpec%' -ArgumentList '/c','""%~f0""' -Verb RunAs"
    exit /b
)

:MENU
cls
echo ============================================================
echo   Move WinRE and Extend Windows Partition
echo ============================================================
echo.
echo PowerShell script:
echo   %SCRIPT%
echo.
echo   [1] Dry run
echo       Analyse only. No partition changes.
echo.
echo   [2] Execute
echo       Run the partition operation.
echo       You will STILL have to type RELAYOUT in PowerShell
echo       before any destructive action begins.
echo.
echo   [3] WinRE confirmation / recovery
echo       Verify the current WinRE setup and repair registration if needed.
echo       This mode does NOT delete, create, shrink, or resize partitions.
echo.
echo   [4] Unblock PowerShell script
echo       Removes the Windows downloaded-file block from the PS1.
echo.
echo   [5] Exit
echo.
choice /C 12345 /N /M "Choose [1-5]: "

if errorlevel 5 goto :EOF
if errorlevel 4 goto UNBLOCK
if errorlevel 3 goto WINRERECOVERY
if errorlevel 2 goto EXECUTE
if errorlevel 1 goto DRYRUN

:DRYRUN
cls
echo ============================================================
echo DRY RUN
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RC=%errorlevel%"
echo.
echo ------------------------------------------------------------
echo PowerShell exit code: %RC%
echo ------------------------------------------------------------
echo.
pause
goto MENU

:EXECUTE
cls
echo ============================================================
echo EXECUTE
echo ============================================================
echo.
echo The PowerShell script will perform its own safety checks.
echo It will require you to type RELAYOUT before destructive work.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Execute
set "RC=%errorlevel%"
echo.
echo ------------------------------------------------------------
echo PowerShell exit code: %RC%
echo ------------------------------------------------------------
echo.
pause
goto MENU

:WINRERECOVERY
cls
echo ============================================================
echo WINRE CONFIRMATION / RECOVERY
echo ============================================================
echo.
echo This mode verifies the current WinRE configuration first.
echo If repair is required, PowerShell will ask you to type RECOVER.
echo.
echo It will NOT delete, create, shrink, or resize partitions.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -WinRERecovery
set "RC=%errorlevel%"
echo.
echo ------------------------------------------------------------
echo PowerShell exit code: %RC%
echo ------------------------------------------------------------
echo.
pause
goto MENU

:UNBLOCK
cls
echo ============================================================
echo UNBLOCK POWERSHELL SCRIPT
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "try { Unblock-File -LiteralPath '%SCRIPT%' -ErrorAction Stop; Write-Host 'Successfully unblocked:'; Write-Host '%SCRIPT%' -ForegroundColor Green; exit 0 } catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }"
set "RC=%errorlevel%"
echo.
if "%RC%"=="0" (
    echo The PowerShell script is unblocked.
) else (
    echo Unblock failed.
)
echo.
pause
goto MENU