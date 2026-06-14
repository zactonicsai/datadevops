@echo off
setlocal
set TOPIC=%~1
if "%TOPIC%"=="" set TOPIC=demo-events
set MESSAGE=%~2
if "%MESSAGE%"=="" set MESSAGE=Hello Kafka from the Windows CLI
set KAFKA_CONTAINER=%KAFKA_CONTAINER%
if "%KAFKA_CONTAINER%"=="" set KAFKA_CONTAINER=kafka-server1
set BOOTSTRAP_SERVER=%BOOTSTRAP_SERVER%
if "%BOOTSTRAP_SERVER%"=="" set BOOTSTRAP_SERVER=kafka-server1:9092

echo Sending message to topic: %TOPIC%
echo Message: %MESSAGE%
echo %MESSAGE% | docker exec -i %KAFKA_CONTAINER% /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server %BOOTSTRAP_SERVER% --topic %TOPIC%
echo Message sent.
endlocal
