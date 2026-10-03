#!/usr/bin/env python3
# tools/reassign_milestones.py
#
# Миграция Issues на подверсии (MANIFEST §105, docs/versions.md §5).
#
# Правило шага: architecture или bug P0/P1 → .2; docs/chore или ci без feature
# → .1; иначе по приоритету p1→.3, p2→.4, p3→.5.
#
# Линия берётся из текущего milestone (v0.3…v0.7). Неразмеченные Issues
# получают линию из карты LINE_OF (по смыслу).
#
# По умолчанию — сухой прогон. Запись: --apply.

import json
import subprocess
import sys
from collections import defaultdict

REPO = "framefrok/Euterpia_core"

STEP_TITLE = {
    1: "Организация и документация",
    2: "Критическое и архитектурное",
    3: "Функциональность P1",
    4: "Функциональность P2",
    5: "Функциональность P3 и полировка",
}

# Линия для неразмеченных Issues (по смыслу; см. docs/versions.md §7-8).
LINE_OF = {
    # гибкость ядра (фундамент GUI)
    272: "v0.4", 273: "v0.4", 276: "v0.4", 277: "v0.4", 278: "v0.4",
    279: "v0.4", 282: "v0.4", 283: "v0.4", 284: "v0.4",
    # GUI повседневная работа
    280: "v0.6", 281: "v0.6",
    # глубина: инструменты, музыка, помощник
    274: "v0.7", 275: "v0.7", 285: "v0.7", 286: "v0.7", 287: "v0.7",
    288: "v0.7", 290: "v0.7", 293: "v0.7", 294: "v0.7", 295: "v0.7",
    # баг CLI/Core ядра
    292: "v0.3",
}


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def issues():
    out = sh(["gh", "issue", "list", "--state", "open", "--limit", "500",
              "--json", "number,title,labels,milestone", "-R", REPO]).stdout
    return json.loads(out)


def milestones():
    out = sh(["gh", "api", "--paginate",
              f"repos/{REPO}/milestones?state=all&per_page=100"]).stdout
    # склейка нескольких страниц JSON-массивов
    dec = json.JSONDecoder()
    idx, items = 0, []
    s = out.strip()
    while idx < len(s):
        obj, end = dec.raw_decode(s, idx)
        items.extend(obj)
        idx = end
        while idx < len(s) and s[idx] in " \n\r\t":
            idx += 1
    return items


def step_of(labels):
    s = set(labels)
    if "architecture" in s:
        return 2
    if "bug" in s and ("p0" in s or "p1" in s):
        return 2
    if "docs" in s or "chore" in s:
        return 1
    if "ci" in s and "feature" not in s:
        return 1
    if "p1" in s:
        return 3
    if "p2" in s:
        return 4
    return 5


def line_of(issue):
    ms = issue.get("milestone")
    if ms:
        title = ms.get("title", "") if isinstance(ms, dict) else str(ms)
        if title[:4] in ("v0.3", "v0.4", "v0.5", "v0.6", "v0.7"):
            return title[:4]
    return LINE_OF.get(issue["number"])


def main():
    apply = "--apply" in sys.argv
    ms = {m["title"]: m["number"] for m in milestones()}
    plan = []
    need = defaultdict(int)
    for it in issues():
        line = line_of(it)
        if not line:
            continue
        step = step_of([l["name"] if isinstance(l, dict) else l
                        for l in it["labels"]])
        title = f"{line}.{step} — {STEP_TITLE[step]}"
        cur = (it.get("milestone") or {}).get("title")
        plan.append((it["number"], it["title"], cur, title))
        need[title] += 1

    print("=== план подверсий ===")
    for t, n in sorted(need.items()):
        print(f"{n:3d}  {t}")
    print(f"\nвсего: {len(plan)} открытых Issues")

    if not apply:
        print("\n(сухой прогон; для записи — --apply)")
        return

    for t in need:
        if t in ms:
            continue
        r = sh(["gh", "api", f"repos/{REPO}/milestones", "-f", f"title={t}",
                "-f", "description=Подверсия (MANIFEST §105, docs/versions.md)"])
        if r.returncode != 0:
            print("milestone error:", t, r.stderr.strip())
        else:
            ms[t] = json.loads(r.stdout)["number"]
            print("created:", t)

    for num, title, cur, t in plan:
        if cur == t:
            continue
        r = sh(["gh", "api", f"repos/{REPO}/issues/{num}", "-X", "PATCH",
                "-F", f"milestone={ms[t]}"])
        if r.returncode != 0:
            print("issue error:", num, r.stderr.strip())
    print("готово")


if __name__ == "__main__":
    main()
