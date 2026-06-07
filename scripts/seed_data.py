#!/usr/bin/env python3
"""
Seed the grocery database with ~90 days of realistic example data PLUS five
explicit, recognizable business scenarios so the dashboard, forecasts, and
what-if assistant have meaningful stories to surface.

Baseline: products across 8 categories, shelves, vendors, daily sales with
weekly seasonality + upward trend, inventory with expire dates, vendor
deliveries, customer feedback, ad & discount programs, loss events.

Scenarios layered on top (see SCENARIOS dict for the knobs):
  1. Margin squeeze   — Meat: vendor cost creeping up over the 90 days.
  2. Shrink problem   — Produce: heavy expiry/spoilage loss (high shrink %).
  3. Winning promo    — "Snack Attack": strong incremental lift, positive ROI.
  4. Losing promo     — "Frozen Fest": deep discount, little lift (negative ROI).
  5. Expiry crisis    — Dairy + Bakery: a cluster of stock expiring in <5 days.

Behavior:
  - By default this SKIPS seeding if the database already has sales rows, so a
    restart of the auto-seed container is a no-op. Set SEED_FORCE=1 to wipe and
    reseed. Set SEED_DAYS to change the history window (default 90).

Run from host after the stack is up (or let the auto-seed service do it):
    pip install psycopg2-binary
    DATABASE_URL=postgresql://grocery:grocery_pw@localhost:5432/grocery \
        python scripts/seed_data.py
"""
import os
import random
import sys
from datetime import date, timedelta

import psycopg2
import psycopg2.extras

random.seed(42)
DB = os.getenv("DATABASE_URL", "postgresql://grocery:grocery_pw@localhost:5432/grocery")
DAYS = int(os.getenv("SEED_DAYS", "90"))
FORCE = os.getenv("SEED_FORCE", "0") == "1"
TODAY = date.today()

CATEGORIES = {
    "Produce":   {"margin": 0.35, "shelf_life": 6,  "base_demand": 60, "cost": (0.5, 3.0)},
    "Dairy":     {"margin": 0.28, "shelf_life": 14, "base_demand": 50, "cost": (1.0, 5.0)},
    "Bakery":    {"margin": 0.45, "shelf_life": 4,  "base_demand": 40, "cost": (0.8, 4.0)},
    "Meat":      {"margin": 0.22, "shelf_life": 7,  "base_demand": 35, "cost": (3.0, 12.0)},
    "Frozen":    {"margin": 0.30, "shelf_life": 120,"base_demand": 30, "cost": (1.5, 7.0)},
    "Beverages": {"margin": 0.40, "shelf_life": 180,"base_demand": 55, "cost": (0.6, 4.0)},
    "Snacks":    {"margin": 0.48, "shelf_life": 90, "base_demand": 45, "cost": (0.7, 3.5)},
    "Household": {"margin": 0.33, "shelf_life": 365,"base_demand": 25, "cost": (1.0, 9.0)},
}

PRODUCT_NAMES = {
    "Produce": ["Bananas", "Apples", "Spinach", "Tomatoes", "Avocados", "Carrots"],
    "Dairy": ["Whole Milk", "Greek Yogurt", "Cheddar Block", "Butter", "Eggs Dozen"],
    "Bakery": ["Sourdough Loaf", "Bagels 6ct", "Croissants 4ct", "Muffins 4ct"],
    "Meat": ["Ground Beef", "Chicken Breast", "Pork Chops", "Salmon Fillet"],
    "Frozen": ["Frozen Pizza", "Ice Cream", "Frozen Veg", "Frozen Berries"],
    "Beverages": ["Orange Juice", "Cola 12pk", "Sparkling Water", "Cold Brew"],
    "Snacks": ["Potato Chips", "Tortilla Chips", "Granola Bars", "Trail Mix"],
    "Household": ["Paper Towels", "Dish Soap", "Laundry Pods", "Trash Bags"],
}

THEMES = ["price", "freshness", "service", "availability", "selection"]
LOSS_CAUSES = ["expiry", "damage", "theft", "markdown"]

