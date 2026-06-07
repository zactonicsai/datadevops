"""
Ingest worker
-------------
Consumes every grocery.* topic and persists messages to Postgres. Structured
datasets (sales/inventory/etc.) are upserted into their typed tables when the
payload matches; everything is also written to `message_log` for auditing and
for the binary-file metadata stream.
"""
import json
import os
import time

import psycopg2
import psycopg2.extras
from kafka import KafkaConsumer

KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP", "kafka1:29092")
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://grocery:grocery_pw@postgres:5432/grocery")

TOPICS = [
    "grocery.sales", "grocery.inventory", "grocery.vendor_delivery",
    "grocery.customer_feedback", "grocery.shelf_space", "grocery.ad_program",
    "grocery.marketing", "grocery.discount_program", "grocery.expiry",
    "grocery.binary", "grocery.text", "grocery.json",
]


def connect_db():
    for attempt in range(30):
        try:
            conn = psycopg2.connect(DATABASE_URL)
            conn.autocommit = True
            return conn
        except Exception as e:
            print(f"[worker] db not ready ({e}); retry {attempt}", flush=True)
            time.sleep(3)
    raise RuntimeError("could not connect to database")


def connect_consumer():
    for attempt in range(30):
        try:
            return KafkaConsumer(
                *TOPICS,
                bootstrap_servers=KAFKA_BOOTSTRAP.split(","),
                value_deserializer=lambda v: json.loads(v.decode("utf-8")),
                auto_offset_reset="earliest",
                enable_auto_commit=True,
                group_id="grocery-ingest",
            )
        except Exception as e:
            print(f"[worker] kafka not ready ({e}); retry {attempt}", flush=True)
            time.sleep(3)
    raise RuntimeError("could not connect to kafka")


def insert_typed(cur, dataset, data):
    """Best-effort insert into a typed table. Silently skips on mismatch."""
    try:
        if dataset == "sales":
            cur.execute(
                """INSERT INTO sales(product_id, sale_date, units, unit_price,
                       discount_pct, revenue, cogs, discount_program_id)
                   VALUES (%(product_id)s,%(sale_date)s,%(units)s,%(unit_price)s,
                       %(discount_pct)s,%(revenue)s,%(cogs)s,%(discount_program_id)s)""",
                {**{"discount_pct": 0, "discount_program_id": None}, **data},
            )
        elif dataset == "customer_feedback":
            cur.execute(
                """INSERT INTO customer_feedback(feedback_date, category, rating,
                       sentiment, theme, comment)
                   VALUES (%(feedback_date)s,%(category)s,%(rating)s,
                       %(sentiment)s,%(theme)s,%(comment)s)""",
                {**{"category": None, "theme": None, "comment": None}, **data},
            )
        # other datasets are mostly seeded directly; extend here as needed
    except Exception as e:
        print(f"[worker] typed insert skipped for {dataset}: {e}", flush=True)


def main():
    db = connect_db()
    consumer = connect_consumer()
    print(f"[worker] consuming {len(TOPICS)} topics", flush=True)

    for msg in consumer:
        rec = msg.value
        dataset = rec.get("dataset", "unknown")
        mtype = rec.get("type", "json")
        with db.cursor() as cur:
            cur.execute(
                """INSERT INTO message_log(dataset, msg_type, topic, payload, object_key)
                   VALUES (%s,%s,%s,%s,%s)""",
                (dataset, mtype, msg.topic,
                 psycopg2.extras.Json(rec),
                 rec.get("object_key")),
            )
            if mtype == "json" and isinstance(rec.get("data"), dict):
                insert_typed(cur, dataset, rec["data"])
        print(f"[worker] stored {dataset}/{mtype} from {msg.topic}", flush=True)


if __name__ == "__main__":
    main()
