# tests/cli_test.nim
#
# Smoke-тест CLI (issues #88, #105, #259).
#
# Тест ЧЁРНЫЙ: он запускает собранный бинарь `build/euterpia` и проверяет
# наблюдаемое поведение — коды возврата, разделение stdout/stderr и
# машинный формат. Так и должно быть: критерии приёмки #88 сформулированы
# в терминах запуска процесса («euterpia nonsense → код 1»), а не в
# терминах внутренних функций, поэтому тест на внутренностях ничего бы не
# доказал.
#
# stdout и stderr читаются по отдельности: одно из требований — при
# `--json` в stdout не должно попадать ничего, кроме JSON-конверта.
#
# Путь к бинарю: `build/euterpia` (или `EUTERPIA_CLI` в окружении).
# Запуск: nimble cliSmoke (собирает CLI, затем этот тест).

import std/[unittest, os, osproc, strutils, json, streams]
import euterpia_version

const
  DefaultCliPath =
    when defined(windows): "build/euterpia.exe"
    else: "build/euterpia"

type
  RunResult* = object
    output*, errput*: string
    code*: int

let cliPath =
  block:
    let fromEnv = getEnv("EUTERPIA_CLI")
    if fromEnv.len > 0: fromEnv else: DefaultCliPath

proc runCli(args: openArray[string]): RunResult =
  let process = startProcess(cliPath, args = @args, options = {})
  result.output = process.outputStream.readAll()
  result.errput = process.errorStream.readAll()
  discard process.waitForExit()
  result.code = process.peekExitCode()
  process.close()

proc nonEmptyLines(text: string): seq[string] =
  for line in text.splitLines():
    if line.len > 0:
      result.add line

proc stripComments(script: string): string =
  ## Комментарии с инструкцией по установке упоминают команду `completion`
  ## (это подсказка человеку, а не список кандидатов), поэтому проверяется
  ## именно КОД скрипта.
  for line in script.splitLines():
    if line.strip().startsWith("#"):
      continue
    result.add line
    result.add "\n"

proc machineCommandNames(): seq[string] =
  ## Список команд из машинной справки — эталон для сверок.
  let r = runCli(["help", "--json"])
  check r.code == 0
  let node = parseJson(r.output)
  for item in node["commands"]:
    result.add item["name"].getStr

suite "CLI: контракт точки входа (#88)":
  test "бинарь собран":
    check fileExists(cliPath)

  test "--help перечисляет команды, печатает в stdout и завершается 0":
    let r = runCli(["--help"])
    check r.code == 0
    check r.errput.len == 0
    for name in ["completion", "doctor", "help", "version"]:
      check name in r.output
    check "Коды возврата" in r.output

  test "запуск без аргументов отвечает справкой (это ответ, а не ошибка)":
    let r = runCli([])
    check r.code == 0
    check "Использование" in r.output

  test "--version печатает версию, совпадающую с версией пакета":
    let r = runCli(["--version"])
    check r.code == 0
    check r.output.strip() == "euterpia " & EuterpiaVersion

    # Вторая половина критерия #88 — «версия из euterpia.nimble». nimble
    # берёт её из того же модуля, поэтому сверяемся с ним напрямую.
    let nimble = findExe("nimble")
    if nimble.len == 0:
      echo "SKIP: nimble не найден в PATH — сверка с пакетом пропущена"
    else:
      let dump = execCmdEx(quoteShell(nimble) & " dump")
      check dump.exitCode == 0
      var packageVersion = ""
      for line in dump.output.splitLines():
        let trimmed = line.strip()
        if trimmed.startsWith("version:"):
          packageVersion = trimmed.split(':', 1)[1].strip().strip(chars = {'"'})
      check packageVersion == EuterpiaVersion

  test "неизвестная команда: код 1, сообщение в stderr":
    let r = runCli(["nonsense"])
    check r.code == 1
    check r.output.len == 0
    check "nonsense" in r.errput
    check "euterpia" in r.errput

  test "неизвестный глобальный ключ до команды: код 1":
    let r = runCli(["--nope", "version"])
    check r.code == 1
    check "--nope" in r.errput

  test "лишние аргументы команды — ошибка данных (код 1), а не среды":
    let r = runCli(["doctor", "extra"])
    check r.code == 1
    check parseJson(runCli(["--json", "doctor", "extra"]).output)["exitCode"].getInt == 1

  test "--json: ошибка машиночитаема, лишнего в stdout нет":
    let r = runCli(["--json", "nonsense"])
    check r.code == 1
    check r.errput.len == 0
    check r.output.count('\n') == 1
    let node = parseJson(r.output)
    check node["schema"].getInt == 1
    check node["ok"].getBool == false
    check node["command"].getStr == "nonsense"
    check node["exitCode"].getInt == 1
    check node["error"]["kind"].getStr == "usage"

  test "глобальные ключи работают и до, и после имени команды (MANIFEST §21)":
    let before = runCli(["--json", "version"])
    let after = runCli(["version", "--json"])
    check before.code == 0
    check before.output == after.output

  test "вывод детерминирован: повторный запуск байт-в-байт":
    for args in [@["--help"], @["help", "--json"], @["version", "--json"],
                 @["completion", "bash"], @["doctor", "--dry-run"]]:
      let first = runCli(args)
      let second = runCli(args)
      check first.code == second.code
      check first.output == second.output

