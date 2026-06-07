"""
What-if scenario assistant (RAG)
--------------------------------
Builds a small knowledge base of the store's current metrics in ChromaDB, then
answers free-text "what-if" questions by retrieving the most relevant facts and
asking the local Ollama model to reason over them. Fully local; no external API.

Resilience: ChromaDB and Ollama are both treated as best-effort. If ChromaDB is
unreachable we fall back to using all metric facts directly (no vector search);
if Ollama is unreachable we return the retrieved facts so the user still gets a
useful, grounded response. The endpoint never raises on a downstream outage.
"""
import os

import requests

from . import data, forecast

CHROMA_HOST = os.getenv("CHROMA_HOST", "chromadb")
CHROMA_PORT = int(os.getenv("CHROMA_PORT", "8000"))
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://ollama:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "llama3.2")
COLLECTION = "grocery_facts"

_client = None
_collection = None


def _chroma():
    """Return the Chroma collection, or None if Chroma can't be reached.

    Never raises: callers treat a None result as 'vector store unavailable'
    and fall back to using metric facts directly.
    """
    global _client, _collection
    if _collection is not None:
        return _collection
    try:
        import chromadb
        _client = chromadb.HttpClient(host=CHROMA_HOST, port=CHROMA_PORT)
        _collection = _client.get_or_create_collection(COLLECTION)
        return _collection
    except Exception as e:
        print(f"[whatif] ChromaDB unavailable ({e}); using direct-facts fallback", flush=True)
        return None


def _build_facts():
    """Build the list of (id, document, metadata) fact tuples from current
    metrics. Used both to populate ChromaDB and as the no-vector fallback."""
    docs, ids, metas = [], [], []

    kpi = data.kpi_summary()
    docs.append(
        f"Store KPIs: revenue ${kpi['revenue']:,}, gross profit ${kpi['gross_profit']:,}, "
        f"net profit ${kpi['net_profit']:,}, margin {kpi['margin_pct']}%, "
        f"shrink {kpi['shrink_pct']}% (loss ${kpi['loss_value']:,}), "
        f"revenue growth {kpi['revenue_growth_pct']}% over last 30 days."
    )
    ids.append("kpi"); metas.append({"kind": "kpi"})

    for c in data.profit_by_category():
        docs.append(
            f"Category {c['category']}: revenue ${c['revenue']:,}, gross profit "
            f"${c['gross_profit']:,}, net profit ${c['net_profit']:,}, margin {c['margin_pct']}%, "
            f"loss ${c['loss_value']:,}."
        )
        ids.append(f"cat-{c['category']}"); metas.append({"kind": "category"})

    for s in data.profit_by_shelf()[:12]:
        docs.append(
            f"Shelf {s['shelf']} (aisle {s['aisle']}, {s['category']}): "
            f"{s['linear_feet']} linear feet, gross profit ${s['gross_profit']:,}, "
            f"profit per foot ${s['profit_per_foot']}."
        )
        ids.append(f"shelf-{s['shelf_id']}"); metas.append({"kind": "shelf"})

    lb = data.loss_breakdown()
    for c in lb["by_cause"]:
        docs.append(f"Loss cause {c['cause']}: ${c['loss_value']:,} across {c['units']} units.")
        ids.append(f"loss-{c['cause']}"); metas.append({"kind": "loss"})

    for p in data.promotion_roi():
        docs.append(
            f"Promotion {p['program']} ({p['category']}, {p['discount_pct']}% off): "
            f"incremental margin ${p['incremental_margin']:,} ({p['roi_label']})."
        )
        ids.append(f"promo-{p['program']}"); metas.append({"kind": "promo"})

    fb = data.feedback_signal()
    for t in fb["themes"]:
        docs.append(f"Feedback theme '{t['theme']}': {t['n']} mentions, avg sentiment {t['sentiment']}.")
        ids.append(f"fb-{t['theme']}"); metas.append({"kind": "feedback"})

    return ids, docs, metas


def build_context_index():
    """(Re)build the fact index from current metrics. Stable ids mean re-runs
    overwrite. If ChromaDB is unavailable, report that gracefully instead of
    raising."""
    ids, docs, metas = _build_facts()
    col = _chroma()
    if col is None:
        return {"indexed": 0, "vector_store": "unavailable",
                "note": "ChromaDB not reachable; what-if will use facts directly."}
    if docs:
        col.upsert(documents=docs, ids=ids, metadatas=metas)
    return {"indexed": len(docs), "vector_store": "ok"}


def _retrieve(query: str, k: int = 6):
    """Return up to k relevant fact strings. Uses ChromaDB vector search when
    available; otherwise returns all metric facts (the model can still reason
    over the full, modest-sized set)."""
    col = _chroma()
    if col is not None:
        try:
            if col.count() == 0:
                build_context_index()
            res = col.query(query_texts=[query], n_results=k)
            docs = res.get("documents", [[]])[0]
            if docs:
                return docs
        except Exception as e:
            print(f"[whatif] retrieval failed ({e}); using direct facts", flush=True)
    # Fallback: build facts directly, no vector store needed.
    _, docs, _ = _build_facts()
    return docs


def ask_whatif(question: str):
    facts = _retrieve(question)

    # Attach a baseline projection so the model can reason about the future.
    try:
        proj = forecast.project_profit(horizon_days=30)
        baseline = proj["summary"].get("projected_total_gross_profit", 0)
    except Exception:
        baseline = 0

    context = "\n".join(f"- {f}" for f in facts) or "- (no specific facts retrieved)"
    prompt = f"""You are a grocery store operations and finance analyst.
Use ONLY the store facts below to reason about the user's what-if question.
Be concrete, quantify impact when possible, and state assumptions plainly.
Keep the answer under 220 words.

STORE FACTS:
{context}

30-DAY BASELINE PROJECTED GROSS PROFIT: ${baseline:,}

WHAT-IF QUESTION: {question}

ANSWER:"""

    try:
        r = requests.post(
            f"{OLLAMA_URL}/api/generate",
            json={"model": OLLAMA_MODEL, "prompt": prompt, "stream": False,
                  "keep_alive": "30m"},
            timeout=90,
        )
        r.raise_for_status()
        answer = r.json().get("response", "").strip()
        if not answer:
            raise ValueError("empty response from model")
    except Exception as e:
        answer = (
            "The local model is still warming up or unavailable "
            f"({e}). Based on the retrieved store facts:\n\n" + context
        )

    return {
        "question": question,
        "answer": answer,
        "facts_used": facts,
        "baseline_30d_gross_profit": baseline,
        "model": OLLAMA_MODEL,
    }
