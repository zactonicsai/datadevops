# Kafka CLI: Send and Receive Messages

This guide shows how to test Kafka from the command line.

Think of Kafka like a mailbox system:

- A **topic** is a mailbox.
- A **producer** puts messages into the mailbox.
- A **consumer** reads messages from the mailbox.
- A **broker** is a Kafka server that stores and shares the messages.

In this lab, Ansible creates three Kafka containers:

```text
kafka-server1
kafka-server2
kafka-server3
```

The examples below use `kafka-server1` as the place where we run Kafka commands.

---

## 1. Start the lab

From the project folder:

```bash
docker compose up -d --build
```

Then run the Ansible playbook:

```bash
docker exec -it ansible-controller bash
/work/scripts/run-playbook.sh
```

Exit the controller when done:

```bash
exit
```

---

## 2. Check that Kafka is running

Run this from your normal terminal:

```bash
docker ps --filter "name=kafka-server"
```

You should see containers like this:

```text
kafka-server1
kafka-server2
kafka-server3
```

---

## 3. Create a topic

This creates a topic named `demo-events`.

```bash
docker exec kafka-server1 /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka-server1:9092 \
  --create \
  --if-not-exists \
  --topic demo-events \
  --partitions 3 \
  --replication-factor 3
```

What this means:

- `--bootstrap-server kafka-server1:9092` means "connect to Kafka server 1."
- `--topic demo-events` is the topic name.
- `--partitions 3` splits the topic into 3 lanes.
- `--replication-factor 3` copies the data to all 3 Kafka servers.

---

## 4. List topics

```bash
docker exec kafka-server1 /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka-server1:9092 \
  --list
```

You should see:

```text
demo-events
```

---

## 5. Send one message

This sends one message into Kafka.

```bash
echo "Hello Kafka from the CLI" | docker exec -i kafka-server1 /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server kafka-server1:9092 \
  --topic demo-events
```

The `echo` command writes the message.

The producer sends the message to Kafka.

---

## 6. Send more than one message

```bash
printf "order-1001 created\norder-1002 paid\norder-1003 shipped\n" | docker exec -i kafka-server1 /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server kafka-server1:9092 \
  --topic demo-events
```

Each line becomes one Kafka message.

---

## 7. Read messages from the beginning

```bash
docker exec -it kafka-server1 /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka-server1:9092 \
  --topic demo-events \
  --from-beginning \
  --timeout-ms 10000
```

What this means:

- `--from-beginning` means "show old messages too."
- `--timeout-ms 10000` stops after 10 seconds if no new messages arrive.

---

## 8. Open a live consumer

Open Terminal 1 and run:

```bash
docker exec -it kafka-server1 /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka-server1:9092 \
  --topic demo-events
```

Leave it open.

Open Terminal 2 and send a message:

```bash
echo "A live message from Terminal 2" | docker exec -i kafka-server1 /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server kafka-server1:9092 \
  --topic demo-events
```

You should see the message appear in Terminal 1.

Press `Ctrl+C` to stop the consumer.

---

## 9. Send messages by typing

This opens an interactive producer.

```bash
docker exec -it kafka-server1 /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server kafka-server1:9092 \
  --topic demo-events
```

Type a message and press Enter:

```text
hello one
hello two
hello three
```

Press `Ctrl+C` when done.

---

## 10. Describe the topic

This shows how the topic is spread across the three Kafka servers.

```bash
docker exec kafka-server1 /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka-server1:9092 \
  --describe \
  --topic demo-events
```

Look for:

- `Partition`
- `Leader`
- `Replicas`
- `Isr`

Simple meaning:

- **Partition**: one lane of the topic.
- **Leader**: the Kafka server in charge of that partition.
- **Replicas**: the Kafka servers that have copies.
- **Isr**: replicas that are caught up and healthy.

---

## 11. Helpful scripts

This project also includes helper scripts.

Linux or macOS:

```bash
./scripts/kafka-create-topic.sh demo-events
./scripts/kafka-send-message.sh demo-events "Hello from helper script"
./scripts/kafka-receive-messages.sh demo-events
./scripts/kafka-cli-demo.sh
```

Windows Command Prompt:

```bat
scripts\kafka-create-topic.bat demo-events
scripts\kafka-send-message.bat demo-events "Hello from helper script"
scripts\kafka-receive-messages.bat demo-events
scripts\kafka-cli-demo.bat
```

---

## 12. Common problems

### Problem: `No such container: kafka-server1`

Kafka has not been deployed yet.

Run:

```bash
docker exec -it ansible-controller bash
/work/scripts/run-playbook.sh
```

### Problem: Consumer shows no messages

You may be reading only new messages.

Try:

```bash
docker exec -it kafka-server1 /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka-server1:9092 \
  --topic demo-events \
  --from-beginning \
  --timeout-ms 10000
```

### Problem: Topic does not exist

Create it again:

```bash
./scripts/kafka-create-topic.sh demo-events
```

### Problem: Command hangs

That is normal for a live consumer or interactive producer.

- Producer waits for you to type messages.
- Consumer waits for new messages.

Press `Ctrl+C` to stop.
