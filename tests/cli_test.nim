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

import std/[unittest, os, osproc, strutils, json, streams, algorithm, strtabs]
import euterpia_version
# Control-слой нужен тесту как «второй клиент»: он строит тот же документ
# мимо CLI и сравнивает результат (критерий #139 — один путь исполнения).
import project
import handles
import control/error_frame
import control/commands
import control/document

const
  DefaultCliPath =
    when defined(windows): "build/euterpia.exe"
    else: "build/euterpia"

  ConfigEnvPrefix = "EUTERPIA_"
    ## Префикс переменных окружения настроек (issue #258). Продублирован
    ## строкой: `cli/` не входит в путь сборки тестов, а сверять в тесте
    ## нужно именно префикс, которым фильтруется окружение.
  ConfigPathEnv = "EUTERPIA_CONFIG"

type
  RunResult* = object
    output*, errput*: string
    code*: int

let cliPath =
  block:
    let fromEnv = getEnv("EUTERPIA_CLI")
    if fromEnv.len > 0: fromEnv else: DefaultCliPath

# Каталог настроек для тестов: реальный конфиг разработчика не должен влиять
# на suite (и наоборот) — иначе «зелёный локально» ничего не значит (#258).
let configSandbox = getTempDir() / "euterpia_cli_config_home"

proc cliEnv(overrides: seq[(string, string)] = @[]): StringTableRef =
  ## Окружение для запуска CLI: копия текущего МИНУС все `EUTERPIA_*`
  ## (чтобы машина разработчика не подмешивала настройки), плюс песочница
  ## для каталога настроек, плюс явные переопределения теста.
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key.startsWith(ConfigEnvPrefix) or key == "XDG_CONFIG_HOME" or
       key == "APPDATA":
      continue
    result[key] = value
  result["XDG_CONFIG_HOME"] = configSandbox
  result["APPDATA"] = configSandbox
  result["HOME"] = configSandbox
  for item in overrides:
    result[item[0]] = item[1]

proc runCli(args: openArray[string];
            env: seq[(string, string)] = @[]): RunResult =
  let process = startProcess(cliPath, args = @args, env = cliEnv(env),
                             options = {})
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

proc runCliIn(dir: string; args: openArray[string];
              env: seq[(string, string)] = @[]): RunResult =
  ## Запуск CLI с другим рабочим каталогом: команды проекта умеют работать
  ## с файлом по умолчанию (`project.eut`), и это поведение проверяется
  ## только из каталога, где такого файла нет «под ногами» у теста.
  ## Путь к бинарю абсолютный: относительный сломался бы после смены каталога.
  let process = startProcess(cliAbsPath, workingDir = dir, args = @args,
                             env = cliEnv(env), options = {})
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

  test "справочник docs/cli.md описывает каждую команду реестра (#96)":
    # Документация не должна отставать от кода. Сверяем не «на глаз», а
    # множеством имён из машинной справки: команда, добавленная в реестр, но
    # не внесённая в справочник, валит этот тест — справочник остаётся
    # контрактом, а не памяткой.
    const docsPath = "docs/cli.md"
    check fileExists(docsPath)
    let docs = readFile(docsPath)
    for name in machineCommandNames():
      check ("`" & name & "`") in docs

suite "CLI: render — индикатор прогресса (#310)":
  # Тест сам запускает процесс и читает stderr по pipe — терминала там
  # нет по определению. Значит авто-режим обязан промолчать, иначе вывод
  # перестал бы быть детерминированным (#88).
  let renderDir = getTempDir() / "euterpia_cli_render"
  proc renderProjectDir(): string =
    # Свой каталог на тест: рендеру нужен проект, а пустой граф без нот
    # требует явного `--seconds` — ровно как в §19. `--force` потому, что
    # каталог общий на suite.
    createDir(renderDir)
    check runCliIn(renderDir, ["init", "project.eut", "--force"]).code == 0
    # Нода обязательна: рендер пустого графа честно отказывает («собирать
    # нечего»), и тест проверял бы ошибку вместо прогресса.
    check runCliIn(renderDir, ["node", "add", "osc", "--name", "o"]).code == 0
    result = renderDir

  test "без ключей прогресса в stderr нет (stderr — пайп, не терминал)":
    let work = renderProjectDir()
    let r = runCliIn(work, ["render", "--seconds", "1", "--out",
                            work / "out.wav"])
    check r.code == 0
    check "осталось" notin r.errput

  test "--progress печатает прогресс в stderr, stdout остаётся отчётом":
    let work = renderProjectDir()
    let r = runCliIn(work, ["render", "--seconds", "2", "--out",
                            work / "out.wav", "--progress"])
    check r.code == 0
    # stdout — только результат команды (§21): ни одного символа прогресса.
    check "осталось" notin r.output
    check "записано:" in r.output
    check "осталось" in r.errput
    check "%" in r.errput

  test "--no-progress отключает прогресс, даже если шёл после --progress":
    let work = renderProjectDir()
    let r = runCliIn(work, ["render", "--seconds", "1", "--out",
                            work / "out.wav", "--progress", "--no-progress"])
    check r.code == 0
    check "осталось" notin r.errput

  test "--progress — флаг: значение после него не его аргумент":
    let r = runCli(["render", "--progress=1"])
    check r.code == 1
    check "не принимает значение" in r.errput

  test "--dry-run не печатает индикатор: диск не трогаем":
    let work = renderProjectDir()
    let r = runCliIn(work, ["render", "--seconds", "1", "--out",
                            work / "out.wav", "--progress", "--dry-run"])
    check r.code == 0
    check "осталось" notin r.errput

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

