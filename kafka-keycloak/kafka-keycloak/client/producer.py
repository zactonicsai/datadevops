#!/usr/bin/env python3
"""Send a few test messages to the demo topics.

Usage:
    python producer.py                      # 5 messages to every demo topic
    python producer.py -t orders -n 20      # 20 messages to one topic
    python producer.py -b localhost:29092   # custom bootstrap server
"""
import argparse
import json
import random
import time
import uuid

from confluent_kafka import Producer

DEMO_TOPICS = ["orders", "payments", "user-events", "audit-log"]


def make_message(topic: str, i: int) -> tuple[str, dict]:
    """Return (key, value) shaped like something the topic might really carry."""
    now = int(time.time() * 1000)
    if topic == "orders":
        key = f"order-{uuid.uuid4().hex[:8]}"
        value = {"order_id": key, "customer": random.choice(["alice", "bob", "carol"]),
                 "amount": round(random.uniform(5, 500), 2), "currency": "USD", "ts": now}
    elif topic == "payments":
        key = f"pay-{uuid.uuid4().hex[:8]}"
        value = {"payment_id": key, "status": random.choice(["AUTHORIZED", "CAPTURED", "FAILED"]),
                 "amount": round(random.uniform(5, 500), 2), "ts": now}
    elif topic == "user-events":
        key = random.choice(["alice", "bob", "carol"])
        value = {"user": key, "event": random.choice(["login", "logout", "view", "click"]),
                 "seq": i, "ts": now}
    else:  # audit-log
        key = "system"
        value = {"actor": "producer.py", "action": f"test-message-{i}", "ts": now}
    return key, value


def delivery_report(err, msg):
    if err is not None:
        print(f"  x delivery failed for key={msg.key()}: {err}")
    else:
        print(f"  ok {msg.topic()} [partition {msg.partition()}] offset {msg.offset()} key={msg.key().decode()}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-b", "--bootstrap", default="localhost:29092")
    ap.add_argument("-t", "--topic", help="single topic (default: all demo topics)")
    ap.add_argument("-n", "--count", type=int, default=5, help="messages per topic")
    args = ap.parse_args()

    producer = Producer({"bootstrap.servers": args.bootstrap, "client.id": "demo-producer"})
    topics = [args.topic] if args.topic else DEMO_TOPICS

    for topic in topics:
        print(f"Producing {args.count} messages to '{topic}'")
        for i in range(args.count):
            key, value = make_message(topic, i)
            producer.produce(topic, key=key, value=json.dumps(value).encode(), callback=delivery_report)
            producer.poll(0)  # serve delivery callbacks
    producer.flush(10)
    print("Done.")


if __name__ == "__main__":
    main()
