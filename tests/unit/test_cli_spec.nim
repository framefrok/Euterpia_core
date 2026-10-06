# tests/unit/test_cli_spec.nim
#
# Unit-тесты описания команд (`libs/cli_spec`, issue #330).
#
# Здесь проверяется то, что нельзя проверить запуском бинаря: поведение
# проверки спецификации на ЗАВЕДОМО ИСПОРЧЕННОМ описании. Критерий приёмки
# #330 сформулирован именно так — «искусственно испорченная спецификация
# роняет CI, а не проходит молча»: если линтер описаний ничего не ловит, он
# бесполезен, и это надо доказать, а не предположить.

import std/[unittest, strutils, json]

import cli_spec

proc demoSpec(): CommandSpec =
  ## Полное описание: у каждой проверки есть что проверять.
  CommandSpec(
    name: "demo",
    summary: "демонстрационная команда",
    synopsis: "demo [--count число]",
    args: @[arg("файл", "что обработать")],
    subcommands: @["run", "plan"],
    options: @[
      opt("--count", "сколько раз повторить", value = "число", default = "1"),
      switch("--force", "перезаписать результат"),
    ],
    example: "euterpia demo --count 2",
    fields: @[field("count", "сколько раз сделано")],
    notes: @["пример строки справки"])

suite "cli_spec: описание команды как данные (#330)":
  test "полное описание не даёт замечаний":
    check validateSpecs(@[demoSpec()]).len == 0

  test "замечания называют команду и причину":
    var broken = demoSpec()
    broken.example = "euterpia other --count 2"
    broken.synopsis = "demo [--count число] [--undeclared]"
    broken.options[1].default = "on"        # у флага не бывает умолчания
    broken.options.add(opt("--count", "", value = "число"))
    broken.fields[0].summary = ""
    let checked = validateSpecs(@[broken])
    let text = checked.join("\n")
    check "пример должен начинаться" in text
    check "synopsis упоминает незаявленный ключ --undeclared" in text
    check "у флага --force не может быть умолчания" in text
    check "ключ --count объявлен дважды" in text
    check "поле --json count без имени или описания" in text
    check "у ключа --count нет описания" in text
    # Каждое замечание начинается с имени команды: в отчёте CI видно, кого
    # именно править, а не только «что-то не так».
    for problem in checked:
      if problem.startsWith("команда без имени"):
        continue
      check problem.startsWith("demo:")

  test "команда без имени, синопсиса и примера тоже ловится":
    let empty = CommandSpec(summary: "без имени")
    let problems = validateSpecs(@[empty])
    check problems.len >= 3
    check "команда без имени" in problems
    check "нет synopsis" in problems.join("\n")
    check "нет примера вызова" in problems.join("\n")

  test "скрытая команда не обязана иметь пример, но остальное — обязана":
    var hidden = demoSpec()
    hidden.hidden = true
    hidden.example = ""
    check validateSpecs(@[hidden]).len == 0
    hidden.synopsis = ""
    check validateSpecs(@[hidden]).len == 1

  test "ключи команды берутся из спецификации, а не из копии":
    let spec = demoSpec()
    check spec.optionKeys() == @["--count", "--force"]
    # Алиасы входят в список ключей: разбор, подсказка и дополнение читают
    # один список, поэтому второй формы ключа не бывает «забытой».
    let aliased = CommandSpec(
      name: "demo",
      summary: "с алиасом",
      synopsis: "demo",
      options: @[opt("--sr", "частота", value = "Гц",
                     aliases = @["--sample-rate"])],
      example: "euterpia demo")
    check aliased.optionKeys() == @["--sr", "--sample-rate"]

suite "cli_spec: представления одного описания (#330)":
  test "справка, машинная схема и Markdown описывают одно и то же":
    let specs = @[demoSpec()]
    let human = helpLines(specs, "euterpia", "1.2.3").join("\n")
    check "euterpia 1.2.3" in human
    check "демонстрационная команда" in human
    check "demo [--count число]" in human

    let one = commandHelpLines(demoSpec(), "euterpia").join("\n")
    check "Использование: euterpia demo [--count число]" in one
    check "--count <число>" in one
    check "умолчание: 1" in one
    check "euterpia demo --count 2" in one
    check "run | plan" in one

    let machine = specJson(demoSpec())
    check machine["name"].getStr == "demo"
    check machine["options"][0]["kind"].getStr == "value"
    check machine["options"][0]["default"].getStr == "1"
    check machine["options"][1]["kind"].getStr == "switch"
    check machine["fields"][0]["name"].getStr == "count"
    var flags: seq[string] = @[]
    for flag in machine["flags"]:
      flags.add flag.getStr
    check flags == @["--count", "--force"]

    let markdown = markdownReference(specs, "euterpia")
    check "### `demo` — демонстрационная команда" in markdown
    check "| `--count` | число | 1 | сколько раз повторить |" in markdown
    check "euterpia demo --count 2" in markdown

  test "кандидаты автодополнения берутся из того же описания":
    let specs = @[demoSpec(), CommandSpec(name: "other", summary: "другая",
                                          synopsis: "other",
                                          example: "euterpia other")]
    check completionCandidates(specs, "", "de") == @["demo"]
    check completionCandidates(specs, "demo", "") == @["--count", "--force",
                                                      "run", "plan"]
    # Префикс «--» отбирает длинные формы: `-v` и `-q` в него не попадают.
    check completionCandidates(specs, "other", "--") == @["--json", "--human",
      "--verbose", "--quiet", "--dry-run", "--help", "--version"]

  test "раздел вставляется только между маркерами":
    let doc = "начало\n" & ReferenceBegin & "\nстарое\n" & ReferenceEnd &
      "\nхвост\n"
    check hasReferenceMarkers(doc)
    let updated = spliceReference(doc, "новое\n")
    check updated == "начало\n" & ReferenceBegin & "\nновое\n" & ReferenceEnd &
      "\nхвост\n"
    # Документ без маркеров не переписывается: дописать раздел «в конец»
    # значило бы получить два справочника.
    check not hasReferenceMarkers("просто текст\n")
    check spliceReference("просто текст\n", "новое\n") == "просто текст\n"
