"""Database access + metric computations using pandas."""
import os
from datetime import date, timedelta

import pandas as pd
from sqlalchemy import create_engine, text

DATABASE_URL = os.getenv(
    "DATABASE_URL", "postgresql://grocery:grocery_pw@postgres:5432/grocery"
).replace("postgresql://", "postgresql+psycopg2://")

_engine = None


def engine():
    global _engine
    if _engine is None:
        _engine = create_engine(DATABASE_URL, pool_pre_ping=True)
    return _engine


def df(sql, params=None):
    with engine().connect() as c:
        return pd.read_sql(text(sql), c, params=params or {})


# --------------------------------------------------------------------------
# KPI summary (investor headline numbers)
# --------------------------------------------------------------------------
def kpi_summary():
    sales = df("SELECT sale_date, revenue, cogs FROM sales")
    loss = df("SELECT loss_date, cost_value FROM loss_events")
    if sales.empty:
        return {"revenue": 0, "gross_profit": 0, "net_profit": 0,
                "margin_pct": 0, "shrink_pct": 0, "loss_value": 0,
                "revenue_growth_pct": 0}

    revenue = float(sales["revenue"].sum())
    cogs = float(sales["cogs"].sum())
    gross = revenue - cogs
    loss_value = float(loss["cost_value"].sum()) if not loss.empty else 0.0
    net = gross - loss_value

    # revenue growth: last 30d vs prior 30d
    sales["sale_date"] = pd.to_datetime(sales["sale_date"])
    maxd = sales["sale_date"].max()
    last30 = sales[sales["sale_date"] > maxd - pd.Timedelta(days=30)]["revenue"].sum()
    prev30 = sales[(sales["sale_date"] <= maxd - pd.Timedelta(days=30)) &
                   (sales["sale_date"] > maxd - pd.Timedelta(days=60))]["revenue"].sum()
    growth = ((last30 - prev30) / prev30 * 100) if prev30 else 0.0

    return {
        "revenue": round(revenue, 2),
        "gross_profit": round(gross, 2),
        "net_profit": round(net, 2),
        "margin_pct": round(gross / revenue * 100, 2) if revenue else 0,
        "shrink_pct": round(loss_value / revenue * 100, 2) if revenue else 0,
        "loss_value": round(loss_value, 2),
        "revenue_growth_pct": round(growth, 2),
    }


# --------------------------------------------------------------------------
# Profit by category / shelf (profit per linear foot)
# --------------------------------------------------------------------------
def profit_by_category():
    q = """
        SELECT p.category,
               SUM(s.revenue) AS revenue,
               SUM(s.revenue - s.cogs) AS gross_profit
        FROM sales s JOIN products p ON p.product_id = s.product_id
        GROUP BY p.category ORDER BY gross_profit DESC
    """
    d = df(q)
    loss = df("""SELECT p.category, SUM(l.cost_value) AS loss_value
                 FROM loss_events l JOIN products p ON p.product_id=l.product_id
                 GROUP BY p.category""")
    d = d.merge(loss, on="category", how="left").fillna({"loss_value": 0})
    d["net_profit"] = d["gross_profit"] - d["loss_value"]
    d["margin_pct"] = (d["gross_profit"] / d["revenue"] * 100).round(2)
    return d.round(2).to_dict(orient="records")


def profit_by_shelf():
    q = """
        SELECT sh.shelf_id, sh.name AS shelf, sh.aisle, sh.category,
               sh.linear_feet,
               COALESCE(SUM(s.revenue - s.cogs),0) AS gross_profit,
               COALESCE(SUM(s.revenue),0) AS revenue
        FROM shelves sh
        LEFT JOIN products p ON p.shelf_id = sh.shelf_id
        LEFT JOIN sales s ON s.product_id = p.product_id
        GROUP BY sh.shelf_id, sh.name, sh.aisle, sh.category, sh.linear_feet
        ORDER BY gross_profit DESC
    """
    d = df(q)
    d["profit_per_foot"] = (d["gross_profit"] / d["linear_feet"]).round(2)
    return d.round(2).to_dict(orient="records")


# --------------------------------------------------------------------------
# Loss breakdown by cause and category
# --------------------------------------------------------------------------
def loss_breakdown():
    by_cause = df("""SELECT cause, SUM(cost_value) AS loss_value, SUM(units) AS units
                     FROM loss_events GROUP BY cause ORDER BY loss_value DESC""")
    by_cat = df("""SELECT p.category, SUM(l.cost_value) AS loss_value
                   FROM loss_events l JOIN products p ON p.product_id=l.product_id
                   GROUP BY p.category ORDER BY loss_value DESC""")
    return {"by_cause": by_cause.round(2).to_dict(orient="records"),
            "by_category": by_cat.round(2).to_dict(orient="records")}


# --------------------------------------------------------------------------
# Expiring soon + low stock (operations)
# --------------------------------------------------------------------------
def expiring_soon(days=7):
    q = """
        SELECT p.name, p.category, i.on_hand, i.expire_date,
               (i.expire_date - CURRENT_DATE) AS days_left,
               (i.on_hand * p.unit_price) AS retail_at_risk
        FROM inventory i JOIN products p ON p.product_id=i.product_id
        WHERE i.snapshot_date = (SELECT MAX(snapshot_date) FROM inventory)
          AND i.expire_date <= CURRENT_DATE + (:days || ' days')::interval
        ORDER BY days_left ASC
        LIMIT 50
    """
    return df(q, {"days": days}).round(2).to_dict(orient="records")


