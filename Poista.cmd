@echo off
rem Teams-kuulokkeet - poisto
setlocal
set "INSTALLED=%LOCALAPPDATA%\TeamsKuulokkeet\TeamsKuulokkeet.ps1"
set "SCRIPT=%~dp0TeamsKuulokkeet.ps1"
if exist "%INSTALLED%" set "SCRIPT=%INSTALLED%"
if not exist "%SCRIPT%" (
  echo Teams-kuulokkeet ei nayta olevan asennettuna.
  pause
  exit /b 0
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%" -Uninstall
endlocal
