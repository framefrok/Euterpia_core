# tests/unit/test_docs_instruments.nim
#
# Документация нод не должна отставать от реестра (issue #309).
#
# История: после PR #303 инструментов стало 14, а README по-прежнему
# называл 6, и в списке идентификаторов не было половины DSP-нод. Никто
# этого не заметил — документацию никто не сверял с кодом. Теперь
# сверяется машинно: каждый зарегистрированный тип и каждый его параметр
# должны встречаться в `docs/libs/compose/instruments.md`.
#
# Проверка грубая по существу, а не по оформлению: ищем имя в тексте.
# Требовать таблицу для каждого параметра значит запретить добавлять
# ноды — а добавлять их нужно.

import std/[unittest, os, strutils]

import sdk/node_api
import sdk/node_registry
import builtin/builtin_registry

const
  DocPath = "docs/libs/compose/instruments.md"
    ## Относительно корня репозитория: тесты запускаются из него
    ## (`nimble unit` / `nimble test`).

proc readDocs(): string =
  check fileExists(DocPath)
  readFile(DocPath)

proc documented(doc, name: string): bool =
  ## Упомянут ли термин в документе.
  ##
  ## Принимаются обе формы: полная (`euterpia.organ`) и короткая (`organ`) —
  ## README использует короткие, справочник полные. Поиск идёт в обратных
  ## кавычках, иначе `pan` совпал бы с любым словом, где есть эти буквы.
  let short =
    if name.startsWith("euterpia."): name["euterpia.".len .. ^1]
    else: name
  doc.find("`" & name & "`") >= 0 or doc.find("`" & short & "`") >= 0

suite "документация нод не отстаёт от реестра (#309)":
  test "каждый зарегистрированный тип описан":
    let doc = readDocs()
    var reg = initNodeRegistry()
    discard registerBuiltinNodes(reg)
    var missing: seq[string]
    for entry in reg:
      let id = readFixed(entry.desc.id)
      if not documented(doc, id):
        missing.add id
    check missing.len == 0

  test "каждый параметр типа описан":
    let doc = readDocs()
    var reg = initNodeRegistry()
    discard registerBuiltinNodes(reg)
    var missing: seq[string]
    for entry in reg:
      let id = readFixed(entry.desc.id)
      let d = entry.desc
      for k in 0 ..< int(d.paramCount):
        let pname = readFixed(d.params[k].name)
        if not documented(doc, pname):
          missing.add id & "." & pname
    check missing.len == 0

  test "в реестре 25 типов: 10 DSP, 14 инструментов, notes":
    var reg = initNodeRegistry()
    discard registerBuiltinNodes(reg)
    check reg.count() == 25

  test "README называет все инструменты, а не шесть":
    # Ровно та ошибка, ради которой тест и написан: в строке «Статус»
    # перечислялось 6 инструментов из 14. README использует короткие имена
    # (`organ`), справочник — полные (`euterpia.organ`), поэтому проверка
    # принимает обе формы — тем же `documented`, что и выше.
    let readme = readFile("README.md")
    var reg = initNodeRegistry()
    discard registerBuiltinNodes(reg)
    var missing: seq[string]
    for entry in reg:
      if nodeCategoryOf(entry.desc[]) != "instrument":
        continue
      if not documented(readme, readFixed(entry.desc.id)):
        missing.add readFixed(entry.desc.id)
    check missing.len == 0