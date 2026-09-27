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
echo       Post-reboot validation of disk, WinRE, and BitLocker state.
echo       Repairs WinRE registration if needed.
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
call :GETSIZE
if errorlevel 1 goto MENU
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -RecoverySizeMB %RECOVERY_SIZE%
set "RC=%errorlevel%"
echo.
echo ------------------------------------------------------------
echo PowerShell exit code: %RC%
echo ------------------------------------------------------------
echo.
if "%RC%"=="2" (
    echo WinRE needs confirmation/recovery before a new relayout.
    echo Follow the recovery guidance shown above. Execute has not been started.
    echo.
)
pause
goto MENU

:EXECUTE
cls
echo ============================================================
echo EXECUTE
echo ============================================================
echo.
call :GETSIZE
if errorlevel 1 goto MENU
echo.
echo Selected Recovery partition size: %RECOVERY_SIZE% MB
echo The PowerShell script will perform its own safety checks.
echo It will require you to type RELAYOUT before destructive work.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Execute -RecoverySizeMB %RECOVERY_SIZE%
set "RC=%errorlevel%"
echo.
echo ------------------------------------------------------------
echo PowerShell exit code: %RC%
echo ------------------------------------------------------------
echo.
if "%RC%"=="0" (
    echo IMPORTANT:
    echo   Restart Windows now.
    echo   After restart, run this BAT again and choose:
    echo   [3] WinRE confirmation / recovery
    echo.
    echo   The operation is complete only after option 3 reports:
    echo   FINAL DISK / WINRE STATE CONFIRMED
    echo.
)
if "%RC%"=="2" (
    echo Execute was blocked because WinRE needs confirmation/recovery first.
    echo Follow the recovery guidance shown above. No relayout was started.
    echo.
)
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

:GETSIZE
set "RECOVERY_SIZE="
set /p "RECOVERY_SIZE=Recovery partition size in MB [870-1100] (default 1024): "
if not defined RECOVERY_SIZE set "RECOVERY_SIZE=1024"

echo(%RECOVERY_SIZE%| findstr /R /X "[0-9][0-9]*" >nul
if errorlevel 1 (
    echo.
    echo ERROR: Enter a whole number between 870 and 1100.
    echo.
    pause
    exit /b 1
)

set /a RECOVERY_SIZE_NUM=%RECOVERY_SIZE% >nul 2>&1
if %RECOVERY_SIZE_NUM% LSS 870 (
    echo.
    echo ERROR: Minimum Recovery partition size is 870 MB.
    echo.
    pause
    exit /b 1
)
if %RECOVERY_SIZE_NUM% GTR 1100 (
    echo.
    echo ERROR: Maximum Recovery partition size is 1100 MB.
    echo.
    pause
    exit /b 1
)

set "RECOVERY_SIZE=%RECOVERY_SIZE_NUM%"
exit /b 0

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