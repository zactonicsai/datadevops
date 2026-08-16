"""Tiny web page: type a message, it goes onto the Kafka topic."""
import json, os, datetime
from flask import Flask, request, render_template_string
from kafka import KafkaProducer

BOOTSTRAP = os.environ["KAFKA_BOOTSTRAP"]
TOPIC     = os.environ.get("KAFKA_TOPIC", "messages")

app = Flask(__name__)
producer = None


def get_producer():
    """Connect lazily so the pod starts even if Kafka is briefly unavailable."""
    global producer
    if producer is None:
        producer = KafkaProducer(
            bootstrap_servers=BOOTSTRAP,
            value_serializer=lambda v: json.dumps(v).encode("utf-8"),
            retries=5,
        )
    return producer


PAGE = """
<!doctype html><title>Message Sender</title>
<style>
 body{font-family:system-ui,sans-serif;max-width:640px;margin:60px auto;padding:0 20px}
 input,button{font-size:16px;padding:10px}
 input{width:70%} .ok{color:#0a7a34} .err{color:#b00}
 code{background:#f2f2f2;padding:2px 6px;border-radius:3px}
</style>
<h1>Send a message</h1>
<p>Goes to Kafka topic <code>{{topic}}</code>, then NiFi copies it to S3.</p>
<form method="post">
  <input name="message" placeholder="Type anything..." autofocus required>
  <button type="submit">Send</button>
</form>
{% if status %}<p class="{{cls}}">{{status}}</p>{% endif %}
"""


@app.route("/", methods=["GET", "POST"])
def index():
    status, cls = None, "ok"
    if request.method == "POST":
        text = request.form.get("message", "")
        payload = {
            "message": text,
            "sent_at": datetime.datetime.now(datetime.UTC).isoformat(),
            "source": "webapp",
        }
        try:
            get_producer().send(TOPIC, payload).get(timeout=10)
            status = "Sent to Kafka: " + text
        except Exception as e:  # noqa: BLE001
            status, cls = "Failed: " + str(e), "err"
    return render_template_string(PAGE, status=status, cls=cls, topic=TOPIC)


@app.route("/healthz")
def healthz():
    return "ok", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
