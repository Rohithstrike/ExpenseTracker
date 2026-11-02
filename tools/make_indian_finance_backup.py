#!/usr/bin/env python3
"""
Generate a realistic Indian INR-only ExpenseTracker backup and an independent
expected-results report.

This script writes files only to the output directory. It does not modify the
Xcode project, application source, app settings, device, or existing backups.

Confirmed backup format:
  BackupFile formatVersion = 1
  Foundation reference-date timestamps (2001-01-01)
  amountMinor = integer paise
  kindRaw values assumed from the supplied prior generator:
      expense, income, transferOut, transferIn

IMPORTANT:
The supplied BackupService.swift confirms the backup structure and transfer
pairing rules, but the app's Transaction.validate(), Money limits, model files,
and default-category seeder were not supplied. Review those assumptions before
restoring into the app.

Usage:
  python3 tools/make_indian_finance_backup.py
  python3 tools/make_indian_finance_backup.py --seed 20261031
  python3 tools/make_indian_finance_backup.py --today 2026-10-31
  python3 tools/make_indian_finance_backup.py --out ~/Documents/ExpenseTracker-Sample-Data
  python3 tools/make_indian_finance_backup.py --force
"""

import argparse
import calendar
import datetime as dt
import json
import random
import re
import sys
import time
import uuid
from collections import Counter, defaultdict
from pathlib import Path

REF_UNIX = 978_307_200
FORMAT_VERSION = 1

# Conservative cap based on the earlier generator's assumed Money limit.
# Confirm Money.maxInputMinorUnits in the actual app before restoring.
MAX_MINOR = 99_999_999_999
INT64_MAX = (1 << 63) - 1

TARGET_TRANSACTIONS = 4200
DAYS_BACK = 730
NAMESPACE = uuid.UUID("8f0c2a54-3d1e-4b7a-9c6e-5a1d2b3c4d5e")

KINDS = ("expense", "income", "transferOut", "transferIn")
PERIOD_ORDER = ("Today", "Yesterday", "This Month", "Last Month")

# Exactly four active INR wallets.
WALLETS = [
    {"name": "Cash", "emoji": "💵", "currency": "INR", "base": 80_000 * 100},
    {"name": "IOB", "emoji": "🏦", "currency": "INR", "base": 180_000 * 100},
    {"name": "SBI", "emoji": "🏦", "currency": "INR", "base": 300_000 * 100},
    {"name": "Axis Bank", "emoji": "💳", "currency": "INR", "base": 150_000 * 100},
]

# 18 plausible categories. Names/colours are generated independently because
# the app's actual default-category seeder was not included in the upload.
CATEGORIES = [
    ("Food & Dining", "🍽️", "#F97316"),
    ("Groceries", "🛒", "#22C55E"),
    ("Transport", "🚌", "#3B82F6"),
    ("Fuel", "⛽", "#EAB308"),
    ("Rent", "🏠", "#8B5CF6"),
    ("Utilities", "💡", "#F59E0B"),
    ("Mobile & Internet", "📱", "#06B6D4"),
    ("Shopping", "🛍️", "#EC4899"),
    ("Healthcare", "🏥", "#EF4444"),
    ("Entertainment", "🎬", "#A855F7"),
    ("Education", "🎓", "#6366F1"),
    ("Personal Care", "🧴", "#14B8A6"),
    ("Travel", "✈️", "#0EA5E9"),
    ("Home & Household", "🧹", "#84CC16"),
    ("Subscriptions", "📺", "#64748B"),
    ("Salary", "💼", "#16A34A"),
    ("Freelance", "💻", "#D946EF"),
    ("Other Income", "💰", "#0D9488"),
]

CAT = {item[0]: i for i, item in enumerate(CATEGORIES)}

# (weight, low rupees, high rupees); income categories are generated separately.
EXPENSE_PROFILES = {
    "Food & Dining": (15, 90, 1100),
    "Groceries": (14, 250, 4200),
    "Transport": (8, 30, 900),
    "Fuel": (7, 300, 3500),
    "Rent": (2, 7000, 24000),
    "Utilities": (4, 350, 4200),
    "Mobile & Internet": (3, 199, 1600),
    "Shopping": (7, 250, 8500),
    "Healthcare": (3, 150, 7500),
    "Entertainment": (4, 100, 1800),
    "Education": (2, 300, 12000),
    "Personal Care": (3, 100, 2200),
    "Travel": (2, 250, 9000),
    "Home & Household": (3, 150, 5000),
    "Subscriptions": (2, 99, 1500),
}
EXPENSE_NAMES = list(EXPENSE_PROFILES)
EXPENSE_WEIGHTS = [EXPENSE_PROFILES[n][0] for n in EXPENSE_NAMES]