# =============================================================================
# #258: настройки окружения
# =============================================================================

suite "CLI: настройки окружения — config (#258)":
  let dir = getTempDir() / "euterpia_cli_config_cases"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  if dirExists(configSandbox):
    removeDir(configSandbox)
  defer:
    removeDir(dir)
    if dirExists(configSandbox):
      removeDir(configSandbox)

  test "config path указывает на каталог настроек из окружения":
    let machine = runCli(["config", "path", "--json"])
    check machine.code == 0
    check machine.output.count('\n') == 1
    let node = parseJson(machine.output)
    check node["path"].getStr == configSandbox / "euterpia" / "config.json"
    check node["exists"].getBool == false
    check "файла нет" in runCli(["config", "path"]).output

  test "config list показывает все ключи и источник каждого значения":
    let human = runCli(["config", "list"])
    check human.code == 0
    check human.errput.len == 0
    for key in ["backend", "device", "sampleRate", "blockSize", "grid",
                "pluginPaths", "cacheDir", "recordDir", "output", "logLevel"]:
      check key & " = " in human.output
    check "backend = miniaudio (default)" in human.output
    check "sampleRate = 48000 (default)" in human.output
    check "device = (не задано) (none)" in human.output

    let machine = runCli(["config", "list", "--json"])
    check machine.code == 0
    check machine.output.count('\n') == 1
    let node = parseJson(machine.output)
    check node["schema"].getInt == 1
    check node["exists"].getBool == false
    var keys: seq[string] = @[]
    for item in node["entries"]:
      keys.add item["key"].getStr
      check item["source"].getStr in ["argv", "env", "file", "default", "none"]
    check keys.len == 10
    check "sampleRate" in keys

  test "config get без ключа повторяет list, с ключом — одно значение":
    check "output = human (default)" in runCli(["config", "get"]).output

    # `--json` в этом запуске сам является источником argv для ключа `output`:
    # команда не врёт о том, почему вывод машинный, а не как в настройках (#258).
    let one = parseJson(runCli(["config", "get", "output", "--json"]).output)
    check one["key"].getStr == "output"
    check one["value"].getStr == "json"
    check one["source"].getStr == "argv"

    let unknown = runCli(["config", "get", "bogus"])
    check unknown.code == 1
    check "ключи:" in unknown.errput
    check runCli(["config"]).code == 1
    check runCli(["config", "frob"]).code == 1
    check runCli(["config", "path", "extra"]).code == 1

  test "config set пишет типизированный файл и отвергает мусор":
    let path = dir / "set.json"
    let env = @[(ConfigPathEnv, path)]

    check runCli(["config", "set", "sampleRate", "44100"], env).code == 0
    check fileExists(path)
    let onDisk = parseJson(readFile(path))
    check onDisk["version"].getInt == 1
    check onDisk["sampleRate"].getInt == 44100   # число, а не строка

    check runCli(["config", "set", "pluginPaths",
                  dir / "p1" & $PathSep & dir / "p2"], env).code == 0
    let withPaths = parseJson(readFile(path))
    check withPaths["pluginPaths"].len == 2
    check withPaths["pluginPaths"][0].getStr == dir / "p1"

    let got = parseJson(
      runCli(["config", "get", "sampleRate", "--json"], env).output)
    check got["value"].getStr == "44100"
    check got["source"].getStr == "file"

    # Неверные значения не пишутся: `set` валидирует тем же кодом, что и чтение.
    let before = readFile(path)
    for bad in [@["sampleRate", "0"], @["sampleRate", "abc"],
                @["blockSize", "99999"], @["output", "yaml"],
                @["backend", "nosuch"], @["bogus", "1"]]:
      let r = runCli(@["config", "set"] & bad, env)
      check r.code == 1
      check r.errput.len > 0
    check readFile(path) == before
    check runCli(["config", "set", "sampleRate"], env).code == 1

  test "config set --dry-run показывает план и не пишет файл":
    let path = dir / "dry.json"
    let env = @[(ConfigPathEnv, path)]
    let r = runCli(["config", "set", "tempo", "1"], env)   # нет такого ключа
    check r.code == 1
    check not fileExists(path)

    let dry = runCli(["config", "set", "output", "json", "--dry-run"], env)
    check dry.code == 0
    check "не записан" in dry.output
    check not fileExists(path)

  test "приоритет: argv > env > файл > умолчание":
    let path = dir / "prio.json"
    let env = @[(ConfigPathEnv, path)]
    check runCli(["config", "set", "sampleRate", "44100"], env).code == 0

    let fromFile = parseJson(
      runCli(["config", "get", "sampleRate", "--json"], env).output)
    check fromFile["value"].getStr == "44100"
    check fromFile["source"].getStr == "file"

    # env сильнее файла
    let fromEnv = parseJson(runCli(["config", "get", "sampleRate", "--json"],
      env & @[("EUTERPIA_SAMPLE_RATE", "96000")]).output)
    check fromEnv["value"].getStr == "96000"
    check fromEnv["source"].getStr == "env"

    # argv сильнее файла: `--human` и `--json` перекрывают output
    check runCli(["config", "set", "output", "json"], env).code == 0
    check "output = human (argv)" in
          runCli(["config", "get", "output", "--human"], env).output
    let argvJson = parseJson(
      runCli(["config", "get", "output", "--json"], env).output)
    check argvJson["value"].getStr == "json"
    check argvJson["source"].getStr == "argv"

    # -v перекрывает logLevel
    let verbose = parseJson(
      runCli(["config", "get", "logLevel", "--json", "-v"], env).output)
    check verbose["value"].getStr == "debug"
    check verbose["source"].getStr == "argv"

  test "битый и неверный конфиг — предупреждение, команда работает":
    let path = dir / "broken.json"
    let env = @[(ConfigPathEnv, path)]
    writeFile(path, "не json вовсе")

    let human = runCli(["version"], env)
    check human.code == 0
    check human.output.strip() == "euterpia " & EuterpiaVersion
    check "конфиг" in human.errput         # предупреждение идёт в stderr

    let machine = runCli(["version", "--json"], env)
    check machine.code == 0
    check machine.output.count('\n') == 1
    check parseJson(machine.output)["ok"].getBool

    # Семантически неверное значение: работаем на источнике ниже, и это видно.
    writeFile(path, """{"sampleRate": -5}""")
    let bad = parseJson(
      runCli(["config", "get", "sampleRate", "--json"], env).output)
    check bad["value"].getStr == "48000"
    check bad["source"].getStr == "default"
    check "используется источник ниже" in
          runCli(["config", "get", "sampleRate"], env).errput

  test "config unset возвращает приоритет источнику ниже":
    let path = dir / "unset.json"
    let env = @[(ConfigPathEnv, path)]
    check runCli(["config", "set", "output", "json"], env).code == 0

    let removed = runCli(["config", "unset", "output", "--json"], env)
    check removed.code == 0
    let node = parseJson(removed.output)
    check node["removed"].getBool
    check node["value"].getStr == "human"
    check node["source"].getStr == "default"
    check not parseJson(readFile(path)).hasKey("output")

    # Повторный unset идемпотентен, неизвестный ключ — ошибка данных.
    let again = runCli(["config", "unset", "output"], env)
    check again.code == 0
    check "не задан" in again.output
    check runCli(["config", "unset", "bogus"], env).code == 1

  test "настройка влияет на команды: output=json перекрывается --human":
    let path = dir / "effect.json"
    let env = @[(ConfigPathEnv, path)]
    check runCli(["config", "set", "output", "json"], env).code == 0

    let asJson = runCli(["version"], env)
    check asJson.code == 0
    check asJson.output.count('\n') == 1
    check parseJson(asJson.output)["command"].getStr == "version"

    let asHuman = runCli(["version", "--human"], env)
    check asHuman.code == 0
    check asHuman.output.strip() == "euterpia " & EuterpiaVersion

  test "EUTERPIA_CONFIG переопределяет путь; незнакомые ключи сохраняются":
    let custom = dir / "custom" / "eut.json"
    let env = @[(ConfigPathEnv, custom)]
    check parseJson(runCli(["config", "path", "--json"], env).output)["path"].getStr ==
          custom
    check runCli(["config", "set", "backend", "miniaudio"], env).code == 0
    check fileExists(custom)

    # Файл мог быть записан более новой сборкой: её ключи не теряются (§59).
    let future = dir / "future.json"
    let futureEnv = @[(ConfigPathEnv, future)]
    writeFile(future, """{"version": 1, "futureKey": {"a": 1}}""")
    check runCli(["config", "set", "logLevel", "debug"], futureEnv).code == 0
    let onDisk = parseJson(readFile(future))
    check onDisk.hasKey("futureKey")
    check onDisk["futureKey"]["a"].getInt == 1
    check onDisk["logLevel"].getStr == "debug"

