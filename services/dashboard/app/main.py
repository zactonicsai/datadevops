"""Dashboard server: serves the static UI and proxies the analytics API so the
browser only ever talks to one origin (through the load balancer)."""
import os
import httpx
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, Response, JSONResponse
from fastapi.staticfiles import StaticFiles

ANALYTICS_URL = os.getenv("ANALYTICS_URL", "http://analytics:8002")
HERE = os.path.dirname(__file__)

app = FastAPI(title="Grocery Dashboard")

# Prometheus metrics at /metrics (scraped by Prometheus).
from prometheus_fastapi_instrumentator import Instrumentator
Instrumentator(should_group_status_codes=False).instrument(app).expose(app)
app.mount("/static", StaticFiles(directory=os.path.join(HERE, "static")), name="static")


@app.get("/", response_class=HTMLResponse)
def index():
    with open(os.path.join(HERE, "templates", "index.html"), encoding="utf-8") as f:
        return f.read()


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


# Proxy: /proxy/<path> -> analytics/<path>  (keeps single-origin for the browser)
@app.api_route("/proxy/{path:path}", methods=["GET", "POST"])
async def proxy(path: str, request: Request):
    url = f"{ANALYTICS_URL}/{path}"
    # Generous timeout: the what-if path can call a cold LLM. This sits above
    # the analytics->Ollama timeout (90s) and below nginx's (180s) so analytics
    # always returns its graceful fallback rather than the proxy emitting a 504.
    async with httpx.AsyncClient(timeout=150) as client:
        if request.method == "POST":
            body = await request.body()
            r = await client.post(url, content=body,
                                  headers={"content-type": "application/json"})
        else:
            r = await client.get(url, params=dict(request.query_params))
    media = r.headers.get("content-type", "application/json")
    return Response(content=r.content, status_code=r.status_code, media_type=media)
