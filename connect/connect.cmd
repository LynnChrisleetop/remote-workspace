@echo off
rem Windows wrapper for connect.ps1 — bypasses the default execution policy
rem (unsigned .ps1 files are blocked otherwise).
rem
rem   connect.cmd -RemoteHost my-devbox
rem   connect.cmd -RemoteHost 203.0.113.10 -SshPort 2222 -User root
setlocal
where pwsh >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0connect.ps1" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0connect.ps1" %*
)
endlocal