MERCHANTS = {
    "Food & Dining": [
        "Swiggy order", "Zomato order", "Saravana Bhavan", "A2B Restaurant",
        "Local restaurant UPI", "Tea shop", "Cafe Coffee Day", "Food court",
        "Office lunch", "Bakery purchase",
    ],
    "Groceries": [
        "DMart grocery", "Reliance Smart", "More Supermarket", " local grocery shop",
        "Vegetable market", "Aavin milk", "BigBasket order", "Zepto grocery",
        "Kirana store UPI", "Provision store",
    ],
    "Transport": [
        "Rapido ride", "Ola cab", "Uber trip", "Chennai Metro", "MTC bus",
        "Auto fare UPI", "Railway ticket", "Parking fee",
    ],
    "Fuel": [
        "IndianOil petrol pump", "HP Petrol Bunk", "BPCL fuel station",
        "Bharat Petroleum", "Shell fuel",
    ],
    "Rent": ["Monthly house rent", "Apartment rent payment", "House rent UPI"],
    "Utilities": [
        "TANGEDCO electricity bill", "Water bill payment", "Gas cylinder booking",
        "Electricity bill UPI", "LPG refill",
    ],
    "Mobile & Internet": [
        "Jio recharge", "Airtel mobile bill", "BSNL recharge",
        "ACT Fibernet bill", "JioFiber broadband",
    ],
    "Shopping": [
        "Amazon order", "Flipkart order", "Myntra purchase", "Ajio order",
        "Reliance Trends", "Decathlon purchase", "Local clothing store",
    ],
    "Healthcare": [
        "Apollo Pharmacy", "MedPlus pharmacy", "Clinic consultation",
        "Hospital payment", "Diagnostic lab", "Doctor consultation",
    ],
    "Entertainment": [
        "PVR Cinemas", "INOX movie", "BookMyShow", "Gaming purchase",
        "Weekend outing",
    ],
    "Education": [
        "Online course fee", "Udemy course", "Books purchase",
        "Training material", "Exam fee",
    ],
    "Personal Care": [
        "Salon payment", "Haircut", "Personal care store", "Pharmacy toiletries",
    ],
    "Travel": [
        "IRCTC train booking", "MakeMyTrip booking", "Hotel payment",
        "Bus ticket booking", "Travel cab",
    ],
    "Home & Household": [
        "Household supplies", "Hardware store", "Cleaning supplies",
        "Home appliance purchase",
    ],
    "Subscriptions": [
        "Netflix subscription", "Spotify subscription", "YouTube Premium",
        "iCloud subscription", "Prime Video subscription",
    ],
}

INCOME_NOTES = {
    "Salary": ["Monthly salary credit", "Salary credited", "Payroll credit"],
    "Freelance": [
        "Freelance design payment", "Website project payment",
        "Consulting fee received", "Development project payment",
        "Client invoice settlement",
    ],
    "Other Income": ["Cashback received", "Interest credit", "Refund received"],
}

UPI_SUFFIXES = ["UPI", "UPI payment", "GPay", "PhonePe", "Paytm UPI"]


def uid(seed, kind, number):
    return str(uuid.uuid5(NAMESPACE, f"{seed}:{kind}:{number}")).upper()


def local_timestamp(day, seconds):
    """Unix timestamp for local wall-clock time in the machine's timezone."""
    hour, rem = divmod(int(seconds), 3600)
    minute, second = divmod(rem, 60)
    return int(time.mktime((
        day.year, day.month, day.day, hour, minute, second, 0, 0, -1
    )))


def foundation_timestamp(unix_seconds):
    return float(unix_seconds - REF_UNIX)


def month_add(year, month, delta):
    index = year * 12 + (month - 1) + delta
    return index // 12, index % 12 + 1


def month_days(year, month):
    return calendar.monthrange(year, month)[1]