suite "CLI: doctor — самодиагностика (#105)":
  test "отчёт согласован: код возврата ⟺ есть провалы проверок":
    let human = runCli(["doctor"])
    check human.code in [0, 2]
    check "Итог:" in human.output

    let machine = runCli(["doctor", "--json"])
    check machine.code == human.code
    check machine.output.count('\n') == 1

    let node = parseJson(machine.output)
    check node["schema"].getInt == 1
    check node["ok"].getBool == (machine.code == 0)
    check node["exitCode"].getInt == machine.code

    var sections = 0
    var fails = 0
    for section in node["sections"]:
      inc sections
      check section["status"].getStr in ["ok", "warn", "fail"]
      for checkItem in section["checks"]:
        check checkItem["title"].getStr.len > 0
        if checkItem["status"].getStr == "fail":
          inc fails
    check sections == 6
    check node["summary"]["fail"].getInt == fails
    check (machine.code == 2) == (fails > 0)

  test "секции покрывают версию, звук, MIDI, плагины, ФС и C-ядра":
    let node = parseJson(runCli(["doctor", "--json"]).output)
    var ids: seq[string] = @[]
    for section in node["sections"]:
      ids.add section["id"].getStr
    check ids == @["build", "audio", "midi", "plugins", "fs", "csrc"]

  test "версия ядра и SIMD-дисплей видны из машинного отчёта":
    let node = parseJson(runCli(["doctor", "--json"]).output)
    check node["sections"][0]["checks"][0]["facts"]["version"].getStr == EuterpiaVersion
    let csrc = node["sections"][5]["checks"][0]
    check csrc["id"].getStr == "simd"
    check csrc["facts"]["hasSimdDispatch"].getBool in [true, false]

  test "--dry-run не проверяет запись и ничего не создаёт":
    let node = parseJson(runCli(["doctor", "--dry-run", "--json"]).output)
    var seenFs = false
    for section in node["sections"]:
      if section["id"].getStr != "fs":
        continue
      seenFs = true
      for checkItem in section["checks"]:
        check checkItem["status"].getStr == "ok"
        check checkItem["facts"]["dryRun"].getBool
        check checkItem["facts"]["writable"].getBool
    check seenFs

  test "устройства читаются, но поток не открывается":
    # Косвенная, но честная проверка: doctor только перечисляет устройства
    # (init + deviceCount + deviceInfo) и не вызывает backendOpen, поэтому
    # статус секции звука может быть «ok» (устройства есть) или «fail»
    # (нет звуковой подсистемы) — но не «открыто».
    let node = parseJson(runCli(["doctor", "--json"]).output)
    var audioStatus = ""
    for section in node["sections"]:
      if section["id"].getStr == "audio":
        for checkItem in section["checks"]:
          if checkItem["id"].getStr == "devices":
            audioStatus = checkItem["status"].getStr
    check audioStatus in ["ok", "fail"]

suite "CLI: автодополнение оболочки (#259)":
  test "completion <shell> печатает скрипт и детерминирован":
    for shell in ["bash", "zsh", "fish"]:
      let first = runCli(["completion", shell])
      check first.code == 0
      check first.output.len > 0
      check "__complete" in first.output
      check first.output == runCli(["completion", shell]).output

  test "неизвестная оболочка: код 1 и понятная ошибка":
    let human = runCli(["completion", "powershell"])
    check human.code == 1
    check "powershell" in human.errput
    check "bash" in human.errput
    let machine = runCli(["--json", "completion", "powershell"])
    check machine.code == 1
    check parseJson(machine.output)["error"]["kind"].getStr == "usage"

  test "completion без оболочки: код 1":
    let r = runCli(["completion"])
    check r.code == 1
    check r.errput.len > 0

  test "кандидаты берутся из реестра: дополнение == машинная справка":
    let fromHelp = machineCommandNames()
    let fromComplete = nonEmptyLines(runCli(["__complete", "--", ""]).output)
    check fromHelp.len >= 4
    check fromComplete == fromHelp

  test "дополняются ключи команды и глобальные ключи":
    check nonEmptyLines(runCli(["__complete", "--", "do"]).output) == @["doctor"]
    check "bash" in nonEmptyLines(runCli(["__complete", "--", "completion", ""]).output)
    check nonEmptyLines(runCli(["__complete", "--", "help", ""]).output) ==
          machineCommandNames()
    check "--json" in nonEmptyLines(runCli(["__complete", "--", "--"]).output)
    check nonEmptyLines(runCli(["__complete", "--", "--j"]).output) == @["--json"]

  test "в шаблонах нет списка команд: новая команда не требует правки скриптов":
    let names = machineCommandNames()
    check names.len >= 4
    for shell in ["bash", "zsh", "fish"]:
      let script = stripComments(runCli(["completion", shell]).output)
      for name in names:
        check name notin script

