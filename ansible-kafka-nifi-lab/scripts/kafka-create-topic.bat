@echo off
setlocal
set TOPIC=%~1
if "%TOPIC%"=="" set TOPIC=demo-events
set PARTITIONS=%PARTITIONS%
if "%PARTITIONS%"=="" set PARTITIONS=3
set REPLICATION_FACTOR=%REPLICATION_FACTOR%
if "%REPLICATION_FACTOR%"=="" set REPLICATION_FACTOR=3
set KAFKA_CONTAINER=%KAFKA_CONTAINER%
if "%KAFKA_CONTAINER%"=="" set KAFKA_CONTAINER=kafka-server1
set BOOTSTRAP_SERVER=%BOOTSTRAP_SERVER%
if "%BOOTSTRAP_SERVER%"=="" set BOOTSTRAP_SERVER=kafka-server1:9092

echo Creating or checking topic: %TOPIC%
docker exec %KAFKA_CONTAINER% /opt/kafka/bin/kafka-topics.sh --bootstrap-server %BOOTSTRAP_SERVER% --create --if-not-exists --topic %TOPIC% --partitions %PARTITIONS% --replication-factor %REPLICATION_FACTOR%

echo.
echo Current topics:
docker exec %KAFKA_CONTAINER% /opt/kafka/bin/kafka-topics.sh --bootstrap-server %BOOTSTRAP_SERVER% --list
endlocal