# =============================================================================
# Граф: node / connect / disconnect / param / graph check (#90)
# =============================================================================

suite "CLI: граф — node/connect/param/graph check (#90)":
  let dir = getTempDir() / "euterpia_cli_graph"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)

  let work = dir / "cwd"
  createDir(work)
  # Проект по умолчанию (`project.eut`) — как в примерах MANIFEST §19:
  # команды графа без `--file` правят именно его. Отдельный тест проверяет,
  # что явный путь (`--file` и аргумент с `.eut`) выбирает другой файл.
  let project = work / "project.eut"

  test "node add: порты, задержка и умолчания берутся из типа ноды":
    check runCliIn(work, ["init", "--name", "Graph"]).code == 0

    let added = runCliIn(work, ["node", "add", "osc"])
    check added.code == 0
    check added.errput.len == 0
    check "добавлена нода #1 Oscillator (euterpia.osc)" in added.output

    check runCliIn(work, ["node", "add", "gain"]).code == 0
    let machine = parseJson(runCliIn(work,
      ["--json", "node", "list", "project.eut"]).output)
    check machine["ok"].getBool
    check machine["command"].getStr == "node"
    check machine["summary"]["nodes"].getInt == 2

    let osc = machine["nodes"][0]
    check osc["id"].getInt == 1
    check osc["type"].getStr == "euterpia.osc"
    check osc["known"].getBool
    check osc["counts"]["audio"]["out"].getInt == 1
    check osc["counts"]["event"]["in"].getInt == 1
    # Параметры в файле — умолчания типа (freq 440, level -6 — из описателя).
    check osc["params"]["freq"].getFloat == 440.0
    check osc["params"]["level"].getFloat == -6.0

    # Файл получает счётчики портов: без них связь некуда привязать.
    let onDisk = parseJson(readFile(project))
    check onDisk["graph"]["nodes"][0]["audioOutCount"].getInt == 1
    check onDisk["graph"]["nodes"][0]["parameters"]["freq"].getFloat == 440.0

  test "node add: неизвестный тип — код 1 и список доступных типов":
    let r = runCliIn(work, ["node", "add", "reverb", "--file", "project.eut"])
    check r.code == 1
    check "reverb" in r.errput
    check "euterpia.osc" in r.errput
    # Файл не изменился: нода не добавилась.
    check parseJson(readFile(project))["graph"]["nodes"].len == 2

  test "node types: каталог типов с портами и параметрами":
    let human = runCliIn(work, ["node", "types"])
    check human.code == 0
    check "euterpia.osc — Oscillator (generator)" in human.output
    check "euterpia.delay — Delay (effects)" in human.output

    let machine = parseJson(runCliIn(work, ["--json", "node", "types"]).output)
    check machine["count"].getInt == machine["types"].len
    var found = false
    for item in machine["types"]:
      if item["id"].getStr == "euterpia.osc":
        found = true
        check item["ports"]["audio"]["out"].getInt == 1
        check item["params"].len == 5
    check found

  test "connect: связь попадает в файл, graph check компилирует граф":
    let connected = runCliIn(work, ["connect", "osc:out", "gain:in"])
    check connected.code == 0
    check "#1:audio:0 → #2:audio:0" in connected.output

    let onDisk = parseJson(readFile(project))
    check onDisk["graph"]["connections"].len == 1
    check onDisk["graph"]["connections"][0]["srcNodeId"].getInt == 1
    check onDisk["graph"]["connections"][0]["dstNodeId"].getInt == 2
    check onDisk["graph"]["connections"][0]["sigType"].getInt == 0

    let checked = runCliIn(work, ["graph", "check", "project.eut"])
    check checked.code == 0
    check "граф компилируется: шагов 2" in checked.output
    check "провалов: 0" in checked.output

    let machine = parseJson(runCliIn(work,
      ["--json", "graph", "check", "project.eut"]).output)
    check machine["ok"].getBool
    check machine["compile"]["verdict"].getStr == "compiles"
    check machine["compile"]["steps"].getInt == 2
    check machine["summary"]["fail"].getInt == 0

  test "connect: вид порта обязан совпадать, повтор связи — ошибка":
    # У gain есть ctrl-вход: осциллятор к нему не подключается.
    let wrongKind = runCliIn(work, ["connect", "osc:out", "gain:ctrl:0"])
    check wrongKind.code == 1
    check "виды портов не совпадают" in wrongKind.errput

    let duplicate = runCliIn(work, ["connect", "osc:out", "gain:in"])
    check duplicate.code == 1
    check "уже есть" in duplicate.errput

    # Порта с таким номером у ноды нет: ошибка называет доступное число.
    let noPort = runCliIn(work, ["connect", "osc:audio:1", "gain:in"])
    check noPort.code == 1
    check "доступно 1" in noPort.errput

  test "param: set проверяет диапазон, get печатает источник значения":
    check runCliIn(work, ["param", "set", "1", "freq", "220"]).code == 0
    check parseJson(readFile(project))["graph"]["nodes"][0]["parameters"]["freq"].getFloat == 220.0

    let got = parseJson(runCliIn(work,
      ["--json", "param", "get", "1", "freq"]).output)
    check got["param"]["value"].getFloat == 220.0
    check got["param"]["source"].getStr == "file"
    check got["param"]["default"].getFloat == 440.0
    check got["param"]["id"].getInt == 1

    # Вне диапазона: отказ, файл не тронут.
    let outOfRange = runCliIn(work, ["param", "set", "1", "freq", "999999"])
    check outOfRange.code == 1
    check "вне диапазона" in outOfRange.errput
    check parseJson(readFile(project))["graph"]["nodes"][0]["parameters"]["freq"].getFloat == 220.0

    # Дискретный параметр не принимает дробное значение.
    let fraction = runCliIn(work, ["param", "set", "1", "waveform", "1.5"])
    check fraction.code == 1
    check "целочисленный" in fraction.errput

    # Нечисловое значение — ошибка данных, а не тихий ноль.
    let notNumber = runCliIn(work, ["param", "set", "1", "freq", "высоко"])
    check notNumber.code == 1
    check "должно быть числом" in notNumber.errput

    # Отрицательное значение — это ЗНАЧЕНИЕ, а не ключ (регрессия #292):
    # раньше `-12` отвергалось как «неизвестный ключ», хотя у level/pan
    # отрицательный диапазон по определению.
    let negative = runCliIn(work, ["param", "set", "1", "level", "-12"])
    check negative.code == 0
    check parseJson(readFile(project))["graph"]["nodes"][0]["parameters"]["level"].getFloat == -12.0

    # Дробное значение дробного параметра принимается (регрессия #292):
    # из-за порядковых значений флагов любой параметр считался целым.
    let fractional = runCliIn(work, ["param", "set", "1", "level", "-6.5"])
    check fractional.code == 0

  test "--dry-run показывает правку и не пишет файл":
    let before = readFile(project)
    let r = runCliIn(work, ["--dry-run", "node", "add", "noise", "--file", "project.eut"])
    check r.code == 0
    check "добавлена нода #3 Noise (euterpia.noise)" in r.output
    check "не записан" in r.output
    check readFile(project) == before

  test "graph check: цикл — провал с вердиктом, а не молчаливый успех":
    check runCliIn(work, ["connect", "gain:out", "gain:in"]).code == 0
    let r = runCliIn(work, ["graph", "check", "project.eut"])
    check r.code == 1
    check "в графе цикл" in r.output
    check "провалов: 1" in r.output

    let machine = parseJson(runCliIn(work,
      ["--json", "graph", "check", "project.eut"]).output)
    check not machine["ok"].getBool
    check machine["exitCode"].getInt == 1
    check machine["compile"]["verdict"].getStr == "cycle"
    check machine["summary"]["fail"].getInt == 1
    # Ошибка объяснена и по-человечески, и машинно: агент берёт verdict.
    check machine["error"]["kind"].getStr == "usage"

    # Без портов снимаются ВСЕ связи между парой нод — цикл уходит.
    let off = runCliIn(work, ["disconnect", "gain", "gain"])
    check off.code == 0
    check "снято связей: 1" in off.output
    check runCliIn(work, ["graph", "check", "project.eut"]).code == 0

  test "disconnect: нет такой связи — ошибка, а не тихий успех":
    let r = runCliIn(work, ["disconnect", "2", "1"])
    check r.code == 1
    check "такой связи нет" in r.errput

    # Связь с указанием портов снимается точечно и соединяется обратно.
    check runCliIn(work, ["disconnect", "osc:out", "gain:in"]).code == 0
    check parseJson(readFile(project))["graph"]["connections"].len == 0
    check runCliIn(work, ["connect", "osc:out", "gain:in"]).code == 0

  test "node rm: удаляет ноду и её связи, граф остаётся согласованным":
    let r = runCliIn(work, ["node", "rm", "2"])
    check r.code == 0
    check "удалена нода #2 Gain (euterpia.gain)" in r.output
    check "удалено связей: 1" in r.output

    let onDisk = parseJson(readFile(project))
    check onDisk["graph"]["nodes"].len == 1
    check onDisk["graph"]["connections"].len == 0

    # Проверка проекта из #89 видит ту же картину, что и проверка графа.
    let validated = runCliIn(work, ["project", "validate", "project.eut"])
    check validated.code == 0
    check "graph: ноды и связи" in validated.output
    check runCliIn(work, ["graph", "check", "project.eut"]).code == 0

  test "пустой граф: предупреждение, но не провал (код 0)":
    check runCliIn(work, ["init", "empty.eut"]).code == 0
    let r = runCliIn(work, ["graph", "check", "empty.eut"])
    check r.code == 0
    check "[warn] в графе есть ноды" in r.output
    check "добавьте ноду: euterpia node add oscillator" in r.output
    check "провалов: 0" in r.output
    check "предупреждений: 1" in r.output

  test "выбор файла: --file и аргумент с .eut указывают на один проект":
    check runCliIn(work, ["init", "other.eut", "--name", "Other"]).code == 0
    check runCliIn(work, ["node", "add", "svf", "other.eut"]).code == 0
    check runCliIn(work, ["node", "add", "delay", "--file", "other.eut"]).code == 0

    # Правки ушли в other.eut, а проект по умолчанию не тронут.
    check parseJson(readFile(work / "other.eut"))["graph"]["nodes"].len == 2
    check parseJson(readFile(project))["graph"]["nodes"].len == 1

    # Первый позиционный аргумент, начинающийся с ключа, файлом не считается.
    let wrong = runCliIn(work, ["node", "list", "--file"])
    check wrong.code == 1
    check "--file" in wrong.errput

  test "вывод детерминирован: два запуска совпадают побайтово":
    let first = runCliIn(work, ["node", "list", "project.eut"]).output
    let second = runCliIn(work, ["node", "list", "project.eut"]).output
    check first == second

  test "справка и автодополнение знают новые команды":
    let names = machineCommandNames()
    for name in ["node", "connect", "disconnect", "param", "graph"]:
      check name in names

    let nodeHelp = runCliIn(work, ["help", "node"])
    check nodeHelp.code == 0
    check "node <list|types|add|rm|show>" in nodeHelp.output
    check "graph check" in runCliIn(work, ["help", "graph"]).output

    let candidates = runCli(["__complete", "--", "n"])
    check candidates.code == 0
    check "node" in candidates.output


