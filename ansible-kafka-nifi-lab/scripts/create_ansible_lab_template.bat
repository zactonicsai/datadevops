@echo off
setlocal EnableExtensions

REM Windows wrapper for the PowerShell template generator.
REM Usage:
REM   create_ansible_lab_template.bat
REM   create_ansible_lab_template.bat my-folder-name

set "PROJECT_NAME=%~1"
if "%PROJECT_NAME%"=="" set "PROJECT_NAME=ansible-kafka-nifi-starter"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0create_ansible_lab_template.ps1" -ProjectName "%PROJECT_NAME%"

endlocal
