@echo off
rem Teams-kuulokkeet - asennus (kayttajakohtainen, ei vaadi jarjestelmanvalvojan oikeuksia)
setlocal
if not exist "%~dp0TeamsKuulokkeet.ps1" (
  echo Tiedostoa TeamsKuulokkeet.ps1 ei loydy. Pura ZIP-paketti ensin kokonaan kansioon ja aja Asenna.cmd sielta.
  pause
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0TeamsKuulokkeet.ps1" -Install
endlocal