# =============================================================================
# Handle-адресация (#143, MANIFEST §35/§36)
# =============================================================================

suite "CLI: handle-адресация (#143)":
  let dir = getTempDir() / "euterpia_cli_handles"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)

  test "адрес печатается, принимается и переживает правки графа":
    check runCliIn(dir, ["init", "a.eut", "--name", "A"]).code == 0
    check runCliIn(dir, ["node", "add", "osc", "a.eut"]).code == 0
    check runCliIn(dir, ["node", "add", "gain", "a.eut"]).code == 0

    # Адрес виден человеку в списке и машине в JSON — обе формы, чтобы клиент
    # не разбирал «node:1.1» из строки.
    let listed = runCliIn(dir, ["node", "list", "a.eut"])
    check listed.code == 0
    check "[node:1.1]" in listed.output
    check "[node:2.1]" in listed.output

    let machine = parseJson(runCliIn(dir,
      ["--json", "node", "list", "a.eut"]).output)
    check machine["nodes"][0]["handle"].getStr == "node:1.1"
    let qualified = machine["nodes"][0]["handleRef"].getStr
    check qualified.startsWith("node:1.1@")
    check qualified.len == "node:1.1@".len + 8

    # Адрес — рабочая ссылка и для ноды, и для её параметра.
    let shown = runCliIn(dir, ["node", "show", "node:1.1", "a.eut"])
    check shown.code == 0
    check "#1" in shown.output

    # У осциллятора параметр 0 — waveform (целочисленный), поэтому freq
    # адресуется вторым: заодно видно, что номер из описателя типа, а не
    # позиция в файле.
    let param = parseJson(runCliIn(dir,
      ["--json", "param", "get", "node:1.1", "node:1.1/param:1", "a.eut"]).output)
    check param["param"]["handle"].getStr == "node:1.1/param:1"
    check param["param"]["name"].getStr == "freq"

    # Правка по адресу попадает в ту же ноду.
    let edited = runCliIn(dir,
      ["param", "set", "node:1.1", "node:1.1/param:1", "330", "a.eut"])
    check edited.code == 0
    check "node:1.1/param:1" in edited.output
    check parseJson(readFile(dir / "a.eut"))["graph"]["nodes"][0]["parameters"]["freq"].getFloat == 330.0

    # Вставка новой ноды не сдвигает адреса уже напечатанных.
    check runCliIn(dir, ["node", "add", "noise", "a.eut"]).code == 0
    check "[node:1.1]" in runCliIn(dir, ["node", "list", "a.eut"]).output

    # Адрес параметра чужой ноды — ошибка, а не тихая подмена на «ту же».
    let mismatch = runCliIn(dir,
      ["param", "get", "node:1.1", "node:2.1/param:1", "a.eut"])
    check mismatch.code == 1
    check "указанной ноде" in mismatch.errput

    # Удалённая нода адреса не имеет; адрес живой ноды продолжает работать.
    check runCliIn(dir, ["node", "rm", "node:2.1", "a.eut"]).code == 0
    let gone = runCliIn(dir, ["node", "show", "node:2.1", "a.eut"])
    check gone.code == 1
    check "нет ноды с адресом" in gone.errput
    check runCliIn(dir, ["node", "show", "node:1.1", "a.eut"]).code == 0

  test "полный адрес отвергает другой документ, сломанный — понятной ошибкой":
    check runCliIn(dir, ["init", "b.eut", "--name", "B"]).code == 0
    let machine = parseJson(runCliIn(dir,
      ["--json", "node", "list", "a.eut"]).output)
    let qualified = machine["nodes"][0]["handleRef"].getStr

    let foreign = runCliIn(dir, ["node", "show", qualified, "b.eut"])
    check foreign.code == 1
    check "другому документу" in foreign.errput

    let broken = runCliIn(dir, ["node", "show", "node:две.раз", "a.eut"])
    check broken.code == 1
    check "адрес" in broken.errput

    let notANode = runCliIn(dir, ["node", "show", "track:1.1", "a.eut"])
    check notANode.code == 1
    check "нужна нода" in notANode.errput

  test "проект называет свой документ: адреса из разных файлов не совпадут":
    let shown = parseJson(runCliIn(dir, ["--json", "project", "show", "a.eut"]).output)
    check shown["documentId"].getStr.len == 8
    let other = parseJson(runCliIn(dir, ["--json", "project", "show", "b.eut"]).output)
    check other["documentId"].getStr != shown["documentId"].getStr

    let human = runCliIn(dir, ["project", "show", "a.eut"])
    check human.code == 0
    check "документ: " & shown["documentId"].getStr in human.output
    check "[node:1.1]" in human.output

  test "вывод с адресами детерминирован (адрес не плывёт между запусками)":
    let first = runCliIn(dir, ["node", "list", "a.eut"]).output
    let second = runCliIn(dir, ["node", "list", "a.eut"]).output
    check first == second
    check "node:1.1" in first

