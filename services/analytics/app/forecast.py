"""
Forecasting & projection
------------------------
Transparent, explainable models (the assumptions are visible to investors):
  * demand forecast per category: linear trend + day-of-week seasonal factor
  * profit projection: linear regression on daily gross profit, with a
    user-adjustable what-if multiplier applied on top.
scikit-learn LinearRegression is used so the coefficients can be inspected.
"""
import numpy as np
import pandas as pd
from sklearn.linear_model import LinearRegression

from . import data


def _fit_trend(values: np.ndarray):
    x = np.arange(len(values)).reshape(-1, 1)
    model = LinearRegression().fit(x, values)
    return model


def forecast_category_demand(horizon_days: int = 14):
    rows = data.category_demand_series()
    if not rows:
        return {"horizon_days": horizon_days, "categories": []}
    df = pd.DataFrame(rows)
    df["sale_date"] = pd.to_datetime(df["sale_date"])
    out = []
    for cat, g in df.groupby("category"):
        g = g.sort_values("sale_date")
        daily = g.groupby("sale_date")["units"].sum().asfreq("D").fillna(0)
        if len(daily) < 7:
            continue
        vals = daily.values.astype(float)
        model = _fit_trend(vals)
        # day-of-week seasonal factors
        dow = pd.Series(vals, index=daily.index).groupby(daily.index.dayofweek).mean()
        overall = vals.mean() or 1.0
        seasonal = (dow / overall).to_dict()

        last_idx = len(vals)
        future = []
        last_date = daily.index[-1]
        for h in range(1, horizon_days + 1):
            d = last_date + pd.Timedelta(days=h)
            trend = float(model.predict([[last_idx + h]])[0])
            factor = seasonal.get(d.dayofweek, 1.0)
            pred = max(trend * factor, 0)
            future.append({"date": d.strftime("%Y-%m-%d"), "units": round(pred, 1)})
        out.append({
            "category": cat,
            "trend_slope": round(float(model.coef_[0]), 3),
            "avg_daily_units": round(overall, 1),
            "forecast": future,
            "forecast_total": round(sum(f["units"] for f in future), 1),
        })
    return {"horizon_days": horizon_days, "categories": out}


def project_profit(horizon_days: int = 30, revenue_multiplier: float = 1.0,
                   cost_multiplier: float = 1.0):
    """Project net profit forward. Multipliers let the dashboard run quick
    what-if levers (e.g. revenue_multiplier=1.05 for a 5% sales lift)."""
    rows = data.daily_revenue()
    if not rows:
        return {"horizon_days": horizon_days, "projection": [], "summary": {}}
    df = pd.DataFrame(rows)
    df["sale_date"] = pd.to_datetime(df["sale_date"])
    df = df.sort_values("sale_date")

    gp = df["gross_profit"].values.astype(float)
    rev = df["revenue"].values.astype(float)
    model_gp = _fit_trend(gp)
    n = len(gp)

    last_date = df["sale_date"].iloc[-1]
    proj = []
    total = 0.0
    for h in range(1, horizon_days + 1):
        base = float(model_gp.predict([[n + h]])[0])
        adjusted = base * revenue_multiplier - base * (cost_multiplier - 1.0)
        adjusted = max(adjusted, 0)
        total += adjusted
        proj.append({
            "date": (last_date + pd.Timedelta(days=h)).strftime("%Y-%m-%d"),
            "projected_gross_profit": round(adjusted, 2),
        })

    hist_daily = float(gp.mean())
    return {
        "horizon_days": horizon_days,
        "revenue_multiplier": revenue_multiplier,
        "cost_multiplier": cost_multiplier,
        "assumptions": {
            "model": "LinearRegression on daily gross profit",
            "trend_slope_per_day": round(float(model_gp.coef_[0]), 3),
            "historical_avg_daily_gross_profit": round(hist_daily, 2),
        },
        "projection": proj,
        "summary": {
            "projected_total_gross_profit": round(total, 2),
            "projected_avg_daily": round(total / horizon_days, 2),
        },
    }
