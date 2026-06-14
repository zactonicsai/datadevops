@echo off
setlocal
set TOPIC=%~1
if "%TOPIC%"=="" set TOPIC=demo-events
set KAFKA_CONTAINER=%KAFKA_CONTAINER%
if "%KAFKA_CONTAINER%"=="" set KAFKA_CONTAINER=kafka-server1
set BOOTSTRAP_SERVER=%BOOTSTRAP_SERVER%
if "%BOOTSTRAP_SERVER%"=="" set BOOTSTRAP_SERVER=kafka-server1:9092
set TIMEOUT_MS=%TIMEOUT_MS%
if "%TIMEOUT_MS%"=="" set TIMEOUT_MS=10000

echo Reading messages from topic: %TOPIC%
echo This will stop after %TIMEOUT_MS% ms if no more messages arrive.
echo.
docker exec -it %KAFKA_CONTAINER% /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server %BOOTSTRAP_SERVER% --topic %TOPIC% --from-beginning --timeout-ms %TIMEOUT_MS%
endlocal
