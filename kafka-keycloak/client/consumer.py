#!/usr/bin/env python3
"""Read messages from a topic and print them (Ctrl+C to stop).

Usage:
    python consumer.py -t orders
    python consumer.py -t orders -g my-group -b localhost:29092
"""
import argparse
import json

from confluent_kafka import Consumer, KafkaError


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-b", "--bootstrap", default="localhost:29092")
    ap.add_argument("-t", "--topic", default="orders")
    ap.add_argument("-g", "--group", default="demo-consumer")
    args = ap.parse_args()

    consumer = Consumer({
        "bootstrap.servers": args.bootstrap,
        "group.id": args.group,
        "auto.offset.reset": "earliest",
    })
    consumer.subscribe([args.topic])
    print(f"Consuming '{args.topic}' as group '{args.group}' (Ctrl+C to stop)")
    try:
        while True:
            msg = consumer.poll(1.0)
            if msg is None:
                continue
            if msg.error():
                if msg.error().code() != KafkaError._PARTITION_EOF:
                    print("Error:", msg.error())
                continue
            try:
                value = json.loads(msg.value())
            except (ValueError, TypeError):
                value = msg.value()
            key = msg.key().decode() if msg.key() else None
            print(f"[p{msg.partition()} o{msg.offset()}] key={key} value={value}")
    except KeyboardInterrupt:
        pass
    finally:
        consumer.close()


if __name__ == "__main__":
    main()