def low_stock():
    q = """
        SELECT p.name, p.category, p.par_level,
               COALESCE(SUM(i.on_hand),0) AS on_hand,
               v.name AS vendor, v.lead_time_days
        FROM products p
        LEFT JOIN inventory i ON i.product_id=p.product_id
            AND i.snapshot_date=(SELECT MAX(snapshot_date) FROM inventory)
        LEFT JOIN vendors v ON v.vendor_id=p.vendor_id
        GROUP BY p.product_id, p.name, p.category, p.par_level, v.name, v.lead_time_days
        HAVING COALESCE(SUM(i.on_hand),0) < p.par_level
        ORDER BY (p.par_level - COALESCE(SUM(i.on_hand),0)) DESC
        LIMIT 50
    """
    return df(q).to_dict(orient="records")


# --------------------------------------------------------------------------
# Vendor scorecard
# --------------------------------------------------------------------------
def vendor_scorecard():
    q = """
        SELECT v.name AS vendor, v.category,
               COUNT(*) AS deliveries,
               SUM(d.received_units)::float / NULLIF(SUM(d.ordered_units),0) AS fill_rate,
               AVG(CASE WHEN d.on_time THEN 1 ELSE 0 END) AS on_time_rate
        FROM vendor_deliveries d JOIN vendors v ON v.vendor_id=d.vendor_id
        GROUP BY v.name, v.category ORDER BY on_time_rate DESC
    """
    d = df(q)
    d["fill_rate"] = (d["fill_rate"] * 100).round(1)
    d["on_time_rate"] = (d["on_time_rate"] * 100).round(1)
    return d.to_dict(orient="records")


# --------------------------------------------------------------------------
# Promotion / ad ROI
# --------------------------------------------------------------------------
def promotion_roi():
    progs = df("SELECT * FROM discount_programs")
    if progs.empty:
        return []
    out = []
    for _, p in progs.iterrows():
        promo = df("""SELECT COALESCE(SUM(revenue-cogs),0) AS gp, COALESCE(SUM(revenue),0) AS rev
                      FROM sales WHERE discount_program_id=:id""", {"id": int(p.discount_program_id)})
        # baseline: same-category daily margin outside the promo window, scaled to window length
        base = df("""SELECT COALESCE(AVG(daily_gp),0) AS avg_gp FROM (
                        SELECT sale_date, SUM(s.revenue-s.cogs) AS daily_gp
                        FROM sales s JOIN products pr ON pr.product_id=s.product_id
                        WHERE pr.category=:cat AND s.discount_program_id IS NULL
                        GROUP BY sale_date) t""", {"cat": p.category})
        window_days = max((p.end_date - p.start_date).days, 1)
        baseline_gp = float(base["avg_gp"].iloc[0]) * window_days
        promo_gp = float(promo["gp"].iloc[0])
        lift = promo_gp - baseline_gp
        out.append({
            "program": p["name"], "category": p.category,
            "discount_pct": float(p.discount_pct),
            "promo_gross_profit": round(promo_gp, 2),
            "baseline_gross_profit": round(baseline_gp, 2),
            "incremental_margin": round(lift, 2),
            "roi_label": "positive" if lift > 0 else "negative",
        })
    return sorted(out, key=lambda x: x["incremental_margin"], reverse=True)


def ad_program_roi():
    ads = df("SELECT * FROM ad_programs")
    out = []
    for _, a in ads.iterrows():
        m = df("""SELECT COALESCE(SUM(s.revenue-s.cogs),0) AS gp
                  FROM sales s JOIN products p ON p.product_id=s.product_id
                  WHERE p.category=:cat AND s.sale_date BETWEEN :s AND :e""",
               {"cat": a.category, "s": a.start_date, "e": a.end_date})
        gp = float(m["gp"].iloc[0])
        spend = float(a.spend)
        out.append({
            "program": a["name"], "channel": a.channel, "category": a.category,
            "spend": round(spend, 2), "attributable_margin": round(gp, 2),
            "roi_x": round(gp / spend, 2) if spend else 0,
        })
    return sorted(out, key=lambda x: x["roi_x"], reverse=True)


# --------------------------------------------------------------------------
# Customer feedback signal
# --------------------------------------------------------------------------
def feedback_signal():
    trend = df("""SELECT feedback_date, AVG(sentiment) AS sentiment, AVG(rating) AS rating
                  FROM customer_feedback GROUP BY feedback_date ORDER BY feedback_date""")
    themes = df("""SELECT theme, COUNT(*) AS n, AVG(sentiment) AS sentiment
                   FROM customer_feedback WHERE theme IS NOT NULL
                   GROUP BY theme ORDER BY n DESC""")
    trend["feedback_date"] = trend["feedback_date"].astype(str)
    return {"trend": trend.round(3).to_dict(orient="records"),
            "themes": themes.round(3).to_dict(orient="records")}


# --------------------------------------------------------------------------
# Daily revenue series (for charts / forecasting)
# --------------------------------------------------------------------------
def daily_revenue():
    d = df("""SELECT sale_date, SUM(revenue) AS revenue, SUM(revenue-cogs) AS gross_profit
              FROM sales GROUP BY sale_date ORDER BY sale_date""")
    d["sale_date"] = d["sale_date"].astype(str)
    return d.round(2).to_dict(orient="records")


def category_demand_series():
    d = df("""SELECT sale_date, p.category, SUM(units) AS units
              FROM sales s JOIN products p ON p.product_id=s.product_id
              GROUP BY sale_date, p.category ORDER BY sale_date""")
    d["sale_date"] = d["sale_date"].astype(str)
    return d.to_dict(orient="records")
