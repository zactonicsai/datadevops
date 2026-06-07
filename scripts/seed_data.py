#!/usr/bin/env python3
"""
Seed the grocery database with ~90 days of realistic example data:
products across 8 categories, shelves, vendors, daily sales with seasonality,
inventory with expire dates, vendor deliveries, customer feedback, ad &
discount programs, and loss events. Idempotent: truncates first.

Run from host after the stack is up:
    pip install psycopg2-binary
    DATABASE_URL=postgresql://grocery:grocery_pw@localhost:5432/grocery \
        python scripts/seed_data.py
"""
import os
import random
from datetime import date, timedelta

import psycopg2
import psycopg2.extras

random.seed(42)
DB = os.getenv("DATABASE_URL", "postgresql://grocery:grocery_pw@localhost:5432/grocery")
DAYS = 90
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


def main():
    conn = psycopg2.connect(DB)
    conn.autocommit = False
    cur = conn.cursor()

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

    # discount programs (a few) + ad programs
    disc_ids = []
    promo_defs = [
        ("Dairy Days", "Dairy", 15), ("Snack Attack", "Snacks", 20),
        ("Fresh Produce Week", "Produce", 10), ("Frozen Fest", "Frozen", 25),
    ]
    for nm, cat, d in promo_defs:
        start = TODAY - timedelta(days=random.randint(20, 70))
        end = start + timedelta(days=7)
        cur.execute("""INSERT INTO discount_programs(name, category, discount_pct, start_date, end_date)
                       VALUES (%s,%s,%s,%s,%s) RETURNING discount_program_id""",
                    (nm, cat, d, start, end))
        disc_ids.append((cur.fetchone()[0], cat, d, start, end))

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

    # daily sales with weekly seasonality + slight upward trend
    print("Generating sales…")
    sales_rows = []
    for d in range(DAYS):
        day = TODAY - timedelta(days=DAYS - 1 - d)
        dow = day.weekday()
        weekend = 1.35 if dow >= 5 else 1.0
        trend = 1.0 + d * 0.0025  # ~ +0.25%/day
        for pid, cat, cost, price, sl, par in products:
            base = CATEGORIES[cat]["base_demand"] / len(PRODUCT_NAMES[cat])
            units = max(0, int(random.gauss(base * weekend * trend, base * 0.25)))
            if units == 0:
                continue
            # apply active discount program?
            dpid, disc = None, 0.0
            for (id_, dcat, dd, s, e) in disc_ids:
                if dcat == cat and s <= day <= e:
                    dpid, disc = id_, dd
                    units = int(units * 1.4)  # promo lift
                    break
            sale_price = round(price * (1 - disc / 100), 2)
            revenue = round(sale_price * units, 2)
            cogs = round(cost * units, 2)
            sales_rows.append((pid, day, units, sale_price, disc, revenue, cogs, dpid))
    psycopg2.extras.execute_values(cur,
        """INSERT INTO sales(product_id, sale_date, units, unit_price, discount_pct,
               revenue, cogs, discount_program_id) VALUES %s""", sales_rows)
    print(f"  {len(sales_rows)} sales rows")

    # current inventory snapshot with expire dates
    print("Generating inventory…")
    inv_rows = []
    for pid, cat, cost, price, sl, par in products:
        on_hand = random.randint(0, int(par * 1.4))
        received = TODAY - timedelta(days=random.randint(0, max(sl - 1, 1)))
        expire = received + timedelta(days=sl)
        inv_rows.append((pid, on_hand, received, expire, TODAY))
    psycopg2.extras.execute_values(cur,
        """INSERT INTO inventory(product_id, on_hand, received_date, expire_date, snapshot_date)
           VALUES %s""", inv_rows)

    # vendor deliveries
    print("Generating deliveries…")
    deliv = []
    for d in range(0, DAYS, 3):
        day = TODAY - timedelta(days=DAYS - 1 - d)
        for pid, cat, cost, price, sl, par in random.sample(products, k=min(8, len(products))):
            ordered = random.randint(20, 80)
            rel = 0.9
            received = int(ordered * random.uniform(0.85, 1.0))
            on_time = random.random() < rel
            ddate = day + timedelta(days=random.randint(1, 5))
            deliv.append((vendor_ids[cat], pid, ordered, received, day, ddate, on_time))
    psycopg2.extras.execute_values(cur,
        """INSERT INTO vendor_deliveries(vendor_id, product_id, ordered_units,
               received_units, order_date, delivery_date, on_time) VALUES %s""", deliv)

    # customer feedback
    print("Generating feedback…")
    fb = []
    for d in range(DAYS):
        day = TODAY - timedelta(days=DAYS - 1 - d)
        for _ in range(random.randint(1, 5)):
            theme = random.choice(THEMES)
            rating = random.choices([1, 2, 3, 4, 5], weights=[5, 8, 17, 40, 30])[0]
            sentiment = round((rating - 3) / 2 + random.uniform(-0.15, 0.15), 3)
            sentiment = max(-1, min(1, sentiment))
            cat = random.choice(list(CATEGORIES))
            fb.append((day, cat, rating, sentiment, theme,
                       f"{theme} comment ({rating}/5)"))
    psycopg2.extras.execute_values(cur,
        """INSERT INTO customer_feedback(feedback_date, category, rating, sentiment, theme, comment)
           VALUES %s""", fb)

    # loss events
    print("Generating loss events…")
    loss = []
    for d in range(DAYS):
        day = TODAY - timedelta(days=DAYS - 1 - d)
        for _ in range(random.randint(0, 4)):
            pid, cat, cost, price, sl, par = random.choice(products)
            cause = random.choices(LOSS_CAUSES, weights=[40, 20, 15, 25])[0]
            units = random.randint(1, 10)
            loss.append((pid, day, units, cause, round(cost * units, 2)))
    psycopg2.extras.execute_values(cur,
        """INSERT INTO loss_events(product_id, loss_date, units, cause, cost_value)
           VALUES %s""", loss)

    conn.commit()
    cur.close(); conn.close()
    print("Seed complete.")


if __name__ == "__main__":
    main()
