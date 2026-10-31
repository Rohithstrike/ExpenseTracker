#!/usr/bin/env python3
"""Writes a deterministic DUMMY backup file for ExpenseTracker, plus an expected-results report.

Nothing here touches the app or its data. Restore the JSON through Settings > Restore from
backup (which REPLACES all data on that device) only after backing up what is there.

Usage: python3 tools/make_test_backup.py [--seed N] [--today YYYY-MM-DD] [--out DIR] [--force]
Dates are relative to the day you run it, using this Mac's time zone, so generate again on
the day you test. The expected figures use their own integer arithmetic and period logic.
"""
import argparse
import copy
import datetime as dt
import json
import random
import re
import sys
import time
import uuid
from pathlib import Path

REF_OFFSET = 978_307_200          # unix seconds at 2001-01-01 00:00:00 UTC (the app's reference date)
MAX_MINOR = 99_999_999_999        # Money.maxInputMinorUnits
INT64_MAX = 2 ** 63 - 1
TARGET_ROWS = 2_600               # random rows; the special rows come on top
NS = uuid.UUID("8f0c2a54-3d1e-4b7a-9c6e-5a1d2b3c4d5e")
KINDS = ("expense", "income", "transferOut", "transferIn")
PERIOD_ORDER = ["Today", "Yesterday", "This month", "Last month"]

CASH, BANK, SAVINGS, USD, OLD = range(5)
(FOOD, TRAVEL, SHOPPING, RENT, FUEL, HEALTH, ENT, BILLS, EDU,
 SALARY, FREELANCE, OLDHOBBY) = range(12)

WALLETS = [
    dict(name="TEST Cash", emoji="💵", currency="INR", archived=False, base=500_000),
    dict(name="TEST Bank", emoji="🏦", currency="INR", archived=False, base=2_000_000),
    dict(name="TEST Savings", emoji="💰", currency="INR", archived=False, base=5_000_000),
    dict(name="TEST Dollars", emoji="💲", currency="USD", archived=False, base=100_000),
    dict(name="TEST Old Card", emoji="💳", currency="INR", archived=True, base=100_000),
]
CATS = [
    ("Food", "🍔", "#F97316", False), ("Travel", "✈️", "#60A5FA", False),
    ("Shopping", "🛍️", "#EC4899", False), ("Rent", "🏠", "#A78BFA", False),
    ("Fuel", "⛽", "#FBBF24", False), ("Health", "💊", "#34D399", False),
    ("Entertainment", "🎮", "#14B8A6", False), ("Bills", "🧾", "#EF4444", False),
    ("Education", "🎓", "#6366F1", False), ("Salary", "💼", "#84CC16", False),
    ("Freelance", "💻", "#D946EF", False), ("Old Hobby", "🧺", "#94A3B8", True),
]
# category index: (weight, low, high) in whole rupees
EXP = {FOOD: (33, 80, 600), TRAVEL: (12, 50, 1500), SHOPPING: (10, 300, 6000),
       FUEL: (10, 300, 2500), HEALTH: (5, 200, 5000), ENT: (8, 100, 1500),
       BILLS: (12, 200, 3000), EDU: (2, 500, 15000)}
EXP_KEYS = list(EXP)
EXP_W = [EXP[k][0] for k in EXP_KEYS]
# category index: (weight, low, high) in whole dollars
USD_EXP = {FOOD: (30, 5, 40), TRAVEL: (15, 10, 200), SHOPPING: (15, 10, 150),
           ENT: (10, 5, 60), BILLS: (30, 10, 120)}
