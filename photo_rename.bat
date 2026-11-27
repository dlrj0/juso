@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0photo_rename.ps1" %*
pause
