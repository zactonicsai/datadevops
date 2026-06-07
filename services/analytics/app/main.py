"""Analytics service API."""
from fastapi import FastAPI, Query
from fastapi.responses import Response, JSONResponse
from pydantic import BaseModel

from . import data, forecast, reports, charts, whatif

app = FastAPI(title="Grocery Analytics", version="1.0.0")

# Prometheus metrics at /metrics (scraped by Prometheus).
from prometheus_fastapi_instrumentator import Instrumentator
Instrumentator(should_group_status_codes=False).instrument(app).expose(app)


@app.get("/health")
def health():
    return {"status": "ok"}


# ---- raw metrics ----
@app.get("/metrics/kpi")
def m_kpi(): return data.kpi_summary()

@app.get("/metrics/profit/category")
def m_pc(): return data.profit_by_category()

@app.get("/metrics/profit/shelf")
def m_ps(): return data.profit_by_shelf()

@app.get("/metrics/loss")
def m_loss(): return data.loss_breakdown()

@app.get("/metrics/expiring")
def m_exp(days: int = 7): return data.expiring_soon(days)

@app.get("/metrics/lowstock")
def m_low(): return data.low_stock()

@app.get("/metrics/vendors")
def m_vend(): return data.vendor_scorecard()

@app.get("/metrics/promotions")
def m_promo(): return data.promotion_roi()

@app.get("/metrics/ads")
def m_ads(): return data.ad_program_roi()

@app.get("/metrics/feedback")
def m_fb(): return data.feedback_signal()

@app.get("/metrics/revenue/daily")
def m_rev(): return data.daily_revenue()


# ---- forecasting / projection ----
@app.get("/forecast/demand")
def f_demand(horizon: int = 14): return forecast.forecast_category_demand(horizon)

@app.get("/forecast/profit")
def f_profit(horizon: int = 30, revenue_multiplier: float = 1.0,
             cost_multiplier: float = 1.0):
    return forecast.project_profit(horizon, revenue_multiplier, cost_multiplier)


# ---- reports (JSON export) ----
@app.get("/reports")
def list_reports():
    return {"reports": list(reports.REPORTS.keys())}

@app.get("/reports/{name}")
def get_report(name: str, horizon: int = 14):
    fn = reports.REPORTS.get(name)
    if not fn:
        return JSONResponse({"error": "unknown report"}, status_code=404)
    try:
        return fn(horizon) if name in ("forecast_plan",) else fn()
    except TypeError:
        return fn()


# ---- SVG charts (vector export) ----
@app.get("/charts/{name}.svg")
def chart_svg(name: str):
    svg = ""
    if name == "profit_by_category":
        rows = data.profit_by_category()
        svg = charts.bar_chart([r["category"] for r in rows],
                               [r["net_profit"] for r in rows],
                               title="Net Profit by Category", value_prefix="$")
    elif name == "profit_per_foot":
        rows = data.profit_by_shelf()[:10]
        svg = charts.bar_chart([r["shelf"] for r in rows],
                               [r["profit_per_foot"] for r in rows],
                               title="Profit per Linear Foot", value_prefix="$")
    elif name == "loss_by_cause":
        rows = data.loss_breakdown()["by_cause"]
        svg = charts.donut_chart([r["cause"] for r in rows],
                                 [r["loss_value"] for r in rows],
                                 title="Loss by Cause")
    elif name == "revenue_trend":
        rows = data.daily_revenue()
        svg = charts.line_chart([r["sale_date"][5:] for r in rows],
                                [{"name": "Revenue", "values": [r["revenue"] for r in rows]},
                                 {"name": "Gross Profit", "values": [r["gross_profit"] for r in rows]}],
                                title="Revenue & Gross Profit Trend", value_prefix="$")
    elif name == "profit_projection":
        proj = forecast.project_profit(30)
        rows = proj["projection"]
        svg = charts.line_chart([r["date"][5:] for r in rows],
                                [{"name": "Projected GP", "values": [r["projected_gross_profit"] for r in rows]}],
                                title="30-Day Profit Projection", value_prefix="$")
    elif name == "demand_forecast":
        fc = forecast.forecast_category_demand(14)
        series = []
        labels = []
        for c in fc["categories"][:5]:
            if not labels:
                labels = [f["date"][5:] for f in c["forecast"]]
            series.append({"name": c["category"], "values": [f["units"] for f in c["forecast"]]})
        svg = charts.line_chart(labels, series, title="14-Day Demand Forecast")
    else:
        return Response("<svg xmlns='http://www.w3.org/2000/svg'></svg>",
                        media_type="image/svg+xml")
    return Response(svg, media_type="image/svg+xml")


# ---- what-if assistant ----
class WhatIf(BaseModel):
    question: str

@app.post("/whatif")
def whatif_query(body: WhatIf):
    return whatif.ask_whatif(body.question)

@app.post("/whatif/reindex")
def whatif_reindex():
    return whatif.build_context_index()
