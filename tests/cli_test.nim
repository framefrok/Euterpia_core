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

import std/[unittest, os, osproc, strutils, json, streams, algorithm]
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

# =============================================================================
# Помощники suite «проект» (#89)
# =============================================================================

let cliAbsPath = absolutePath(cliPath)

proc runCliIn(dir: string; args: openArray[string]): RunResult =
  ## Запуск CLI с другим рабочим каталогом: команды проекта умеют работать
  ## с файлом по умолчанию (`project.eut`), и это поведение проверяется
  ## только из каталога, где такого файла нет «под ногами» у теста.
  ## Путь к бинарю абсолютный: относительный сломался бы после смены каталога.
  let process = startProcess(cliAbsPath, workingDir = dir, args = @args,
                             options = {})
  result.output = process.outputStream.readAll()
  result.errput = process.errorStream.readAll()
  discard process.waitForExit()
  result.code = process.peekExitCode()
  process.close()

proc diffPaths(a, b: JsonNode; prefix: string = ""): seq[string] =
  ## Пути полей, которыми два JSON различаются. Проверка «set меняет только
  ## темп» обязана быть списком путей, а не «на глаз»: иначе любое лишнее
  ## изменение в будущем прошло бы незамеченным.
  if a.isNil or b.isNil or a.kind != b.kind:
    return @[prefix]
  case a.kind
  of JObject:
    var keys: seq[string] = @[]
    for key, _ in a: keys.add key
    for key, _ in b:
      if key notin keys: keys.add key
    for key in keys:
      if not a.hasKey(key) or not b.hasKey(key):
        result.add key
      else:
        let joined = if prefix.len == 0: key else: prefix & "." & key
        result.add diffPaths(a[key], b[key], joined)
  of JArray:
    if a.len != b.len:
      return @[prefix]
    for i in 0 ..< a.len:
      result.add diffPaths(a[i], b[i], prefix & "[" & $i & "]")
  else:
    if a != b:
      result.add prefix

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

# =============================================================================
# #89: команды проекта
# =============================================================================

