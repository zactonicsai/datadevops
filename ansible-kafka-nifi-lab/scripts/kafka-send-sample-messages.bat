@echo off
setlocal
set TOPIC=%~1
if "%TOPIC%"=="" set TOPIC=demo-events
set KAFKA_CONTAINER=%KAFKA_CONTAINER%
if "%KAFKA_CONTAINER%"=="" set KAFKA_CONTAINER=kafka-server1
set BOOTSTRAP_SERVER=%BOOTSTRAP_SERVER%
if "%BOOTSTRAP_SERVER%"=="" set BOOTSTRAP_SERVER=kafka-server1:9092

echo Sending sample messages to topic: %TOPIC%
(
  echo order-1001 created
  echo order-1002 paid
  echo order-1003 shipped
  echo inventory SKU-55 updated
) | docker exec -i %KAFKA_CONTAINER% /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server %BOOTSTRAP_SERVER% --topic %TOPIC%
echo Sample messages sent.
endlocal
