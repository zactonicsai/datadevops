@echo off
setlocal
set TOPIC=%~1
if "%TOPIC%"=="" set TOPIC=demo-events
set KAFKA_CONTAINER=%KAFKA_CONTAINER%
if "%KAFKA_CONTAINER%"=="" set KAFKA_CONTAINER=kafka-server1
set BOOTSTRAP_SERVER=%BOOTSTRAP_SERVER%
if "%BOOTSTRAP_SERVER%"=="" set BOOTSTRAP_SERVER=kafka-server1:9092

docker exec %KAFKA_CONTAINER% /opt/kafka/bin/kafka-topics.sh --bootstrap-server %BOOTSTRAP_SERVER% --describe --topic %TOPIC%
endlocal