suite "CLI: проект — init/show/set/validate (#89)":
  let dir = getTempDir() / "euterpia_cli_project"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)

  test "init → project show воспроизводит метаданные":
    let path = dir / "meta.eut"
    let created = runCli(["init", path, "--sr", "44100", "--tempo", "133",
                          "--ts", "7/8", "--name", "Demo", "--author", "Ada"])
    check created.code == 0
    check "темп: 133.0 BPM" in created.output
    check "записан: " & path in created.output
    check fileExists(path)

    let machine = runCli(["project", "show", path, "--json"])
    check machine.code == 0
    check machine.output.count('\n') == 1
    let node = parseJson(machine.output)
    check node["schema"].getInt == 1
    check node["ok"].getBool
    check node["command"].getStr == "project"
    check node["path"].getStr == path
    check node["metadata"]["name"].getStr == "Demo"
    check node["metadata"]["author"].getStr == "Ada"
    check node["metadata"]["sampleRate"].getFloat == 44100.0
    check node["metadata"]["tempo"].getFloat == 133.0
    check node["metadata"]["timeSignature"]["numerator"].getInt == 7
    check node["metadata"]["timeSignature"]["denominator"].getInt == 8
    check node["summary"]["nodes"].getInt == 0
    check node["summary"]["tracks"].getInt == 0
    check node["graph"]["nodes"].len == 0
    check node["sequencer"]["tracks"].len == 0
    check node["pluginStates"].len == 0

    # Машинный ответ — то же, что лежит в файле: CLI не пересказывает формат
    # своими словами (§20), поэтому `metadata` обязан совпасть побайтово.
    check node["metadata"] == parseJson(readFile(path))["metadata"]

    let human = runCli(["project", "show", path])
    check human.code == 0
    check human.errput.len == 0
    check "имя: Demo" in human.output
    check "размер: 7/8" in human.output
    check "Граф: нод 0, связей 0" in human.output
    check "Секвенсор: треков 0, клипов 0, нот 0" in human.output
    check "Состояния плагинов: 0" in human.output

  test "без файла команды проекта работают с project.eut (пример MANIFEST §19)":
    let work = dir / "cwd"
    createDir(work)
    check runCliIn(work, ["init"]).code == 0
    check fileExists(work / "project.eut")

    # Имя проекта по умолчанию — имя файла: это задокументированное правило,
    # а не догадка (иначе `project show` печатал бы пустое имя).
    let shown = parseJson(runCliIn(work, ["project", "show", "--json"]).output)
    check shown["metadata"]["name"].getStr == "project"

    check runCliIn(work, ["project", "set", "tempo", "140"]).code == 0
    let after = parseJson(runCliIn(work, ["project", "show", "--json"]).output)
    check after["metadata"]["tempo"].getFloat == 140.0
    check runCliIn(work, ["project", "validate"]).code == 0

  test "init не затирает существующий проект без --force":
    let path = dir / "keep.eut"
    check runCli(["init", path, "--name", "First"]).code == 0
    let before = readFile(path)

    let again = runCli(["init", path, "--name", "Second"])
    check again.code == 1
    check "уже существует" in again.errput
    check readFile(path) == before

    check runCli(["init", path, "--name", "Second", "--force"]).code == 0
    let shown = parseJson(runCli(["project", "show", path, "--json"]).output)
    check shown["metadata"]["name"].getStr == "Second"

  test "--dry-run показывает план и не касается диска":
    let path = dir / "dry.eut"
    let created = runCli(["init", path, "--tempo", "150", "--dry-run"])
    check created.code == 0
    check "не записан" in created.output
    check not fileExists(path)

    check runCli(["init", path]).code == 0
    let before = readFile(path)
    let changed = runCli(["project", "set", path, "tempo", "150", "--dry-run"])
    check changed.code == 0
    check "не записан" in changed.output
    check readFile(path) == before

  test "project set меняет только указанное поле (и отметку изменения)":
    let path = dir / "set.eut"
    check runCli(["init", path, "--name", "Set", "--sr", "48000"]).code == 0

    # Поля и ожидаемые пути в JSON — один источник: и организация цикла,
    # и само ожидание проверки.
    let cases = [
      (field: "name", value: "Other", paths: @["metadata.name"]),
      (field: "author", value: "Ada", paths: @["metadata.author"]),
      (field: "sample-rate", value: "44100", paths: @["metadata.sampleRate"]),
      (field: "tempo", value: "140", paths: @["metadata.tempo"]),
      (field: "time-signature", value: "5/8",
       paths: @["metadata.timeSignature.denominator",
                "metadata.timeSignature.numerator"]),
    ]
    for item in cases:
      let before = parseJson(readFile(path))
      check runCli(["project", "set", path, item.field, item.value]).code == 0
      let after = parseJson(readFile(path))

      var changed = diffPaths(before, after)
      changed.sort()
      # `metadata.modified` — отметка последнего изменения: она либо
      # сдвинулась, либо осталась прежней, если правка уложилась в ту же
      # секунду. Всё остальное обязано совпасть с точностью до указанного
      # поля — критерий #89 «остальное байт-в-байт» (сравнение JSON).
      var dataChanges: seq[string] = @[]
      for changedPath in changed:
        if changedPath != "metadata.modified":
          dataChanges.add changedPath
      check dataChanges == item.paths
      check after["metadata"]["modified"].getStr >=
            before["metadata"]["modified"].getStr

    # Повторная запись того же значения не переписывает файл: иначе
    # идемпотентный `set` поднимал бы отметку изменения на ровном месте.
    let bytes = readFile(path)
    check runCli(["project", "set", path, "tempo", "140"]).code == 0
    check readFile(path) == bytes

  test "project set: неизвестное поле, неверное значение, лишние аргументы — код 1":
    let path = dir / "fields.eut"
    check runCli(["init", path]).code == 0
    let before = readFile(path)

    for bad in [@["bogus", "1"], @["tempo", "0"], @["tempo", "abc"],
                @["sample-rate", "-1"], @["time-signature", "4/6"],
                @["time-signature", "4"], @["tempo"]]:
      let r = runCli(@["project", "set", path] & bad)
      check r.code == 1
      check r.errput.len > 0

    check "поля:" in runCli(["project", "set", path, "bogus", "1"]).errput
    check readFile(path) == before

    # Диспетчер подкоманд тоже отвечает кодом 1, а не падением.
    check runCli(["project"]).code == 1
    check runCli(["project", "frob"]).code == 1
    check runCli(["project", "show", path, "extra"]).code == 1

  test "повреждённый файл: код 1, сообщение и файл НЕ перезаписан":
    let path = dir / "broken.eut"
    writeFile(path, "{ это не проект")
    let before = readFile(path)

    let human = runCli(["project", "set", path, "tempo", "140"])
    check human.code == 1
    check human.output.len == 0
    check human.errput.len > 0
    check readFile(path) == before

    let machine = runCli(["--json", "project", "set", path, "tempo", "140"])
    check machine.code == 1
    let node = parseJson(machine.output)
    check node["ok"].getBool == false
    check node["exitCode"].getInt == 1
    check node["error"]["kind"].getStr == "usage"
    check readFile(path) == before

    # Отсутствующий файл — тоже данные (1), и подсказка ведёт к init.
    let missing = runCli(["project", "show", dir / "nope.eut"])
    check missing.code == 1
    check "euterpia init" in missing.errput

  test "validate: отчёт по секциям, повреждённый файл даёт код 1":
    let path = dir / "broken2.eut"
    writeFile(path, "] не json [")
    let human = runCli(["project", "validate", path])
    check human.code == 1
    check "[fail]" in human.output
    check "Итог:" in human.output

    let machine = runCli(["project", "validate", path, "--json"])
    check machine.code == 1
    check machine.output.count('\n') == 1
    let node = parseJson(machine.output)
    check node["ok"].getBool == false
    check node["exitCode"].getInt == 1
    check node["error"]["kind"].getStr == "usage"
    check node["sections"][0]["id"].getStr == "file"
    check node["sections"][0]["checks"][0]["status"].getStr == "fail"
    check node["summary"]["fail"].getInt > 0

  test "validate не падает на проекте без необязательных секций":
    let path = dir / "minimal.eut"
    writeFile(path, """{"format":"euterpia-project","version":1}""")
    let human = runCli(["project", "validate", path])
    check human.code == 0
    check "Итог: " in human.output

    let machine = runCli(["project", "validate", path, "--json"])
    check machine.code == 0
    let node = parseJson(machine.output)
    check node["ok"].getBool
    check node["path"].getStr == path
    var ids: seq[string] = @[]
    for section in node["sections"]:
      ids.add section["id"].getStr
    check ids == @["file", "format", "metadata", "graph", "sequencer", "plugins"]
    # Пустые метаданные — предупреждение, а не отказ: совместимость вперёд.
    check node["summary"]["warn"].getInt > 0
    check node["summary"]["fail"].getInt == 0

    # Чужая версия формата — это данные, а не среда: код 1 и kind «usage».
    let newer = dir / "newer.eut"
    writeFile(newer, """{"format":"euterpia-project","version":999}""")
    check runCli(["project", "validate", newer]).code == 1
    let newerJson = parseJson(
      runCli(["project", "validate", newer, "--json"]).output)
    check newerJson["error"]["kind"].getStr == "usage"

  test "validate находит несогласованность графа: код 1":
    let path = dir / "dangling.eut"
    writeFile(path, """{"format":"euterpia-project","version":1,
      "metadata":{"name":"X","sampleRate":48000,"tempo":120},
      "graph":{"nodes":[{"id":1,"nodeType":"fx.gain","audioInCount":1,"audioOutCount":1}],
               "connections":[{"srcNodeId":1,"srcPortIdx":0,"dstNodeId":7,"dstPortIdx":0}]}}""")
    let human = runCli(["project", "validate", path])
    check human.code == 1
    check "нет такой ноды" in human.output

    let node = parseJson(runCli(["project", "validate", path, "--json"]).output)
    check node["summary"]["fail"].getInt > 0
    var graphFacts: JsonNode = nil
    for section in node["sections"]:
      if section["id"].getStr != "graph":
        continue
      for checkItem in section["checks"]:
        if checkItem["id"].getStr == "connections":
          graphFacts = checkItem["facts"]
    check graphFacts != nil
    check graphFacts["dangling"].len == 1

  test "новые команды видны в справке, машинной справке и автодополнении":
    let names = machineCommandNames()
    check "init" in names
    check "project" in names
    # Порядок справки: сначала «создать проект», затем всё остальное.
    check names[0] == "init"
    check names[1] == "project"

    check nonEmptyLines(runCli(["__complete", "--", "proj"]).output) ==
          @["project"]
    check nonEmptyLines(runCli(["__complete", "--", "project", ""]).output) ==
          @["show", "set", "validate"]
    check "--tempo" in nonEmptyLines(runCli(["__complete", "--", "init", "--tem"]).output)

    let human = runCli(["help", "project"])
    check human.code == 0
    check "show | set | validate" in human.output
    check "project set" in human.output

    let machine = parseJson(runCli(["help", "project", "--json"]).output)
    check machine["helpFor"].getStr == "project"
    check machine["notes"].len > 0
    var subs: seq[string] = @[]
    for sub in machine["subcommands"]:
      subs.add sub.getStr
    check subs == @["show", "set", "validate"]

