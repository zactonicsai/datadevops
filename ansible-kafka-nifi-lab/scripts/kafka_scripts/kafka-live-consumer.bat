@echo off
setlocal
set TOPIC=%~1
if "%TOPIC%"=="" set TOPIC=demo-events
set KAFKA_CONTAINER=%KAFKA_CONTAINER%
if "%KAFKA_CONTAINER%"=="" set KAFKA_CONTAINER=kafka-server1
set BOOTSTRAP_SERVER=%BOOTSTRAP_SERVER%
if "%BOOTSTRAP_SERVER%"=="" set BOOTSTRAP_SERVER=kafka-server1:9092

echo Opening live consumer for topic: %TOPIC%
echo Press Ctrl+C to stop.
echo.
docker exec -it %KAFKA_CONTAINER% /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server %BOOTSTRAP_SERVER% --topic %TOPIC%
endlocal
