"""Assemble the five named reports as JSON documents."""
from datetime import datetime, timezone

from . import data, forecast


def _now():
    return datetime.now(timezone.utc).isoformat()


def daily_operations_report():
    return {
        "report": "Daily Operations",
        "generated_at": _now(),
        "expiring_soon": data.expiring_soon(7),
        "low_stock": data.low_stock(),
        "vendor_scorecard": data.vendor_scorecard(),
    }


def profit_margin_report():
    return {
        "report": "Profit & Margin",
        "generated_at": _now(),
        "kpi": data.kpi_summary(),
        "by_category": data.profit_by_category(),
        "by_shelf": data.profit_by_shelf(),
        "loss_breakdown": data.loss_breakdown(),
    }


def promotion_marketing_report():
    return {
        "report": "Promotion & Marketing ROI",
        "generated_at": _now(),
        "discount_programs": data.promotion_roi(),
        "ad_programs": data.ad_program_roi(),
        "feedback_signal": data.feedback_signal(),
    }


def forecast_plan_report(horizon=14):
    return {
        "report": "Forecast & Plan",
        "generated_at": _now(),
        "demand_forecast": forecast.forecast_category_demand(horizon),
        "low_stock": data.low_stock(),
    }


def investor_summary_report():
    proj = forecast.project_profit(30)
    return {
        "report": "Investor Summary",
        "generated_at": _now(),
        "kpi": data.kpi_summary(),
        "by_category": data.profit_by_category(),
        "profit_projection_30d": proj,
        "daily_revenue": data.daily_revenue(),
    }


REPORTS = {
    "daily_operations": daily_operations_report,
    "profit_margin": profit_margin_report,
    "promotion_marketing": promotion_marketing_report,
    "forecast_plan": forecast_plan_report,
    "investor_summary": investor_summary_report,
}