USD_KEYS = list(USD_EXP)
USD_W = [USD_EXP[k][0] for k in USD_KEYS]
NOTES = {
    FOOD: ["Lunch", "Groceries", "Dinner", "Snacks", "Coffee"],
    TRAVEL: ["Auto fare", "Bus ticket", "Train ticket", "Cab"],
    SHOPPING: ["Clothes", "Household items", "Online order", "Gift"],
    FUEL: ["Petrol", "Full tank"],
    HEALTH: ["Pharmacy", "Doctor visit", "Lab test"],
    ENT: ["Movie", "Streaming", "Game"],
    BILLS: ["Electricity", "Mobile recharge", "Internet", "Water bill"],
    EDU: ["Course fee", "Books"],
    OLDHOBBY: ["Hobby supplies"],
}
MARKERS = {
    "edit": "MARKER-EDIT-AMOUNT", "category": "MARKER-CHANGE-CATEGORY", "date": "MARKER-CHANGE-DATE",
    "delete": "MARKER-DELETE", "income": "MARKER-INCOME", "transfer": "MARKER-TRANSFER",
}


# ---------- small helpers ----------

def uid(seed, kind, n):
    return str(uuid.uuid5(NS, f"{seed}:{kind}:{n}")).upper()


def local_ts(d, secs):
    h, rem = divmod(secs, 3600)
    m, s = divmod(rem, 60)
    return int(time.mktime((d.year, d.month, d.day, h, m, s, 0, 0, -1)))


def row(kind, amount, wallet, cat, ts, note, transfer=None):
    return {"kind": kind, "amount": amount, "wallet": wallet, "cat": cat,
            "ts": ts, "note": note, "transfer": transfer}


def group_indian(s):
    if len(s) <= 3:
        return s
    head, tail = s[:-3], s[-3:]
    parts = []
    while len(head) > 2:
        parts.insert(0, head[-2:])
        head = head[:-2]
    if head:
        parts.insert(0, head)
    return ",".join(parts + [tail])


def fmt(minor, cur):
    sign = "-" if minor < 0 else ""
    whole, frac = divmod(abs(minor), 100)
    if cur == "INR":
        return f"{sign}₹{group_indian(str(whole))}.{frac:02d}"
    if cur == "USD":
        return f"{sign}${whole:,}.{frac:02d}"
    return f"{sign}{cur} {whole:,}.{frac:02d}"


def cat_name(c):
    if c is None:
        return "Uncategorised"
    name, _, _, archived = CATS[c]
    return f"{name} (archived)" if archived else name


def periods_for(today):
    first_this = today.replace(day=1)
    next_first = dt.date(first_this.year + (first_this.month == 12), 1 if first_this.month == 12 else first_this.month + 1, 1)
    last_first = (first_this - dt.timedelta(days=1)).replace(day=1)
    return {
        "Today": (local_ts(today, 0), local_ts(today + dt.timedelta(days=1), 0)),
        "Yesterday": (local_ts(today - dt.timedelta(days=1), 0), local_ts(today, 0)),
        "This month": (local_ts(first_this, 0), local_ts(next_first, 0)),
        "Last month": (local_ts(last_first, 0), local_ts(first_this, 0)),
    }


# ---------- dataset ----------