def periods_for(today):
    first_this = today.replace(day=1)
    ny, nm = month_add(today.year, today.month, 1)
    first_next = dt.date(ny, nm, 1)
    last_day_prev = first_this - dt.timedelta(days=1)
    first_prev = last_day_prev.replace(day=1)
    return {
        "Today": (
            local_timestamp(today, 0),
            local_timestamp(today + dt.timedelta(days=1), 0),
        ),
        "Yesterday": (
            local_timestamp(today - dt.timedelta(days=1), 0),
            local_timestamp(today, 0),
        ),
        "This Month": (
            local_timestamp(first_this, 0),
            local_timestamp(first_next, 0),
        ),
        "Last Month": (
            local_timestamp(first_prev, 0),
            local_timestamp(first_this, 0),
        ),
    }


def indian_group(number):
    s = str(number)
    if len(s) <= 3:
        return s
    tail, head = s[-3:], s[:-3]
    pieces = []
    while len(head) > 2:
        pieces.insert(0, head[-2:])
        head = head[:-2]
    if head:
        pieces.insert(0, head)
    return ",".join(pieces + [tail])


def money(minor):
    sign = "-" if minor < 0 else ""
    whole, paise = divmod(abs(int(minor)), 100)
    return f"{sign}₹{indian_group(whole)}.{paise:02d}"


def make_row(kind, amount, wallet, category, timestamp, note, transfer=None):
    return {
        "kind": kind,
        "amount": int(amount),
        "wallet": int(wallet),
        "category": category,
        "timestamp": int(timestamp),
        "note": note,
        "transfer": transfer,
    }


def choose_wallet(rng, category=None):
    # Salary normally arrives in a bank; cash spending is common for small items.
    if category == "Salary":
        return rng.choices([1, 2, 3], weights=[35, 40, 25])[0]
    if category == "Freelance":
        return rng.choices([1, 2, 3], weights=[25, 35, 40])[0]
    if rng.random() < 0.30:
        return 0
    return rng.choices([1, 2, 3], weights=[30, 40, 30])[0]


def random_time(rng, day, real_today, now_seconds):
    if day == real_today:
        upper = max(0, min(23 * 3600 + 59 * 60, now_seconds - 90))
        lower = min(8 * 3600, upper)
        return rng.randint(lower, upper) if upper >= lower else upper
    return rng.randint(6 * 3600, 23 * 3600 + 30 * 60)


