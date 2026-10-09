@echo off
setlocal
if "%UPSTREAM_BASE_URL%"=="" (
  echo Set UPSTREAM_BASE_URL first, for example:
  echo   set UPSTREAM_BASE_URL=https://api.example.com/v1
  exit /b 2
)
steady-relay.exe --upstream "%UPSTREAM_BASE_URL%" --listen "127.0.0.1:8080" --max-retries 10
