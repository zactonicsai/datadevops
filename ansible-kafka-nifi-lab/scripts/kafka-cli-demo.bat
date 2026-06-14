@echo off
setlocal
set TOPIC=%~1
if "%TOPIC%"=="" set TOPIC=demo-events

call "%~dp0kafka-create-topic.bat" %TOPIC%
call "%~dp0kafka-send-message.bat" %TOPIC% "Hello Kafka from the Windows CLI demo"
call "%~dp0kafka-send-sample-messages.bat" %TOPIC%
call "%~dp0kafka-describe-topic.bat" %TOPIC%
call "%~dp0kafka-receive-messages.bat" %TOPIC%
endlocal
