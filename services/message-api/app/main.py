"""
Message API
-----------
Single ingress for all grocery messages. Supports three payload types:
  * text   -> POST /api/messages   {dataset, type:"text", text:"..."}
  * json   -> POST /api/messages   {dataset, type:"json", data:{...}}
  * binary -> POST /api/upload      (multipart file + dataset form field)

Every message is routed to a per-dataset Kafka topic. Binary files are stored
in MinIO and only their metadata flows through Kafka.
"""
import json
import os
import socket
import uuid
from datetime import datetime, timezone

from fastapi import FastAPI, File, Form, UploadFile, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from typing import Any, Optional
from kafka import KafkaProducer
from minio import Minio

KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP", "kafka1:29092")
MINIO_ENDPOINT = os.getenv("MINIO_ENDPOINT", "minio:9000")
MINIO_ACCESS_KEY = os.getenv("MINIO_ACCESS_KEY", "minioadmin")
MINIO_SECRET_KEY = os.getenv("MINIO_SECRET_KEY", "minioadmin")
MINIO_BUCKET = os.getenv("MINIO_BUCKET", "grocery-uploads")

HOSTNAME = socket.gethostname()

VALID_DATASETS = {
    "sales", "inventory", "vendor_delivery", "customer_feedback",
    "shelf_space", "ad_program", "marketing", "discount_program",
    "expiry", "text", "json",
}

app = FastAPI(title="Grocery Message API", version="1.0.0")

# Expose Prometheus metrics at /metrics (scraped by Prometheus). Real status
# codes (not grouped) so dashboards can match e.g. status=~"5..".
from prometheus_fastapi_instrumentator import Instrumentator
Instrumentator(should_group_status_codes=False).instrument(app).expose(app)

_producer: Optional[KafkaProducer] = None
_minio: Optional[Minio] = None


def get_producer() -> KafkaProducer:
    global _producer
    if _producer is None:
        _producer = KafkaProducer(
            bootstrap_servers=KAFKA_BOOTSTRAP.split(","),
            value_serializer=lambda v: json.dumps(v).encode("utf-8"),
            acks="all",
            retries=5,
        )
    return _producer


def get_minio() -> Minio:
    global _minio
    if _minio is None:
        _minio = Minio(
            MINIO_ENDPOINT,
            access_key=MINIO_ACCESS_KEY,
            secret_key=MINIO_SECRET_KEY,
            secure=False,
        )
        if not _minio.bucket_exists(MINIO_BUCKET):
            _minio.make_bucket(MINIO_BUCKET)
    return _minio


def topic_for(dataset: str) -> str:
    return f"grocery.{dataset}"


class Message(BaseModel):
    dataset: str
    type: str                       # "text" | "json"
    text: Optional[str] = None
    data: Optional[Any] = None


@app.get("/api/health")
def health():
    return {"status": "ok", "served_by": HOSTNAME, "kafka": KAFKA_BOOTSTRAP}


@app.get("/api/datasets")
def datasets():
    return {"datasets": sorted(VALID_DATASETS)}


@app.post("/api/messages")
def send_message(msg: Message):
    if msg.dataset not in VALID_DATASETS:
        raise HTTPException(400, f"unknown dataset '{msg.dataset}'")
    if msg.type not in ("text", "json"):
        raise HTTPException(400, "type must be 'text' or 'json'")

    payload = {
        "id": str(uuid.uuid4()),
        "dataset": msg.dataset,
        "type": msg.type,
        "received_at": datetime.now(timezone.utc).isoformat(),
        "served_by": HOSTNAME,
    }
    if msg.type == "text":
        if msg.text is None:
            raise HTTPException(400, "text payload requires 'text'")
        payload["text"] = msg.text
    else:
        if msg.data is None:
            raise HTTPException(400, "json payload requires 'data'")
        payload["data"] = msg.data

    topic = topic_for(msg.dataset)
    try:
        fut = get_producer().send(topic, payload)
        meta = fut.get(timeout=10)
    except Exception as e:
        raise HTTPException(503, f"kafka produce failed: {e}")

    return JSONResponse({
        "accepted": True,
        "topic": topic,
        "partition": meta.partition,
        "offset": meta.offset,
        "served_by": HOSTNAME,
        "id": payload["id"],
    })


@app.post("/api/upload")
async def upload_binary(
    file: UploadFile = File(...),
    dataset: str = Form("binary"),
    description: str = Form(""),
):
    content = await file.read()
    object_key = f"{dataset}/{uuid.uuid4()}_{file.filename}"

    try:
        import io
        get_minio().put_object(
            MINIO_BUCKET, object_key, io.BytesIO(content), length=len(content),
            content_type=file.content_type or "application/octet-stream",
        )
    except Exception as e:
        raise HTTPException(503, f"object store failed: {e}")

    payload = {
        "id": str(uuid.uuid4()),
        "dataset": dataset,
        "type": "binary",
        "received_at": datetime.now(timezone.utc).isoformat(),
        "served_by": HOSTNAME,
        "object_key": object_key,
        "bucket": MINIO_BUCKET,
        "filename": file.filename,
        "content_type": file.content_type,
        "size_bytes": len(content),
        "description": description,
    }
    try:
        fut = get_producer().send("grocery.binary", payload)
        meta = fut.get(timeout=10)
    except Exception as e:
        raise HTTPException(503, f"kafka produce failed: {e}")

    return JSONResponse({
        "accepted": True,
        "topic": "grocery.binary",
        "object_key": object_key,
        "size_bytes": len(content),
        "partition": meta.partition,
        "offset": meta.offset,
        "served_by": HOSTNAME,
    })
