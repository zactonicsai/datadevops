#!/usr/bin/env bash
# =============================================================================
# 15-create-nifi-flow.sh  —  ONE JOB: help you build the Kafka -> S3 flow.
#
# HONEST NOTE: building a NiFi flow through its REST API takes a lot of very
# fiddly JSON, and NiFi 2.x needs a "controller service" for the Kafka
# connection before the ConsumeKafka processor will even validate.
#
# For LEARNING, doing it in the UI once is genuinely better — you see the
# boxes and arrows and understand what the flow is. So this script:
#   1. prints exact click-by-click instructions, and
#   2. gives you the values to paste, pre-filled from your lab.
#
# It also starts the port-forward for you.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-config.sh"
need_tool kubectl
require NS_APPS S3_BUCKET KAFKA_BOOTSTRAP AWS_REGION

banner "Build the NiFi flow:  Kafka  ->  S3"

USER=$(kubectl -n "$NS_APPS" get secret nifi-single-user -o jsonpath='{.data.username}' | base64 -d)
PASS=$(kubectl -n "$NS_APPS" get secret nifi-single-user -o jsonpath='{.data.password}' | base64 -d)

cat <<TXT

  Step 1. Open NiFi
  ------------------------------------------------------------------
  Run this in a SECOND terminal and leave it running:

      kubectl -n ${NS_APPS} port-forward svc/nifi 8443:8443

  Then open:  https://localhost:8443/nifi
  Accept the browser certificate warning (self-signed cert — expected).

      username: ${USER}
      password: ${PASS}


  Step 2. Add the Kafka connection service
  ------------------------------------------------------------------
  NiFi 2.x keeps connection settings in a shared "controller service"
  so several processors can reuse one connection.

    a) Click the hamburger menu (top right) -> Controller Settings
    b) Go to the "Controller Services" tab -> "+"
    c) Add:  Kafka3ConnectionService
    d) Click its pencil/edit icon and set:

         Bootstrap Servers = ${KAFKA_BOOTSTRAP}
         Security Protocol = PLAINTEXT

    e) Save, then click the lightning bolt to ENABLE it.
       (A service that is not enabled makes processors show a yellow
        warning triangle and refuse to start.)


  Step 3. Add the ConsumeKafka processor  (the "read" end)
  ------------------------------------------------------------------
    a) Drag the processor icon onto the canvas
    b) Search for and add:  ConsumeKafka
    c) Double-click it -> Properties tab -> set:

         Kafka Connection Service = Kafka3ConnectionService
         Group ID                 = nifi-lab
         Topics                   = ${KAFKA_TOPIC}
         Processing Strategy      = FLOW_FILE

    d) Settings tab: nothing to change yet.


  Step 4. Add the PutS3Object processor  (the "write" end)
  ------------------------------------------------------------------
    a) Drag another processor on -> search:  PutS3Object
    b) Double-click -> Properties tab -> set:

         Bucket        = ${S3_BUCKET}
         Region        = ${AWS_REGION}
         Object Key    = \${filename}.json
         Credentials   = leave EMPTY  <-- important, see note below

    c) Settings tab -> "Automatically Terminate Relationships":
       tick BOTH  success  and  failure.
       (Nothing comes after this processor, so its outputs need somewhere
        to go. Untermined relationships stop a processor from starting.)

  >>> WHY LEAVE CREDENTIALS EMPTY <<<
  Because of IRSA. The pod already has temporary AWS credentials injected
  by Kubernetes. NiFi's AWS library finds them automatically. If you paste
  an access key here instead, you have created exactly the long-lived
  secret that IRSA exists to eliminate.


  Step 5. Connect them
  ------------------------------------------------------------------
    a) Hover over ConsumeKafka -> an arrow icon appears in the middle
    b) Drag the arrow onto PutS3Object
    c) In the dialog, tick the "success" relationship -> Add


  Step 6. Start the flow
  ------------------------------------------------------------------
    a) Click an empty part of the canvas (deselects everything)
    b) Press the "Start" (play) button in the Operate palette
    c) Both boxes should turn green with a play symbol.

    If a box has a red or yellow icon, hover over it — NiFi tells you
    exactly what is wrong (usually an unset property or a disabled
    controller service).


  Step 7. TEST IT
  ------------------------------------------------------------------
  In a third terminal:

      kubectl -n ${NS_APPS} port-forward svc/webapp 8000:80

  Open http://localhost:8000 , type a message, press Send.

  Then watch it arrive:

      # 1. Confirm Kafka got it
      kubectl -n ${NS_APPS} exec -it kafka-0 -- \\
        /opt/kafka/bin/kafka-console-consumer.sh \\
        --bootstrap-server localhost:9092 --topic ${KAFKA_TOPIC} --from-beginning

      # 2. Confirm S3 got it  (allow ~10 seconds)
      aws s3 ls s3://${S3_BUCKET}/ --recursive

      # 3. Read one back
      aws s3 cp s3://${S3_BUCKET}/<the-file-name> - | cat

  That is the whole pipeline:
      browser -> webapp -> Kafka -> NiFi -> S3

TXT

log "Run ./16-verify.sh at any time to check the whole chain."