# =============================================================================
# Control Core: одна команда — один результат из CLI и из тестового клиента
# (#139, MANIFEST §65)
# =============================================================================

suite "CLI: control-слой — те же команды, тот же документ (#139)":
  let dir = getTempDir() / "euterpia_cli_control"
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  defer: removeDir(dir)

  proc specsFromCli(): seq[NodeTypeSpec] =
    ## Описания типов берём У CLI (`node types --json`) — это тот же источник,
    ## которым пользуется его провайдер для control-слоя. Тест не дублирует
    ## реестр: если каталог изменится, тест увидит новое описание, а не
    ## устаревшую копию.
    let types = parseJson(runCliIn(dir, ["--json", "node", "types"]).output)["types"]
    for t in types:
      var spec = NodeTypeSpec(
        id: t["id"].getStr,
        name: t["name"].getStr,
        audioIn: t["ports"]["audio"]["in"].getInt,
        audioOut: t["ports"]["audio"]["out"].getInt,
        ctrlIn: t["ports"]["ctrl"]["in"].getInt,
        ctrlOut: t["ports"]["ctrl"]["out"].getInt,
        eventIn: t["ports"]["event"]["in"].getInt,
        eventOut: t["ports"]["event"]["out"].getInt,
        latencyFrames: t["latencyFrames"].getInt
      )
      for p in t["params"].items:
        var flags: seq[string] = @[]
        for flag in p["flags"].items:
          flags.add flag.getStr
        spec.params.add ParamSpec(
          name: p["name"].getStr,
          minValue: p["min"].getFloat.float32,
          maxValue: p["max"].getFloat.float32,
          defaultValue: p["default"].getFloat.float32,
          step: p["step"].getFloat.float32,
          integerLike: ("integer" in flags) or ("choice" in flags)
        )
      result.add spec

  proc providerFor(specs: seq[NodeTypeSpec]): NodeTypeProvider =
    let captured = specs
    result = proc(nodeType: string; spec: var NodeTypeSpec): bool =
      for s in captured:
        if s.id == nodeType:
          spec = s
          return true
      false

  proc blankProject(): ProjectFormat =
    ## Пустой документ для клиента, который строит проект с нуля.
    ProjectFormat(format: ProjectFormatName, version: ProjectFormatVersion)

  proc withoutMetadata(node: JsonNode): JsonNode =
    ## Документы сравниваются без метаданных: отметку времени ставит хозяин
    ## (у CLI — системные часы, у теста — фиксированные), и именно она
    ## единственная намеренно различающаяся часть.
    result = node
    if result.hasKey("metadata"):
      result.delete("metadata")

  test "CLI и тестовый клиент дают один и тот же документ":
    let specs = specsFromCli()
    check specs.len > 0

    # 1. Тот же сценарий через CLI.
    let project = dir / "same.eut"
    check runCliIn(dir, ["init", "same.eut", "--name", "Same"]).code == 0
    check runCliIn(dir, ["node", "add", "osc", "same.eut"]).code == 0
    check runCliIn(dir, ["node", "add", "gain", "same.eut"]).code == 0
    check runCliIn(dir, ["param", "set", "1", "freq", "330", "same.eut"]).code == 0
    check runCliIn(dir, ["connect", "osc:out", "gain:in", "same.eut"]).code == 0

    # 2. Тот же сценарий через control-слой, как это сделал бы Editor.
    var doc: Document
    initDocument(doc, blankProject(), documentIdForPath(absolutePath(dir / "same.eut")),
                 providerFor(specs), proc(): string = "2026-01-01T00:00:00")
    check doc.applyCommand(createNode("euterpia.osc")).isOk()
    check doc.applyCommand(createNode("euterpia.gain")).isOk()
    check doc.applyCommand(setParameter(1, 330.0f32, "freq")).isOk()
    check doc.applyCommand(connect(port(1, cpkAudio, 0), port(2, cpkAudio, 0))).isOk()

    # 3. Документы совпадают.
    let fromCli = parseJson(readFile(project))
    let fromControl = toJson(doc.proj)
    check withoutMetadata(fromCli) == withoutMetadata(fromControl)

  test "отказ команды одинаков у CLI и у control-слоя":
    let specs = specsFromCli()
    let project = dir / "reject.eut"
    check runCliIn(dir, ["init", "reject.eut", "--name", "Reject"]).code == 0
    check runCliIn(dir, ["node", "add", "gain", "reject.eut"]).code == 0
    let before = readFile(project)

    # Тот же отказ, что и у CLI: значение вне диапазона.
    let cli = runCliIn(dir, ["--json", "param", "set", "1", "gain", "99", "reject.eut"])
    check cli.code == 1
    let cliBody = parseJson(cli.output)
    check cliBody["errorCode"].getInt == frameCodeValue(ecOutOfRange)
    check cliBody["error"]["kind"].getStr == "out_of_range"
    check cliBody["exitCode"].getInt == 1
    # Файл не тронут.
    check readFile(project) == before

    var doc: Document
    initDocument(doc, loadProject(project).value, documentIdForPath(absolutePath(project)),
                 providerFor(specs), nil)
    let frame = doc.applyCommand(setParameter(1, 99.0f32, "gain"))
    check frame.code == ecOutOfRange
    check frameCodeValue(frame.code) == cliBody["errorCode"].getInt
    check $frame.code == cliBody["error"]["kind"].getStr
