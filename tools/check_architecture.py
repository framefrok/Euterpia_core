#!/usr/bin/env python3
"""Guard направления зависимостей слоёв EUTERPIA (issue #50, MANIFEST §27).

Правило §27 до этого держалось на честном слове: шаг CI ловил только
CLI-протечки подстрокой `cli/`, а `import adapters/...` в Core — точечным
grep'ом на три имени адаптера. Перечень имён рано или поздно отстаёт от
дерева, поэтому запрет здесь формулируется не списком библиотек, а по СЛОЮ:
что нельзя импортировать, вычисляется из фактического состава папок.

Закон направлений (MANIFEST §19-21, §27):

    Commons ─X→ Core
    Commons ─X→ Nodes
    Commons ─X→ CLI / Editor

    Core    ─X→ Nodes
    Core    ─X→ CLI / Editor
    Core    ─X→ adapters

    Nodes   ─X→ CLI / Editor
    Nodes   ─X→ adapters
    Nodes   ─X→ GUI (точки входа `editor`/`main`)

    Core/Nodes/Commons ─X→ GUI (этим держится встраивание ядра, §6, #213)

Разрешено обратное: `adapters → Core`, `Nodes → Core`, `Core/Nodes → Commons`,
`CLI/Editor → всё публичное`.

Сопоставляются ТОЛЬКО строки `import` / `include` / `from`: подстрока в
докстроке или комментарии зависимостью не является. Это принципиально —
`core/audio_backend_api.nim` по §8 легитимно перечисляет бэкенды в прозе, а
`core/*_api.nim` упоминают `adapters/` в комментариях.

Запуск:
    python3 tools/check_architecture.py     # напрямую
    nimble archGuard                        # то же через nimble-цель

Код возврата: 0 — нарушений нет, 1 — есть (нарушения печатаются списком, а в
GitHub Actions — ещё и аннотациями `::error`).
"""

from __future__ import annotations

import os
import re
import sys

# Корень репозитория: скрипт лежит в tools/, значит, на уровень выше.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Начало инструкции импорта; `from X import a, b` покрывается тем же шаблоном.
IMPORT_RE = re.compile(r"^\s*(import|include|from)\b(.*)$")

# Имя модуля Nim: путь вида `adapters/clap/clap_host` либо плоское `clap_host`.
MODULE_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_./\\]*")

# Слова, которые шаблон MODULE_RE выхватит, но модулями слоя не являются.
NOT_A_MODULE = frozenset({"import", "include", "from", "std", "pkg", "system"})

# GUI-слой (§6, #213). В отличие от core/nodes/commons это не папка, а
# корневые точки входа: `editor.nim` (будущий редактор) и `main.nim`
# (композитный запуск). Перечень задан явно — вычислять его из состава
# корня нельзя, там лежат и `cli.nim`, и `euterpia_version.nim`.
#
# Почему правило отдельное: импорт `editor`/`main` из ядра — это не просто
# «не туда посмотрели», а конец встраивания. Ядро, дёрнувшее GUI, перестаёт
# собираться как библиотека в чужом процессе (#213) и требует редактора там,
# где его нет (§6, §66). Префикс `editor/` ждёт папку, когда она появится.
GUI_MODULES = frozenset({"editor", "main"})
GUI_PREFIXES = ("editor/",)


def strip_comment(line: str) -> str:
    """Отбрасывает комментарий. В import-выражениях строковых литералов нет,
    поэтому первый `#` всегда начинает комментарий, а не часть имени."""
    return line.split("#", 1)[0]


def modules_in(text: str) -> set[str]:
    """Имена модулей из фрагмента import-выражения.

    Развёрнут групповой синтаксис `import std/[os, strutils]`: содержимое
    скобок превращается в отдельные модули (`os`, `strutils`).
    """
    mods: set[str] = set()
    for group in re.findall(r"\[([^\]]*)\]", text):
        for part in group.split(","):
            part = part.strip()
            if part:
                mods.add(part)
    text = re.sub(r"\[[^\]]*\]", " ", text)
    for token in MODULE_RE.findall(text):
        if token not in NOT_A_MODULE:
            mods.add(token)
    return mods


def continues(code: str, rest: str) -> bool:
    """Продолжается ли инструкция импорта на следующей строке.

    Nim знает три формы переноса: пустой хвост после ключевого слова
    (`import` своей строкой, имена — ниже), запятая в конце строки и
    ключевое слово `import` в конце `from`-выражения.
    """
    stripped = code.rstrip()
    tokens = rest.split()
    return (
        not tokens
        or stripped.endswith(",")
        or tokens[-1] == "import"
    )


