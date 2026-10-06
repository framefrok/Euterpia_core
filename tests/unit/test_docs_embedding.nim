# tests/unit/test_docs_embedding.nim
#
# Документация встраивания не должна отставать от кода (issue #213).
#
# `docs/embedding.md` — обещание наружу: имена C-ABI, имена nimble-целей и
# имя джоба CI. Обещание, которое никто не сверяет, гниёт: функция из
# документа исчезает из фасада, цель переименовывается, джоб выключается —
# и хост узнаёт об этом только при сборке. Поэтому проверяются ОБЕ стороны
# каждой пары:
#
#   * doc → код: каждый `eutHost*` из документа объявлен в фасаде, каждая
#     упомянутая цель и джоб существуют;
#   * код → doc: каждый `exportc`-символ фасада описан в документе.
#
# Проверка грубая по существу (`document` vs `code`), а не по оформлению:
# требовать таблицу с колонками значило бы запретить править документ.

import std/[unittest, os, strutils, sets, re]

const
  DocsPath = "docs/embedding.md"
    ## Относительно корня репозитория: тесты запускаются из него
    ## (`nimble unit` / `nimble test`).
  FacadePath = "examples/embed_lib.nim"
  NimblePath = "euterpia.nimble"
  CiPath = ".github/workflows/ci.yml"

proc readChecked(path: string): string =
  check fileExists(path)
  readFile(path)

proc exportedSymbols(src: string): HashSet[string] =
  ## Символы фасада: имена процедур, объявленных в `examples/embed_lib.nim`.
  ## У всех них стоит `{.exportc.}`, то есть имя процедуры — и есть имя
  ## символа в таблице экспорта (свой `exportc: "..."` здесь не нужен).
  for line in src.splitLines():
    let s = line.strip()
    if not s.startsWith("proc "):
      continue
    var name = ""
    for ch in s["proc ".len .. ^1]:
      if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}:
        name.add ch
      else:
        break
    if name.startsWith("eutHost") and name.len > "eutHost".len:
      result.incl name

proc documentedSymbols(doc: string): HashSet[string] =
  ## `eutHost*`-имена, упомянутые в документе (в том числе внутри
  ## подписи с аргументами: `` `eutHostCreate(sr, blockSize)` ``).
  for token in doc.findAll(re"eutHost[A-Za-z0-9]+"):
    result.incl token

suite "документация встраивания не отстаёт от кода (#213)":
  test "каждый экспортируемый символ фасада описан в docs/embedding.md":
    # Обратная сторона: символ появился в ABI, но документация о нём молчит —
    # хост не знает, что функция существует и когда её звать.
    let doc = readChecked(DocsPath)
    let code = exportedSymbols(readChecked(FacadePath))
    check code.len >= 8
    let documented = documentedSymbols(doc)
    var missing: seq[string]
    for name in code:
      if name notin documented:
        missing.add name
    check missing.len == 0

  test "документ не обещает символов, которых нет в фасаде":
    # Прямая сторона: `docs/embedding.md` — контракт. Функция в таблице,
    # но не в коде, означает, что хост получит ошибку линковки при первом
    # же вызове.
    let documented = documentedSymbols(readChecked(DocsPath))
    let code = exportedSymbols(readChecked(FacadePath))
    var phantom: seq[string]
    for name in documented:
      if name notin code:
        phantom.add name
    check phantom.len == 0

  test "версия фасада берётся из одного источника с CLI":
    # Док обещает `eutHostVersion() == euterpia --version`. Держится это не
    # на обещании, а на импорте `euterpia_version` — единственного места,
    # где номер версии записан.
    let facade = readChecked(FacadePath)
    let doc = readChecked(DocsPath)
    check "import euterpia_version" in facade
    check "euterpia --version" in doc

  test "nimble-цели из документа объявлены в пакете":
    let doc = readChecked(DocsPath)
    let nimble = readChecked(NimblePath)
    let targets = doc.findAll(re"nimble [A-Za-z][A-Za-z0-9_]*")
    var missing: seq[string]
    for t in targets:
      let name = t["nimble ".len .. ^1]
      if not (("task " & name & ",") in nimble):
        missing.add name
    check missing.len == 0
    check targets.len >= 3   # embedExample, embedLib, archGuard

  test "джоб CI, на который ссылается документ, существует":
    # Таблица «Что | Команда | Джоб CI» в документе — часть контракта:
    # встраивание проверяется в CI, а не «у автора на машине».
    let doc = readChecked(DocsPath)
    let ci = readChecked(CiPath)
    check "`embed`" in doc
    check "\n  embed:\n" in ci
    check "nimble embedExample" in ci
    check "nimble embedLib" in ci

  test "флаги сборки в документе совпадают с фасадом":
    # Флаги — часть контракта встраивания: `--app:lib`/`--app:staticLib`
    # задают и таблицу экспорта, и способ упаковки символов.
    let doc = readChecked(DocsPath)
    let facade = readChecked(FacadePath)
    for flag in ["--app:lib", "--app:staticLib"]:
      check flag in doc
      check flag in facade

  test "контракт владения в документе совпадает с кодом":
    # Кто что освобождает — самая дорогая часть встраивания: ошибка здесь
    # даёт утечку или двойное освобождение у хоста. Документ обязан
    # называть те же функции, что реально вызываются в `eutHostDestroy`.
    let doc = readChecked(DocsPath)
    let facade = readChecked(FacadePath)
    for procName in ["destroyAudioEngine", "destroyNodeState"]:
      check ("`" & procName & "`") in doc
      check procName in facade
