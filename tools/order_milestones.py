#!/usr/bin/env python3
# tools/order_milestones.py
#
# Наводит порядок в списке milestones (MANIFEST §105).
#
# GitHub по умолчанию сортирует milestones по due date; без дат порядок
# произвольный (по созданию), поэтому подверсии шли вперемешку. Скрипт задаёт
# due_on в ЛОГИЧЕСКОЙ последовательности: сначала линия (v0.3 → v0.4 → …),
# внутри линии — шаг (.1 → .2 → …). Даты — ориентир для порядка, не дедлайн.
#
# По умолчанию — сухой прогон. Запись: --apply.

import datetime as dt
import json
import re
import subprocess
import sys

REPO = "framefrok/Euterpia_core"
START = dt.date(2026, 10, 20)   # ближайшая точка отсчёта
STEP_DAYS = 21                  # шаг между подверсиями
SUB_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)")


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def milestones():
    out = sh(["gh", "api", "--paginate",
              f"repos/{REPO}/milestones?state=all&per_page=100"]).stdout
    dec, idx, items = json.JSONDecoder(), 0, []
    s = out.strip()
    while idx < len(s):
        obj, end = dec.raw_decode(s, idx)
        items.extend(obj)
        idx = end
        while idx < len(s) and s[idx] in " \n\r\t":
            idx += 1
    return items


def key(title):
    m = SUB_RE.match(title)
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)))


def main():
    apply = "--apply" in sys.argv
    subs = [(key(m["title"]), m["title"], m["number"])
            for m in milestones() if key(m["title"])]
    subs.sort()
    for i, (_, title, num) in enumerate(subs):
        due = START + dt.timedelta(days=STEP_DAYS * i)
        print(f"{due}  {title}")
        if apply:
            r = sh(["gh", "api", f"repos/{REPO}/milestones/{num}", "-X", "PATCH",
                    "-f", f"due_on={due.isoformat()}T00:00:00Z"])
            if r.returncode != 0:
                print("  error:", r.stderr.strip())
    if not apply:
        print("\n(сухой прогон; для записи — --apply)")


if __name__ == "__main__":
    main()