# ---------------------------------------------------------------------------
# Scenario configuration — these knobs make specific stories show up in the
# analytics. Tweak here to change the narrative the dashboard tells.
# ---------------------------------------------------------------------------
SCENARIOS = {
    "margin_squeeze_category": "Meat",      # vendor cost rises over the window
    "margin_squeeze_total_pct": 0.18,       # +18% unit cost from day 0 -> today
    "shrink_problem_category": "Produce",   # elevated spoilage loss
    "shrink_problem_multiplier": 3.5,       # x more loss events than baseline
    "winning_promo": {"name": "Snack Attack", "category": "Snacks",
                       "discount_pct": 20, "lift": 1.9},   # strong lift -> good ROI
    "losing_promo": {"name": "Frozen Fest", "category": "Frozen",
                     "discount_pct": 30, "lift": 1.05},    # deep cut, weak lift -> bad ROI
    "expiry_crisis_categories": ["Dairy", "Bakery"],       # cluster expiring <5 days
}


def already_seeded(cur):
    cur.execute("SELECT COUNT(*) FROM sales;")
    return cur.fetchone()[0] > 0


def main():
    conn = psycopg2.connect(DB)
    conn.autocommit = False
    cur = conn.cursor()

    if already_seeded(cur) and not FORCE:
        cur.execute("SELECT COUNT(*) FROM sales;")
        n = cur.fetchone()[0]
        print(f"Database already has {n} sales rows; skipping seed. "
              f"Set SEED_FORCE=1 to wipe and reseed.")
        cur.close(); conn.close()
        return

    print("Truncating…")
    cur.execute("""TRUNCATE loss_events, sales, inventory, vendor_deliveries,
                   customer_feedback, discount_programs, ad_programs,
                   products, shelves, vendors, message_log RESTART IDENTITY CASCADE;""")

    # vendors (one per category)
    vendor_ids = {}
    for cat in CATEGORIES:
        cur.execute("""INSERT INTO vendors(name, category, lead_time_days, reliability)
                       VALUES (%s,%s,%s,%s) RETURNING vendor_id""",
                    (f"{cat} Supply Co", cat, random.randint(2, 6), round(random.uniform(0.82, 0.98), 3)))
        vendor_ids[cat] = cur.fetchone()[0]

    # shelves (one per category, with linear feet)
    shelf_ids = {}
    aisle = 1
    for cat in CATEGORIES:
        cur.execute("""INSERT INTO shelves(name, aisle, linear_feet, category)
                       VALUES (%s,%s,%s,%s) RETURNING shelf_id""",
                    (f"{cat} Shelf", f"A{aisle}", round(random.uniform(8, 24), 1), cat))
        shelf_ids[cat] = cur.fetchone()[0]
        aisle += 1

    # products
    products = []  # (id, cat, cost, price, shelf_life, par)
    for cat, names in PRODUCT_NAMES.items():
        meta = CATEGORIES[cat]
        for nm in names:
            cost = round(random.uniform(*meta["cost"]), 2)
            price = round(cost / (1 - meta["margin"]), 2)
            par = random.randint(30, 70)
            sl = meta["shelf_life"]
            cur.execute("""INSERT INTO products(sku, name, category, shelf_id, vendor_id,
                               unit_cost, unit_price, par_level, shelf_life_days)
                           VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING product_id""",
                        (f"{cat[:3].upper()}-{len(products):03d}", nm, cat,
                         shelf_ids[cat], vendor_ids[cat], cost, price, par, sl))
            pid = cur.fetchone()[0]
            products.append((pid, cat, cost, price, sl, par))

    # discount programs: scenario promos (recent, so they're in the lift window)
    # plus a couple of neutral ones.
    disc_ids = []
    win = SCENARIOS["winning_promo"]
    lose = SCENARIOS["losing_promo"]
    promo_defs = [
        (win["name"], win["category"], win["discount_pct"], win["lift"]),
        (lose["name"], lose["category"], lose["discount_pct"], lose["lift"]),
        ("Dairy Days", "Dairy", 15, 1.4),
        ("Fresh Produce Week", "Produce", 10, 1.3),
    ]
    promo_lift = {}
    for nm, cat, d, lift in promo_defs:
        # place each promo as a 7-day window ending within the last ~3 weeks
        end = TODAY - timedelta(days=random.randint(3, 20))
        start = end - timedelta(days=7)
        cur.execute("""INSERT INTO discount_programs(name, category, discount_pct, start_date, end_date)
                       VALUES (%s,%s,%s,%s,%s) RETURNING discount_program_id""",
                    (nm, cat, d, start, end))
        did = cur.fetchone()[0]
        disc_ids.append((did, cat, d, start, end))
        promo_lift[did] = lift

    # ad programs
    ad_defs = [
        ("Weekly Circular", "circular", "Produce", 1200),
        ("Digital Coupons", "digital", "Snacks", 800),
        ("In-store Endcap", "instore", "Beverages", 450),
        ("Radio Spot", "radio", "Meat", 1500),
    ]
    for nm, ch, cat, spend in ad_defs:
        start = TODAY - timedelta(days=random.randint(20, 70))
        end = start + timedelta(days=14)
        cur.execute("""INSERT INTO ad_programs(name, channel, category, start_date, end_date, spend)
                       VALUES (%s,%s,%s,%s,%s,%s)""", (nm, ch, cat, start, end, spend))

    # ---- daily sales with weekly seasonality + slight upward trend ----
    # Scenario 1 (margin squeeze): the cost of goods for the target category
    # rises linearly across the window, so recent COGS is higher and margin
    # erodes even as revenue holds.
    print("Generating sales…")
    squeeze_cat = SCENARIOS["margin_squeeze_category"]
    squeeze_total = SCENARIOS["margin_squeeze_total_pct"]
    sales_rows = []
    for d in range(DAYS):
        day = TODAY - timedelta(days=DAYS - 1 - d)
        dow = day.weekday()
        weekend = 1.35 if dow >= 5 else 1.0
        trend = 1.0 + d * 0.0025  # ~ +0.25%/day
        frac = d / max(DAYS - 1, 1)
        for pid, cat, cost, price, sl, par in products:
            base = CATEGORIES[cat]["base_demand"] / len(PRODUCT_NAMES[cat])
            units = max(0, int(random.gauss(base * weekend * trend, base * 0.25)))
            if units == 0:
                continue
            # effective unit cost — apply the margin-squeeze ramp for the target
            eff_cost = cost
            if cat == squeeze_cat:
                eff_cost = round(cost * (1 + squeeze_total * frac), 2)
            # apply active discount program?
            dpid, disc = None, 0.0
            for (id_, dcat, dd, s, e) in disc_ids:
                if dcat == cat and s <= day <= e:
                    dpid, disc = id_, dd
                    units = int(units * promo_lift.get(id_, 1.4))
                    break
            sale_price = round(price * (1 - disc / 100), 2)
            revenue = round(sale_price * units, 2)
            cogs = round(eff_cost * units, 2)
            sales_rows.append((pid, day, units, sale_price, disc, revenue, cogs, dpid))
    psycopg2.extras.execute_values(cur,
        """INSERT INTO sales(product_id, sale_date, units, unit_price, discount_pct,
               revenue, cogs, discount_program_id) VALUES %s""", sales_rows)
    print(f"  {len(sales_rows)} sales rows")

    # ---- current inventory snapshot with expire dates ----
    # Scenario 5 (expiry crisis): force a cluster of near-expiry stock for the
    # target categories so "expiring soon" lights up.
    print("Generating inventory…")
    crisis_cats = set(SCENARIOS["expiry_crisis_categories"])
    inv_rows = []
    for pid, cat, cost, price, sl, par in products:
        on_hand = random.randint(0, int(par * 1.4))
        if cat in crisis_cats and random.random() < 0.7:
            # received recently but expiring in 1-4 days, with healthy stock at risk
            days_left = random.randint(1, 4)
            expire = TODAY + timedelta(days=days_left)
            received = expire - timedelta(days=sl)
            on_hand = random.randint(int(par * 0.6), int(par * 1.3))
        else:
            received = TODAY - timedelta(days=random.randint(0, max(sl - 1, 1)))
            expire = received + timedelta(days=sl)
        inv_rows.append((pid, on_hand, received, expire, TODAY))
    psycopg2.extras.execute_values(cur,
        """INSERT INTO inventory(product_id, on_hand, received_date, expire_date, snapshot_date)
           VALUES %s""", inv_rows)

    # ---- vendor deliveries ----
    print("Generating deliveries…")
    deliv = []
    for d in range(0, DAYS, 3):
        day = TODAY - timedelta(days=DAYS - 1 - d)
        for pid, cat, cost, price, sl, par in random.sample(products, k=min(8, len(products))):
            ordered = random.randint(20, 80)
            # the margin-squeeze vendor is also a bit less reliable (late/short)
            rel = 0.72 if cat == squeeze_cat else 0.9
            received = int(ordered * random.uniform(0.78 if cat == squeeze_cat else 0.85, 1.0))
            on_time = random.random() < rel
            ddate = day + timedelta(days=random.randint(1, 5))
            deliv.append((vendor_ids[cat], pid, ordered, received, day, ddate, on_time))
    psycopg2.extras.execute_values(cur,
        """INSERT INTO vendor_deliveries(vendor_id, product_id, ordered_units,
               received_units, order_date, delivery_date, on_time) VALUES %s""", deliv)

    # ---- customer feedback ----
    # Scenario 2 echo: the high-shrink (Produce) category draws more "freshness"
    # complaints with lower ratings, so the feedback signal corroborates loss.
    print("Generating feedback…")
    shrink_cat = SCENARIOS["shrink_problem_category"]
    fb = []
    for d in range(DAYS):
        day = TODAY - timedelta(days=DAYS - 1 - d)
        for _ in range(random.randint(1, 5)):
            cat = random.choice(list(CATEGORIES))
            if cat == shrink_cat and random.random() < 0.6:
                theme = "freshness"
                rating = random.choices([1, 2, 3, 4, 5], weights=[22, 26, 28, 16, 8])[0]
            else:
                theme = random.choice(THEMES)
                rating = random.choices([1, 2, 3, 4, 5], weights=[5, 8, 17, 40, 30])[0]
            sentiment = round((rating - 3) / 2 + random.uniform(-0.15, 0.15), 3)
            sentiment = max(-1, min(1, sentiment))
            fb.append((day, cat, rating, sentiment, theme, f"{theme} comment ({rating}/5)"))
    psycopg2.extras.execute_values(cur,
        """INSERT INTO customer_feedback(feedback_date, category, rating, sentiment, theme, comment)
           VALUES %s""", fb)

    # ---- loss events ----
    # Scenario 2 (shrink problem): elevated expiry loss for the target category.
    print("Generating loss events…")
    shrink_mult = SCENARIOS["shrink_problem_multiplier"]
    shrink_products = [p for p in products if p[1] == shrink_cat]
    loss = []
    for d in range(DAYS):
        day = TODAY - timedelta(days=DAYS - 1 - d)
        # baseline loss across all categories
        for _ in range(random.randint(0, 4)):
            pid, cat, cost, price, sl, par = random.choice(products)
            cause = random.choices(LOSS_CAUSES, weights=[40, 20, 15, 25])[0]
            units = random.randint(1, 10)
            loss.append((pid, day, units, cause, round(cost * units, 2)))
        # extra spoilage concentrated in the shrink-problem category
        for _ in range(int(random.uniform(0, 4) * shrink_mult / 2)):
            if not shrink_products:
                break
            pid, cat, cost, price, sl, par = random.choice(shrink_products)
            units = random.randint(3, 14)
            loss.append((pid, day, units, "expiry", round(cost * units, 2)))
    psycopg2.extras.execute_values(cur,
        """INSERT INTO loss_events(product_id, loss_date, units, cause, cost_value)
           VALUES %s""", loss)

    conn.commit()
    cur.close(); conn.close()
    print("Seed complete.")
    print("Scenarios seeded: margin squeeze (%s), shrink problem (%s), "
          "winning promo (%s), losing promo (%s), expiry crisis (%s)." % (
              SCENARIOS["margin_squeeze_category"],
              SCENARIOS["shrink_problem_category"],
              SCENARIOS["winning_promo"]["name"],
              SCENARIOS["losing_promo"]["name"],
              ", ".join(SCENARIOS["expiry_crisis_categories"])))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"Seed failed: {e}", file=sys.stderr)
        raise