def build(today, seed, real_today, now_secs):
    rng = random.Random(seed)

    def cap(d):
        return max(0, now_secs - 120) if d == real_today else 86399

    def pick(d):
        c = cap(d)
        return rng.randint(min(7 * 3600, c), min(23 * 3600, c))

    def day_ago(n):
        return today - dt.timedelta(days=n)

    def expense(off):
        d = day_ago(off)
        ts = local_ts(d, pick(d))
        if rng.random() < 0.08:
            cat = rng.choices(USD_KEYS, weights=USD_W)[0]
            lo, hi = USD_EXP[cat][1], USD_EXP[cat][2]
            wallet = USD
            amount = rng.randrange(lo * 4, hi * 4 + 1) * 25
        else:
            wallet = CASH if rng.random() < 0.5 else BANK
            if off > 450 and rng.random() < 0.2:
                wallet = OLD
            if off > 400 and rng.random() < 0.04:
                cat = OLDHOBBY
                amount = rng.randrange(200 * 2, 2500 * 2 + 1) * 50
            else:
                cat = rng.choices(EXP_KEYS, weights=EXP_W)[0]
                lo, hi = EXP[cat][1], EXP[cat][2]
                amount = rng.randrange(lo * 2, hi * 2 + 1) * 50
        note = "" if rng.random() < 0.4 else rng.choice(NOTES[cat])
        return row("expense", amount, wallet, cat, ts, note)

    base = []
    y, m = today.year, today.month
    months = []
    for _ in range(24):
        months.append((y, m))
        m -= 1
        if m == 0:
            m, y = 12, y - 1
    for i, (y, m) in enumerate(months):
        d1 = dt.date(y, m, 1)
        if d1 <= today:
            base.append(row("income", 6_500_000, BANK, SALARY, local_ts(d1, min(8 * 3600, cap(d1))), "Salary"))
        d5 = dt.date(y, m, 5)
        if d5 <= today:
            base.append(row("expense", 1_500_000, BANK, RENT, local_ts(d5, min(10 * 3600, cap(d5))), "Monthly rent"))
        for _ in range(rng.choice([1, 2, 2, 3])):
            d = dt.date(y, m, rng.randint(1, 28))
            amount = rng.randrange(5000, 60001, 500) * 100
            if d <= today:
                base.append(row("income", amount, BANK, FREELANCE, local_ts(d, pick(d)), "Freelance payment"))
        if i % 3 == 0:
            d = dt.date(y, m, rng.randint(1, 28))
            amount = rng.randrange(200, 2501, 50) * 100
            if d <= today:
                base.append(row("income", amount, USD, None, local_ts(d, pick(d)), "Client payment"))

    pool = [CASH, BANK, SAVINGS]
    for k in range(100):
        a = rng.choice(pool)
        b = rng.choice([w for w in pool if w != a])
        off = rng.randrange(0, 61) if rng.random() < 0.3 else rng.randrange(0, 731)
        d = day_ago(off)
        ts = local_ts(d, pick(d))
        amount = rng.randrange(100, 10001, 50) * 100
        note = "" if k % 2 == 0 else f"Transfer {k + 1}"
        base.append(row("transferOut", amount, a, None, ts, note, k))
        base.append(row("transferIn", amount, b, None, ts, note, k))

    daily = []
    for off in range(731):
        for _ in range(rng.choices(range(6), weights=[4, 12, 22, 26, 20, 16])[0]):
            daily.append(expense(off))
    while len(base) + len(daily) > TARGET_ROWS:
        daily.pop(rng.randrange(len(daily)))
    while len(base) + len(daily) < TARGET_ROWS:
        daily.append(expense(rng.randrange(0, 731)))

    special = []
    first_this = today.replace(day=1)
    last_last = first_this - dt.timedelta(days=1)
    first_last = last_last.replace(day=1)
    last_before = first_last - dt.timedelta(days=1)
    special.append(row("expense", 11_100, CASH, FOOD, local_ts(first_this, 0), "BOUNDARY-THIS-MONTH-START"))
    special.append(row("expense", 22_200, CASH, FOOD, local_ts(last_last, 86399), "BOUNDARY-LAST-MONTH-END"))
    special.append(row("expense", 33_300, CASH, FOOD, local_ts(first_last, 0), "BOUNDARY-LAST-MONTH-START"))
    special.append(row("expense", 44_400, CASH, FOOD, local_ts(last_before, 86399), "BOUNDARY-PREVIOUS-MONTH-END"))

    t_now = lambda s: local_ts(today, min(s, cap(today)))
    special.append(row("expense", 100_000, CASH, FOOD, t_now(36_000), MARKERS["edit"]))
    special.append(row("expense", 200_000, BANK, SHOPPING, local_ts(day_ago(1), 43_200), MARKERS["category"]))
    special.append(row("expense", 300_000, CASH, BILLS, local_ts(day_ago(3), 43_200), MARKERS["date"]))
    special.append(row("expense", 50_000, CASH, FUEL, t_now(37_000), MARKERS["delete"]))
    special.append(row("income", 800_000, BANK, FREELANCE, t_now(38_000), MARKERS["income"]))
    ts = t_now(39_000)
    special.append(row("transferOut", 250_000, CASH, None, ts, MARKERS["transfer"], 1000))
    special.append(row("transferIn", 250_000, BANK, None, ts, MARKERS["transfer"], 1000))

    rows = base + daily + special
    rows.sort(key=lambda r: r["ts"])
    return rows