def amount_minor(rng, low_rupees, high_rupees):
    # Rounded to realistic ₹10 or ₹50 increments, represented in paise.
    step = 10 if high_rupees <= 5000 else 50
    lo = max(step, (low_rupees // step) * step)
    hi = max(lo, (high_rupees // step) * step)
    return rng.randint(lo // step, hi // step) * step * 100


def generate_rows(today, real_today, now_seconds, seed):
    rng = random.Random(seed)
    start = today - dt.timedelta(days=DAYS_BACK)
    rows = []

    # Monthly recurring income and rent, bounded to the requested 24-month span.
    cursor = today.year * 12 + today.month - 1
    start_cursor = start.year * 12 + start.month - 1
    month_index = 0
    while cursor >= start_cursor:
        year, month = divmod(cursor, 12)
        month += 1
        last = month_days(year, month)

        salary_day = min(rng.choice([1, 1, 1, 2, 3, 5]), last)
        salary_date = dt.date(year, month, salary_day)
        if start <= salary_date <= today:
            salary = amount_minor(rng, 48000, 105000)
            w = choose_wallet(rng, "Salary")
            rows.append(make_row(
                "income", salary, w, CAT["Salary"],
                local_timestamp(salary_date, 9 * 3600 + 15 * 60),
                rng.choice(INCOME_NOTES["Salary"]),
            ))

        # Rent is a separate monthly outflow, usually from a bank account.
        rent_date = dt.date(year, month, min(5, last))
        if start <= rent_date <= today:
            rent = amount_minor(rng, 9000, 26000)
            w = rng.choice([1, 2, 3])
            rows.append(make_row(
                "expense", rent, w, CAT["Rent"],
                local_timestamp(rent_date, 10 * 3600),
                rng.choice(MERCHANTS["Rent"]),
            ))

        # One or two freelance credits in many months, not every month.
        if rng.random() < 0.78:
            for _ in range(rng.choice([1, 1, 2])):
                day_num = rng.randint(4, last)
                d = dt.date(year, month, day_num)
                if start <= d <= today:
                    value = amount_minor(rng, 1500, 32000)
                    w = choose_wallet(rng, "Freelance")
                    rows.append(make_row(
                        "income", value, w, CAT["Freelance"],
                        local_timestamp(d, rng.randint(11, 20) * 3600),
                        rng.choice(INCOME_NOTES["Freelance"]),
                    ))

        # Occasional bank interest, refunds or cashback.
        if rng.random() < 0.35:
            d = dt.date(year, month, rng.randint(1, last))
            if start <= d <= today:
                value = amount_minor(rng, 20, 1800)
                w = rng.choice([1, 2, 3])
                rows.append(make_row(
                    "income", value, w, CAT["Other Income"],
                    local_timestamp(d, rng.randint(8, 18) * 3600),
                    rng.choice(INCOME_NOTES["Other Income"]),
                ))
        cursor -= 1
        month_index += 1

    # Distributed everyday spending. Average daily count is tuned so the final
    # dataset lands close to 4,200 including recurring income and transfers.
    for offset in range(DAYS_BACK + 1):
        day = today - dt.timedelta(days=offset)
        count = rng.choices(
            [1, 2, 3, 4, 5, 6, 7, 8],
            weights=[3, 8, 16, 23, 22, 16, 8, 4],
        )[0]
        # Ensure useful data in the two most recent day-based Progress periods.
        if offset in (0, 1):
            count = max(count, 4)
        for _ in range(count):
            category = rng.choices(EXPENSE_NAMES, weights=EXPENSE_WEIGHTS)[0]
            _, low, high = EXPENSE_PROFILES[category]
            value = amount_minor(rng, low, high)
            wallet = choose_wallet(rng, category)
            merchant = rng.choice(MERCHANTS[category])
            if rng.random() < 0.48 and category not in ("Rent", "Subscriptions"):
                merchant += " · " + rng.choice(UPI_SUFFIXES)
            rows.append(make_row(
                "expense", value, wallet, CAT[category],
                local_timestamp(day, random_time(rng, day, real_today, now_seconds)),
                merchant,
            ))

    # Transfers are inserted as paired rows with exactly equal timestamps,
    # amounts and notes. The validator requires two legs per transfer ID.
    transfer_count = 90
    for n in range(transfer_count):
        offset = rng.randint(0, DAYS_BACK)
        day = today - dt.timedelta(days=offset)
        source = rng.randrange(4)
        destination = rng.choice([i for i in range(4) if i != source])
        value = amount_minor(rng, 500, 18000)
        ts = local_timestamp(
            day, random_time(rng, day, real_today, now_seconds)
        )
        note = rng.choice([
            "Transfer between own accounts",
            "Move funds to savings",
            "Cash withdrawal transfer",
            "Monthly account transfer",
            "UPI transfer between own accounts",
        ])
        rows.append(make_row("transferOut", value, source, None, ts, note, n))
        rows.append(make_row("transferIn", value, destination, None, ts, note, n))

    rows.sort(key=lambda r: (r["timestamp"], r["kind"], r["wallet"]))
    # Aim for the requested range. Preserve recurring rows and paired transfers;
    # adjust only ordinary expense rows if random variation falls outside it.
    if len(rows) > TARGET_TRANSACTIONS:
        removable = [
            i for i, r in enumerate(rows)
            if r["kind"] == "expense" and r["category"] != CAT["Rent"]
        ]
        rng.shuffle(removable)
        remove_count = len(rows) - TARGET_TRANSACTIONS
        remove_set = set(removable[:remove_count])
        rows = [r for i, r in enumerate(rows) if i not in remove_set]
    elif len(rows) < TARGET_TRANSACTIONS:
        while len(rows) < TARGET_TRANSACTIONS:
            day = today - dt.timedelta(days=rng.randint(0, DAYS_BACK))
            category = rng.choices(EXPENSE_NAMES, weights=EXPENSE_WEIGHTS)[0]
            _, low, high = EXPENSE_PROFILES[category]
            rows.append(make_row(
                "expense", amount_minor(rng, low, high),
                choose_wallet(rng, category), CAT[category],
                local_timestamp(day, random_time(rng, day, real_today, now_seconds)),
                rng.choice(MERCHANTS[category]),
            ))
        rows.sort(key=lambda r: (r["timestamp"], r["kind"], r["wallet"]))
    return rows


def delta(row):
    if row["kind"] in ("income", "transferIn"):
        return row["amount"]
    return -row["amount"]


def calculate_openings(rows):
    # Find the lowest cumulative balance required for each wallet, then add a
    # modest reserve. This guarantees no wallet becomes negative at any point.
    cumulative = [0] * len(WALLETS)
    lowest = [0] * len(WALLETS)
    for row in rows:
        w = row["wallet"]
        cumulative[w] += delta(row)
        lowest[w] = min(lowest[w], cumulative[w])

    openings = []
    for i, wallet in enumerate(WALLETS):
        reserve = 10_000 * 100 if i == 0 else 25_000 * 100
        opening = max(wallet["base"], -lowest[i] + reserve)
        # Round opening balance up to the nearest ₹1,000.
        opening = ((opening + 100_000 - 1) // 100_000) * 100_000
        if opening > MAX_MINOR:
            raise ValueError(
                f"Required opening balance for {wallet['name']} exceeds "
                "the configured Money limit."
            )
        openings.append(opening)
    return openings


def final_balances(rows, openings):
    result = list(openings)
    for row in rows:
        result[row["wallet"]] += delta(row)
    return result


def build_backup(rows, openings, today, seed, now_unix):
    created_unix = local_timestamp(today - dt.timedelta(days=760), 12 * 3600)
    wallets = []
    for i, w in enumerate(WALLETS):
        wallets.append({
            "id": uid(seed, "wallet", i),
            "name": w["name"],
            "emoji": w["emoji"],
            "openingBalanceMinor": openings[i],
            "currencyCode": "INR",
            "createdAt": foundation_timestamp(created_unix + i),
            "isArchived": False,
        })

    categories = []
    for i, (name, emoji, color) in enumerate(CATEGORIES):
        created = created_unix + 100 + i
        categories.append({
            "id": uid(seed, "category", i),
            "name": name,
            "emoji": emoji,
            "colorHex": color,
            "createdAt": foundation_timestamp(created),
            "updatedAt": foundation_timestamp(created),
            "isArchived": False,
        })

    transactions = []
    for i, row in enumerate(rows):
        transactions.append({
            "id": uid(seed, "transaction", i),
            "amountMinor": row["amount"],
            "kindRaw": row["kind"],
            "timestamp": foundation_timestamp(row["timestamp"]),
            "note": row["note"],
            "walletID": uid(seed, "wallet", row["wallet"]),
            "categoryID": (
                None if row["category"] is None
                else uid(seed, "category", row["category"])
            ),
            "transferID": (
                None if row["transfer"] is None
                else uid(seed, "transfer", row["transfer"])
            ),
        })

    return {
        "formatVersion": FORMAT_VERSION,
        "appVersion": "1.0",
        "backupID": uid(seed, "backup", 0),
        "exportedAt": foundation_timestamp(now_unix),
        "wallets": wallets,
        "categories": categories,
        "transactions": transactions,
    }


def validate_backup(file_data, rows, openings):
    errors = []
    wallets = file_data["wallets"]
    categories = file_data["categories"]
    transactions = file_data["transactions"]

    if file_data["formatVersion"] != FORMAT_VERSION:
        errors.append("Unsupported format version.")
    if len(wallets) != 4:
        errors.append("Expected exactly four wallets.")
    if len(categories) < 15 or len(categories) > 20:
        errors.append("Category count is outside 15–20.")
    if not 3000 <= len(transactions) <= 5000:
        errors.append("Transaction count is outside 3,000–5,000.")
    if any(w["currencyCode"] != "INR" for w in wallets):
        errors.append("A non-INR wallet exists.")
    if [w["name"] for w in wallets] != ["Cash", "IOB", "SBI", "Axis Bank"]:
        errors.append("Wallet names/order do not match requirements.")
    all_ids = (
        [x["id"] for x in wallets]
        + [x["id"] for x in categories]
        + [x["id"] for x in transactions]
    )
    if len(all_ids) != len(set(all_ids)):
        errors.append("Duplicate record IDs.")

    wallet_ids = {w["id"] for w in wallets}
    category_ids = {c["id"] for c in categories}
    currency = {w["id"]: w["currencyCode"] for w in wallets}
    balances = {w["id"]: w["openingBalanceMinor"] for w in wallets}
    legs = defaultdict(list)

    for t in transactions:
        if t["kindRaw"] not in KINDS:
            errors.append("Unknown transaction kind.")
            continue
        if t["walletID"] not in wallet_ids:
            errors.append("Transaction references a missing wallet.")
            continue
        if t["categoryID"] is not None and t["categoryID"] not in category_ids:
            errors.append("Transaction references a missing category.")
        if not isinstance(t["amountMinor"], int) or not (1 <= t["amountMinor"] <= MAX_MINOR):
            errors.append("Invalid transaction amount.")
        if len(t["note"]) > 500:
            errors.append("Transaction note exceeds 500 characters.")
        kind = t["kindRaw"]
        if kind in ("expense", "income") and t["transferID"] is not None:
            errors.append("Non-transfer has a transfer ID.")
        if kind in ("transferOut", "transferIn"):
            if t["transferID"] is None or t["categoryID"] is not None:
                errors.append("Invalid transfer fields.")
            else:
                legs[t["transferID"]].append(t)
        change = t["amountMinor"] if kind in ("income", "transferIn") else -t["amountMinor"]
        balances[t["walletID"]] += change
        if abs(balances[t["walletID"]]) > INT64_MAX:
            errors.append("Wallet balance overflow.")

    for transfer_id, pair in legs.items():
        outs = [x for x in pair if x["kindRaw"] == "transferOut"]
        ins = [x for x in pair if x["kindRaw"] == "transferIn"]
        if len(pair) != 2 or len(outs) != 1 or len(ins) != 1:
            errors.append(f"Transfer {transfer_id} does not have exactly two legs.")
            continue
        out, inn = outs[0], ins[0]
        if not (
            out["walletID"] != inn["walletID"]
            and out["amountMinor"] == inn["amountMinor"]
            and out["timestamp"] == inn["timestamp"]
            and out["note"] == inn["note"]
            and currency[out["walletID"]] == currency[inn["walletID"]]
        ):
            errors.append(f"Transfer {transfer_id} is inconsistent.")

    # Independent chronological ledger check, including opening balances.
    chronological = [x["openingBalanceMinor"] for x in wallets]
    for t in transactions:
        wid = wallets_by_id(wallets, t["walletID"])
        i = wid
        change = t["amountMinor"] if t["kindRaw"] in ("income", "transferIn") else -t["amountMinor"]
        chronological[i] += change
        if chronological[i] < 0:
            errors.append(f"Wallet {wallets[i]['name']} becomes negative.")
            break

    if any(w["name"] and "TEST" in w["name"].upper() for w in wallets):
        errors.append("Forbidden TEST text in wallet name.")
    for c in categories:
        if "TEST" in c["name"].upper():
            errors.append("Forbidden TEST text in category name.")
        if not re.fullmatch(r"#[0-9A-Fa-f]{6}", c["colorHex"]):
            errors.append("Invalid category colour.")
    for t in transactions:
        if "TEST" in t["note"].upper():
            errors.append("Forbidden TEST text in transaction note.")

    expected = final_balances(rows, openings)
    actual = [balances[w["id"]] for w in wallets]
    if expected != actual:
        errors.append("Independent wallet balance calculation mismatch.")
    if any(x < 0 for x in actual):
        errors.append("A final wallet balance is negative.")
    return sorted(set(errors))


def wallets_by_id(wallets, wallet_id):
    for index, wallet in enumerate(wallets):
        if wallet["id"] == wallet_id:
            return index
    raise KeyError(wallet_id)


def calculate_period(rows, period):
    start, end = period
    result = {
        "income": 0,
        "expenses": 0,
        "income_count": 0,
        "expense_count": 0,
        "transfer_rows": 0,
        "categories": defaultdict(int),
        "wallet_income": defaultdict(int),
        "wallet_expenses": defaultdict(int),
    }
    for r in rows:
        if not (start <= r["timestamp"] < end):
            continue
        if r["kind"] in ("transferOut", "transferIn"):
            result["transfer_rows"] += 1
        elif r["kind"] == "income":
            result["income"] += r["amount"]
            result["income_count"] += 1
            result["wallet_income"][r["wallet"]] += r["amount"]
        elif r["kind"] == "expense":
            result["expenses"] += r["amount"]
            result["expense_count"] += 1
            result["categories"][r["category"]] += r["amount"]
            result["wallet_expenses"][r["wallet"]] += r["amount"]
    return result


def make_report(rows, backup, openings, today, seed):
    periods = periods_for(today)
    final = final_balances(rows, openings)
    kinds = Counter(r["kind"] for r in rows)
    transfers = kinds["transferOut"]
    first_day = dt.datetime.fromtimestamp(min(r["timestamp"] for r in rows)).date()
    last_day = dt.datetime.fromtimestamp(max(r["timestamp"] for r in rows)).date()

    out = [
        "# ExpenseTracker Indian Finance Dataset — Expected Results",
        "",
        f"- Generated for local date: **{today.isoformat()}**",
        f"- Random seed: `{seed}`",
        "- Currency: **INR only**",
        "- Amount storage: integer paise (`₹1 = 100` minor units)",
        f"- Backup: `{backup}`",
        f"- Local timezone: `{time.strftime('%Z (UTC%z)')}`",
        f"- Transaction date range: {first_day.isoformat()} to {last_day.isoformat()}",
        "",
        "## Dataset summary",
        "",
        f"- Wallets: **{len(WALLETS)}** (Cash, IOB, SBI, Axis Bank)",
        f"- Categories: **{len(CATEGORIES)}**",
        f"- Transaction rows: **{len(rows):,}**",
        f"- Expenses: **{kinds['expense']:,}**",
        f"- Income entries: **{kinds['income']:,}**",
        f"- Transfer pairs: **{transfers:,}** ({kinds['transferOut'] + kinds['transferIn']:,} rows)",
        "- Transfers are excluded from income, expenses and net cash flow.",
        "",
        "## Progress screen expected results",
        "",
    ]

    for label in PERIOD_ORDER:
        p = calculate_period(rows, periods[label])
        net = p["income"] - p["expenses"]
        out.extend([
            f"### {label}",
            "",
            f"- Income: **{money(p['income'])}** ({p['income_count']:,} entries)",
            f"- Expenses: **{money(p['expenses'])}** ({p['expense_count']:,} entries)",
            f"- Net cash flow: **{money(net)}**",
            f"- Transfer rows in period (excluded from totals): {p['transfer_rows']:,}",
            "",
            "**Expense category totals**",
            "",
            "| Category | Transactions amount | Share of expenses |",
            "|---|---:|---:|",
        ])
        for category_index, amount in sorted(
            p["categories"].items(),
            key=lambda item: (-item[1], CATEGORIES[item[0]][0]),
        ):
            share = (amount * 1000 + p["expenses"] // 2) // p["expenses"] if p["expenses"] else 0
            out.append(
                f"| {CATEGORIES[category_index][0]} | {money(amount)} | "
                f"{share // 10}.{share % 10}% |"
            )
        if not p["categories"]:
            out.append("| No expenses | ₹0.00 | 0.0% |")
        out.append("")

    out.extend([
        "## Current wallet balances",
        "",
        "Balances below include opening balances and every transaction, including transfer legs.",
        "",
        "| Wallet | Currency | Opening balance | Expected current balance |",
        "|---|---|---:|---:|",
    ])
    for i, wallet in enumerate(WALLETS):
        out.append(
            f"| {wallet['name']} | INR | {money(openings[i])} | {money(final[i])} |"
        )

    out.extend([
        "",
        "## Transaction counts by wallet",
        "",
        "| Wallet | Expense rows | Income rows | Transfer out | Transfer in |",
        "|---|---:|---:|---:|---:|",
    ])
    for i, wallet in enumerate(WALLETS):
        counts = Counter(r["kind"] for r in rows if r["wallet"] == i)
        out.append(
            f"| {wallet['name']} | {counts['expense']:,} | {counts['income']:,} | "
            f"{counts['transferOut']:,} | {counts['transferIn']:,} |"
        )

    out.extend([
        "",
        "## Category totals across all 24 months",
        "",
        "| Category | Expense rows | Total amount |",
        "|---|---:|---:|",
    ])
    totals = defaultdict(lambda: [0, 0])
    for r in rows:
        if r["kind"] == "expense":
            totals[r["category"]][0] += 1
            totals[r["category"]][1] += r["amount"]
    for category_index, (count, amount) in sorted(
        totals.items(), key=lambda item: (-item[1][1], CATEGORIES[item[0]][0])
    ):
        out.append(f"| {CATEGORIES[category_index][0]} | {count:,} | {money(amount)} |")

    out.extend([
        "",
        "## Validation checks",
        "",
        "- Exactly four wallets; all active; all currency codes are INR.",
        "- 15–20 categories.",
        "- 3,000–5,000 transaction rows.",
        "- Unique UUIDs for wallets, categories and transactions.",
        "- Every transaction references an existing wallet and valid category where applicable.",
        "- Each transfer ID has exactly one transfer-out and one transfer-in row.",
        "- Both transfer legs have identical amount, timestamp and note, and different wallets.",
        "- Transfers are excluded from income and expense totals.",
        "- Opening balances are calculated to prevent negative balances throughout the ledger.",
        "- All wallet balances are calculated in integer paise.",
        "- The report is computed independently from the in-memory transaction ledger.",
        "",
        "## Important restore precaution",
        "",
        "Restoring a backup replaces the app's existing wallets, categories and transactions. "
        "Back up your real app data first and preferably validate this file in the iOS Simulator. "
        "This generator does not restore or import anything on your iPhone.",
        "",
        "## Compatibility note",
        "",
        "The supplied BackupService.swift confirms format version 1, field names, UUID references, "
        "Foundation timestamps and paired-transfer requirements. The app's actual "
        "`Transaction.validate()`, `Money.maxInputMinorUnits`, and default-category definitions "
        "were not included with the supplied source. Confirm those before restoring.",
        "",
    ])
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(
        description="Generate an INR-only Indian personal-finance ExpenseTracker backup."
    )
    parser.add_argument("--seed", type=int, default=20261031)
    parser.add_argument("--today", help="Local date YYYY-MM-DD; defaults to today.")
    parser.add_argument(
        "--out",
        default=str(Path.home() / "Documents" / "ExpenseTracker-Sample-Data"),
    )
    parser.add_argument(
        "--force", action="store_true",
        help="Overwrite only the two exact output files if they already exist.",
    )
    args = parser.parse_args()

    real_today = dt.datetime.now().astimezone().date()
    today = dt.date.fromisoformat(args.today) if args.today else real_today
    if today > real_today:
        sys.exit("--today cannot be in the future.")
    now_unix = int(time.time())
    now_local = dt.datetime.now().astimezone()
    now_seconds = now_local.hour * 3600 + now_local.minute * 60 + now_local.second

    rows = generate_rows(today, real_today, now_seconds, args.seed)
    if not 3000 <= len(rows) <= 5000:
        sys.exit(f"Transaction count outside requested range: {len(rows)}")

    openings = calculate_openings(rows)
    backup = build_backup(rows, openings, today, args.seed, now_unix)
    errors = validate_backup(backup, rows, openings)
    if errors:
        sys.exit("Validation failed:\n- " + "\n- ".join(errors))

    output_dir = Path(args.out).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)
    backup_path = output_dir / "ExpenseTracker-Sample-Backup.json"
    report_path = output_dir / "ExpenseTracker-Sample-Expected-Results.md"

    existing = [p for p in (backup_path, report_path) if p.exists()]
    if existing and not args.force:
        sys.exit(
            "Output file already exists; nothing was overwritten:\n"
            + "\n".join(str(p) for p in existing)
            + "\nChoose another --out directory or pass --force."
        )

    backup_path.write_text(
        json.dumps(backup, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    # Read back and independently revalidate the exact written JSON.
    reread = json.loads(backup_path.read_text(encoding="utf-8"))
    if reread != backup:
        sys.exit("Written JSON did not round-trip identically.")
    errors = validate_backup(reread, rows, openings)
    if errors:
        sys.exit("Written JSON validation failed:\n- " + "\n- ".join(errors))

    report = make_report(rows, backup_path.name, openings, today, args.seed)
    report_path.write_text(report, encoding="utf-8")

    print()
    print("Indian finance backup generated successfully.")
    print(f"Backup:       {backup_path}")
    print(f"Expected:     {report_path}")
    print(f"Wallets:      {len(backup['wallets'])}")
    print(f"Categories:   {len(backup['categories'])}")
    print(f"Transactions: {len(backup['transactions'])}")
    print(f"Expenses:     {sum(r['kind'] == 'expense' for r in rows)}")
    print(f"Income:       {sum(r['kind'] == 'income' for r in rows)}")
    print(f"Transfer pairs: {sum(r['kind'] == 'transferOut' for r in rows)}")
    print("Currencies:   INR only")
    print("Validation:   PASSED")
    print("Existing app data/backups were not accessed or modified.")


if __name__ == "__main__":
    main()