def collect_imports(path: str) -> set[str]:
    """Модули, импортируемые файлом (только строки import/include/from).

    Многострочное выражение (`import` на своей строке, имена — на следующих,
    с отступом и с запятой в конце) продолжается, пока этого требует
    `continues`.
    """
    imports: set[str] = set()
    continued = False
    with open(path, encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            code = strip_comment(raw.rstrip("\n"))
            if not code.strip():
                continued = False
                continue
            match = IMPORT_RE.match(code)
            if match:
                rest = match.group(2)
                imports |= modules_in(rest)
                continued = continues(code, rest)
                continue
            if continued and code[:1] in (" ", "\t"):
                imports |= modules_in(code)
                continued = code.rstrip().endswith(",")
                continue
            continued = False
    return imports


def nim_modules(subdir: str) -> set[str]:
    """Базовые имена всех `.nim`-модулей слоя, без расширения."""
    names: set[str] = set()
    for _dirpath, _dirs, files in os.walk(os.path.join(ROOT, subdir)):
        for name in files:
            if name.endswith(".nim"):
                names.add(name[:-4])
    return names


def basename(module: str) -> str:
    """Последний компонент пути модуля: `std/strutils` -> `strutils`."""
    return module.replace("\\", "/").rsplit("/", 1)[-1]


def build_rules() -> list[tuple[str, frozenset[str], tuple[str, ...], str]]:
    """Правила: (папка слоя, запретные имена, запретные префиксы, ярлык).

    Префикс пути ловит импорт с подкаталогом (`adapters/clap/...`), базовое
    имя — плоский импорт (`clap_host`). Для CLI/Editor сопоставляется ТОЛЬКО
    путь: их модули носят общеупотребительные имена (`main`, `config`), и
    совпадение базового имени дало бы ложные срабатывания. Более широкую
    проверку `cli/` по подстроке по-прежнему делает шаг CI «Core не знает о
    CLI» (#88).
    """
    adapters = frozenset(nim_modules("adapters"))
    core = frozenset(nim_modules("core"))
    nodes = frozenset(nim_modules("nodes"))
    return [
        ("core", adapters, ("adapters/",), "core ─X→ adapters"),
        ("core", nodes, ("nodes/",), "core ─X→ nodes"),
        ("nodes", adapters, ("adapters/",), "nodes ─X→ adapters"),
        ("commons", core, ("core/",), "commons ─X→ core"),
        ("commons", nodes, ("nodes/",), "commons ─X→ nodes"),
        ("core", frozenset(), ("cli/", "editor/"), "core ─X→ cli/editor"),
        ("nodes", frozenset(), ("cli/", "editor/"), "nodes ─X→ cli/editor"),
        ("commons", frozenset(), ("cli/", "editor/"), "commons ─X→ cli/editor"),
        # GUI (§6, #213): проверяются и плоские имена точек входа
        # (`import editor`, `import main`), и будущая папка `editor/`.
        ("core", GUI_MODULES, GUI_PREFIXES, "core ─X→ gui"),
        ("nodes", GUI_MODULES, GUI_PREFIXES, "nodes ─X→ gui"),
        ("commons", GUI_MODULES, GUI_PREFIXES, "commons ─X→ gui"),
    ]


def scan(
    subdir: str,
    forbidden: frozenset[str],
    prefixes: tuple[str, ...],
    label: str,
) -> list[tuple[str, str, str]]:
    """Нарушения одного правила: (путь к файлу, импорт, ярлык)."""
    found: list[tuple[str, str, str]] = []
    for dirpath, _dirs, files in os.walk(os.path.join(ROOT, subdir)):
        for name in sorted(files):
            if not name.endswith(".nim"):
                continue
            path = os.path.join(dirpath, name)
            for module in sorted(collect_imports(path)):
                norm = module.replace("\\", "/")
                if basename(norm) in forbidden or norm.startswith(prefixes):
                    found.append((os.path.relpath(path, ROOT), module, label))
    return found


def report(violations: list[tuple[str, str, str]]) -> int:
    """Печатает результат и возвращает код возврата процесса."""
    if not violations:
        print("ok: направление зависимостей слоёв соблюдено (MANIFEST §27)")
        return 0
    github = os.environ.get("GITHUB_ACTIONS") == "true"
    for rel, module, label in violations:
        message = f"{label}: {rel} импортирует «{module}» (запрещено MANIFEST §27)"
        if github:
            print(f"::error file={rel}::{message}")
        else:
            print(f"ERROR: {message}")
    print(f"нарушений направления зависимостей: {len(violations)}")
    return 1


def main() -> int:
    violations: list[tuple[str, str, str]] = []
    for subdir, forbidden, prefixes, label in build_rules():
        violations += scan(subdir, forbidden, prefixes, label)
    return report(violations)


if __name__ == "__main__":
    sys.exit(main())