def delta(r):
    return r["amount"] if r["kind"] in ("income", "transferIn") else -r["amount"]


def openings(rows):
    cum = [0] * 5
    low = [0] * 5
    for r in rows:
        cum[r["wallet"]] += delta(r)
        low[r["wallet"]] = min(low[r["wallet"]], cum[r["wallet"]])
    floor = [100_000, 100_000, 100_000, 10_000, 100_000]
    result = []
    for i, w in enumerate(WALLETS):
        opening = max(w["base"], floor[i] - low[i])
        result.append(((opening + 9_999) // 10_000) * 10_000)
    return result


def to_json(rows, opens, today, seed, now_ts):
    created0 = local_ts(today - dt.timedelta(days=760), 0)
    wallets = [{"id": uid(seed, "wallet", i), "name": w["name"], "emoji": w["emoji"],
                "openingBalanceMinor": opens[i], "currencyCode": w["currency"],
                "createdAt": created0 + i - REF_OFFSET, "isArchived": w["archived"]}
               for i, w in enumerate(WALLETS)]
    cats = [{"id": uid(seed, "category", j), "name": n, "emoji": e, "colorHex": h,
             "createdAt": created0 + j - REF_OFFSET, "updatedAt": created0 + j - REF_OFFSET, "isArchived": a}
            for j, (n, e, h, a) in enumerate(CATS)]
    txns = []
    for i, r in enumerate(rows):
        txns.append({
            "id": uid(seed, "txn", i), "amountMinor": r["amount"], "kindRaw": r["kind"],
            "timestamp": r["ts"] - REF_OFFSET, "note": r["note"],
            "walletID": uid(seed, "wallet", r["wallet"]),
            "categoryID": None if r["cat"] is None else uid(seed, "category", r["cat"]),
            "transferID": None if r["transfer"] is None else uid(seed, "transfer", r["transfer"]),
        })
    return {"formatVersion": 1, "appVersion": "1.0", "backupID": uid(seed, "backup", 0),
            "exportedAt": now_ts - REF_OFFSET, "wallets": wallets, "categories": cats, "transactions": txns}


# ---------- validation (mirrors BackupService.validate) ----------

def validate(f):
    errs = []
    w, c, t = f["wallets"], f["categories"], f["transactions"]
    if f["formatVersion"] != 1:
        errs.append("format version")
    if not any(not x["isArchived"] for x in w):
        errs.append("no active wallet")
    for label, items in (("wallet", w), ("category", c), ("transaction", t)):
        ids = [x["id"] for x in items]
        if len(set(ids)) != len(ids):
            errs.append(f"duplicate {label} ids")
    cur, bal = {}, {}
    for x in w:
        ok = bool(x["name"].strip()) and len(x["name"]) <= 200 and len(x["currencyCode"]) == 3 \
            and x["currencyCode"].isascii() and x["currencyCode"].isalpha() \
            and abs(x["openingBalanceMinor"]) <= MAX_MINOR
        if not ok:
            errs.append(f"wallet {x['name']}")
        cur[x["id"]] = x["currencyCode"].upper()
        bal[x["id"]] = x["openingBalanceMinor"]
    for x in c:
        if not x["name"].strip() or len(x["name"]) > 200 or not re.fullmatch(r"#[0-9A-Fa-f]{6}", x["colorHex"]):
            errs.append(f"category {x['name']}")
    cat_ids = {x["id"] for x in c}
    legs = {}
    for x in t:
        k = x["kindRaw"]
        if k not in KINDS:
            errs.append("unknown kind")
            continue
        if x["walletID"] not in cur:
            errs.append("missing wallet")
            continue
        if x["categoryID"] is not None and x["categoryID"] not in cat_ids:
            errs.append("missing category")
        if not (1 <= x["amountMinor"] <= MAX_MINOR) or len(x["note"]) > 500:
            errs.append("amount or note")
        if k in ("expense", "income") and x["transferID"] is not None:
            errs.append("unexpected transfer id")
        if k in ("transferOut", "transferIn"):
            if x["transferID"] is None or x["categoryID"] is not None:
                errs.append("transfer fields")
            else:
                legs.setdefault(x["transferID"], []).append(x)
        d = x["amountMinor"] if k in ("income", "transferIn") else -x["amountMinor"]
        bal[x["walletID"]] += d
        if abs(bal[x["walletID"]]) > INT64_MAX:
            errs.append("balance overflow")
    for tid, group in legs.items():
        outs = [g for g in group if g["kindRaw"] == "transferOut"]
        ins = [g for g in group if g["kindRaw"] == "transferIn"]
        if len(group) != 2 or len(outs) != 1 or len(ins) != 1:
            errs.append(f"transfer {tid} legs")
            continue
        o, i = outs[0], ins[0]
        if not (o["walletID"] != i["walletID"] and o["amountMinor"] == i["amountMinor"]
                and o["timestamp"] == i["timestamp"] and o["note"] == i["note"]
                and cur[o["walletID"]] == cur[i["walletID"]]):
            errs.append(f"transfer {tid} mismatch")
    return errs


# ---------- expected results (independent integer arithmetic) ----------

EMPTY = {"income": 0, "expense": 0, "n_income": 0, "n_expense": 0, "cats": {}}


def compute(rows, periods):
    result = {}
    for pname, (a, b) in periods.items():
        cur_map, transfer_rows = {}, 0
        for r in rows:
            if not (a <= r["ts"] < b):
                continue
            if r["kind"] in ("transferOut", "transferIn"):
                transfer_rows += 1
                continue
            cur = WALLETS[r["wallet"]]["currency"]
            e = cur_map.setdefault(cur, {"income": 0, "expense": 0, "n_income": 0, "n_expense": 0, "cats": {}})
            if r["kind"] == "income":
                e["income"] += r["amount"]
                e["n_income"] += 1
            else:
                e["expense"] += r["amount"]
                e["n_expense"] += 1
                e["cats"][r["cat"]] = e["cats"].get(r["cat"], 0) + r["amount"]
        for e in cur_map.values():
            assert sum(e["cats"].values()) == e["expense"]
        result[pname] = {"cur": cur_map, "transfer_rows": transfer_rows}
    return result


def balances(rows, opens):
    b = list(opens)
    for r in rows:
        b[r["wallet"]] += delta(r)
    return b


def changes(before, after):
    lines = []
    for p in PERIOD_ORDER:
        for cur in sorted(set(before[p]["cur"]) | set(after[p]["cur"])):
            x = before[p]["cur"].get(cur, EMPTY)
            y = after[p]["cur"].get(cur, EMPTY)
            parts = []
            if x["income"] != y["income"]:
                parts.append(f"income {fmt(x['income'], cur)} → {fmt(y['income'], cur)}")
            if x["expense"] != y["expense"]:
                parts.append(f"expenses {fmt(x['expense'], cur)} → {fmt(y['expense'], cur)}")
            if x["income"] - x["expense"] != y["income"] - y["expense"]:
                parts.append(f"net {fmt(x['income'] - x['expense'], cur)} → {fmt(y['income'] - y['expense'], cur)}")
            for c in sorted(set(x["cats"]) | set(y["cats"]), key=lambda k: (k is None, -1 if k is None else k)):
                if x["cats"].get(c, 0) != y["cats"].get(c, 0):
                    parts.append(f"{cat_name(c)} {fmt(x['cats'].get(c, 0), cur)} → {fmt(y['cats'].get(c, 0), cur)}")
            if parts:
                lines.append(f"- **{p}, {cur}:** " + "; ".join(parts))
    return lines or ["- No Progress figure changes."]


def balance_changes(rows_before, rows_after, opens):
    b0, b1 = balances(rows_before, opens), balances(rows_after, opens)
    lines = [f"- {WALLETS[i]['name']}: {fmt(b0[i], WALLETS[i]['currency'])} → {fmt(b1[i], WALLETS[i]['currency'])}"
             for i in range(5) if b0[i] != b1[i]]
    return lines or ["- No wallet balance changes."]


def find(rows, note):
    return next(r for r in rows if r["note"] == note)


def share(amount, total):
    pm = (amount * 1000 + total // 2) // total
    return f"{pm // 10}.{pm % 10}%"


def make_report(rows, opens, today, seed, periods, backup_name):
    comp = compute(rows, periods)
    out = []
    out.append(f"# ExpenseTracker TEST DATA: expected results for {today.isoformat()}")
    out.append("")
    out.append(f"- Backup file: `{backup_name}` (seed {seed}). **Dummy data only.**")
    out.append(f"- Time zone used: {time.strftime('%Z (UTC%z)')}. Your phone must use the same time zone.")
    out.append("- Valid for the day it was generated. If midnight passes, generate again and restore again.")
    out.append("- Amounts use Indian digit grouping for INR. A phone set to another region may group digits differently.")
    out.append("- Percentages here have one decimal. The app shows whole numbers, so allow 1 point of rounding difference.")
    kinds = {k: sum(1 for r in rows if r["kind"] == k) for k in KINDS}
    out.append("")
    out.append("## Dataset")
    out.append(f"- {len(WALLETS)} wallets ({sum(1 for w in WALLETS if not w['archived'])} active, 1 archived, 1 in USD)")
    out.append(f"- {len(CATS)} categories (1 archived)")
    out.append(f"- {len(rows)} transactions: {kinds['expense']} expenses, {kinds['income']} income, "
               f"{kinds['transferOut']} transfers ({kinds['transferOut'] + kinds['transferIn']} rows)")
    first = dt.datetime.fromtimestamp(min(r["ts"] for r in rows)).date()
    out.append(f"- Oldest transaction: {first.isoformat()}; newest: {today.isoformat()}")
    out.append("")
    out.append("## Progress tab (Income, Expenses, Net, categories)")
    out.append("Restore, open Progress, and compare each period. Currency selector appears when a period has INR and USD.")
    for p in PERIOD_ORDER:
        a, b = periods[p]
        out.append("")
        out.append(f"### {p}")
        out.append(f"Transfer rows in this period (must NOT appear in any total): {comp[p]['transfer_rows']}")
        if not comp[p]["cur"]:
            out.append("No income or expenses: the app should show \"No activity\".")
        for cur in sorted(comp[p]["cur"]):
            e = comp[p]["cur"][cur]
            out.append("")
            out.append(f"**{cur}**: income {fmt(e['income'], cur)} ({e['n_income']} entries), "
                       f"expenses {fmt(e['expense'], cur)} ({e['n_expense']} entries), "
                       f"net {fmt(e['income'] - e['expense'], cur)}")
            if e["cats"]:
                out.append("")
                out.append("| Category | Amount | Share |")
                out.append("|---|---|---|")
                order = sorted(e["cats"].items(), key=lambda kv: (-kv[1], cat_name(kv[0])))
                for c, amt in order:
                    out.append(f"| {cat_name(c)} | {fmt(amt, cur)} | {share(amt, e['expense'])} |")
    out.append("")
    out.append("## Wallets tab (current balances after ALL transactions)")
    out.append("| Wallet | Currency | Opening | Expected current |")
    out.append("|---|---|---|---|")
    final = balances(rows, opens)
    for i, w in enumerate(WALLETS):
        out.append(f"| {w['name']}{' (archived)' if w['archived'] else ''} | {w['currency']} | "
                   f"{fmt(opens[i], w['currency'])} | {fmt(final[i], w['currency'])} |")
    out.append("")
    out.append("## Edit and delete checks (marker rows)")
    out.append("Find each row in Transactions by its note. After each action, open Progress and compare.")
    out.append("Do these one at a time, and compare against the changes listed (everything else stays the same).")

    def action(title, after_rows):
        out.append("")
        out.append(f"### {title}")
        out.append("Progress changes:")
        out.extend(changes(comp, compute(after_rows, periods)))
        out.append("Wallet balance changes:")
        out.extend(balance_changes(rows, after_rows, opens))

    a1 = copy.deepcopy(rows)
    find(a1, MARKERS["edit"])["amount"] = 150_000
    action(f"1. Edit `{MARKERS['edit']}`: change the amount from {fmt(100_000, 'INR')} to {fmt(150_000, 'INR')}", a1)
    a2 = copy.deepcopy(rows)
    find(a2, MARKERS["category"])["cat"] = TRAVEL
    action(f"2. Edit `{MARKERS['category']}`: change its category from Shopping to Travel", a2)
    a3 = copy.deepcopy(rows)
    find(a3, MARKERS["date"])["ts"] = local_ts(today, 43_200)
    action(f"3. Edit `{MARKERS['date']}`: change its date to today", a3)
    a4 = [r for r in copy.deepcopy(rows) if r["note"] != MARKERS["delete"]]
    action(f"4. Delete `{MARKERS['delete']}`", a4)
    a5 = [r for r in copy.deepcopy(rows) if r["note"] != MARKERS["transfer"]]
    action(f"5. Delete the transfer `{MARKERS['transfer']}` (swipe either side; both rows must disappear)", a5)
    out.append("")
    out.append(f"Also present, no action needed: `{MARKERS['income']}` (income {fmt(800_000, 'INR')} today in Bank), "
               "and four `BOUNDARY-...` expenses on the first and last second of this month and last month.")
    out.append("They test period edges: START rows belong to their own month, END rows to the month before.")
    out.append("")
    out.append("## Before you restore")
    out.append("1. Back up what is on that device first (Settings > Back up data).")
    out.append("2. Restore replaces ALL data on that device. Try the iPhone Simulator first.")
    out.append("3. After restoring, check the summary the app shows matches the dataset counts above.")
    return "\n".join(out) + "\n"


# ---------- main ----------

def main():
    ap = argparse.ArgumentParser(description="Generate dummy ExpenseTracker backup data")
    ap.add_argument("--seed", type=int, default=20261029)
    ap.add_argument("--today", help="YYYY-MM-DD (default: today)")
    ap.add_argument("--out", default=str(Path.home() / "Documents" / "ExpenseTracker-testdata"))
    ap.add_argument("--force", action="store_true", help="overwrite existing output files")
    args = ap.parse_args()

    real_today = dt.date.today()
    today = dt.date.fromisoformat(args.today) if args.today else real_today
    now = dt.datetime.now()
    now_secs = now.hour * 3600 + now.minute * 60 + now.second
    now_ts = int(time.time())

    rows = build(today, args.seed, real_today, now_secs)
    opens = openings(rows)
    data = to_json(rows, opens, today, args.seed, now_ts)
    errs = validate(data)
    if errs:
        sys.exit("Generated data failed validation: " + "; ".join(sorted(set(errs))))
    if min(balances(rows, opens)) < 0:
        sys.exit("A wallet balance is negative")

    outdir = Path(args.out).expanduser()
    outdir.mkdir(parents=True, exist_ok=True)
    backup_path = outdir / f"TEST-backup-{today.isoformat()}.json"
    report_path = outdir / f"TEST-expected-{today.isoformat()}.md"
    if (backup_path.exists() or report_path.exists()) and not args.force:
        sys.exit(f"Output already exists in {outdir}. Use --force to overwrite.")

    backup_path.write_text(json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
    again = json.loads(backup_path.read_text(encoding="utf-8"))
    errs = validate(again)
    if errs or again != data:
        sys.exit("Written file did not read back identically or failed validation")
    report_path.write_text(make_report(rows, opens, today, args.seed, periods_for(today), backup_path.name), encoding="utf-8")

    print(f"Backup:  {backup_path}")
    print(f"Report:  {report_path}")
    print(f"Wallets {len(data['wallets'])}, categories {len(data['categories'])}, transactions {len(data['transactions'])}")
    print("Validation passed (written file re-read and checked).")


if __name__ == "__main__":
    main()
