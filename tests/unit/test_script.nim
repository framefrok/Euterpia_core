# tests/unit/test_script.nim
#
# Unit-тесты сценариев (`libs/script`, issues #333, #335).
#
# Здесь проверяется то, чего не видно из чёрного CLI-теста:
#   * разбор и каноническая запись — «сценарий, собранный ядром, читается и
#     отвергается понятным кодом» (#333);
#   * `previewScript` не меняет документ — критерий «plan не меняет ни файла,
#     ни документа» проверяется снимком;
#   * транзакция: отказ не оставляет половины изменений;
#   * детерминизм: один сценарий на одном документе даёт побайтово тот же
#     снимок (часы фиксированы `control_fakes`);
#   * сравнение с эталоном (#335): метрики, сценарий, сэмплы.
#
# CLI-часть (команды, NDJSON, REPL) проверяется запуском бинаря в
# `tests/cli_test.nim`: `cli/` не входит в путь сборки unit-набора.

import std/[json, strutils, unittest]

import project
import control/commands
import control/error_frame
import control/document
import script
import control_fakes

proc scenarioJson(commands: JsonNode; variables: JsonNode = nil;
                  version = 1; description = ""): string =
  ## Сценарий текстом: тесты не должны зависеть от конструктора `Script`,
  ## иначе они проверяли бы запись, которую сами же и сделали.
  var root = %*{
    "format": ScriptFormatName,
    "version": version,
    "commands": commands,
  }
  if description.len > 0:
    root["description"] = %description
  if variables != nil:
    root["variables"] = variables
  $root

proc createAndConnect(): JsonNode =
  ## Минимальный сценарий: нода, вторая нода, связь и параметр.
  %*[
    {"kind": "node.create", "nodeType": "test.osc", "name": "osc"},
    {"kind": "node.create", "nodeType": "test.gain", "name": "out"},
    {"kind": "graph.connect",
     "src": {"nodeId": 1, "kind": 0, "index": 0},
     "dst": {"nodeId": 2, "kind": 0, "index": 0}},
    {"kind": "param.set", "nodeId": 2, "paramName": "gain", "value": 0.5},
  ]

proc parseOk(text: string; overrides: seq[(string, string)] = @[]): Script =
  let frame = parseScript(text, result, overrides)
  check frame.isOk()
  if not frame.isOk():
    checkpoint(frame.message)

suite "script: формат сценария (#333)":
  test "сценарий разбирается, команды сохраняют порядок":
    var sc: Script
    let frame = parseScript(scenarioJson(createAndConnect()), sc)
    check frame.isOk()
    check sc.version == 1
    check sc.commands.len == 4
    check sc.commands[0].kind == ccCreateNode
    check sc.commands[1].kind == ccCreateNode
    check sc.commands[2].kind == ccConnect
    check sc.commands[3].kind == ccSetParameter

  test "каноническая запись детерминирована и читается обратно":
    let sc = parseOk(scenarioJson(createAndConnect()))
    let first = encodeScript(sc)
    let second = encodeScript(sc)
    check first == second
    var reread: Script
    check parseScript(first, reread).isOk()
    check encodeScript(reread) == first

  test "чужой формат отвергается, а не читается как пустой сценарий":
    var sc: Script
    let frame = parseScript(
      """{"format":"other","version":1,"commands":[]}""", sc)
    check not frame.isOk()
    check frame.code == ecInvalidArgument
    check "это не сценарий" in frame.message

  test "будущая версия отвергается понятным кодом (#333)":
    var sc: Script
    let frame = parseScript(scenarioJson(createAndConnect(), version = 99), sc)
    check not frame.isOk()
    check frame.code == ecInvalidArgument
    check "новее этой сборки" in frame.message
    check "обновите euterpia" in frame.hint

  test "неизвестная команда названа с номером, а не пропущена":
    var sc: Script
    let text = scenarioJson(%*[{"kind": "node.explode", "nodeType": "x"}])
    let frame = parseScript(text, sc)
    check not frame.isOk()
    check frame.code == ecUnsupportedCommand
    check "команда #0" in frame.message
    check "node.explode" in frame.message

  test "сценарий без команд — ошибка данных":
    var sc: Script
    let frame = parseScript(scenarioJson(%*[]), sc)
    check not frame.isOk()
    check frame.code == ecInvalidArgument
    check "без команд" in frame.message

  test "переменные подставляются с типом: `${freq}` — число":
    let commands = %*[
      {"kind": "node.create", "nodeType": "test.osc", "name": "osc"},
      {"kind": "param.set", "nodeId": 1, "paramName": "freq",
       "value": "${freq}"},
    ]
    let text = scenarioJson(commands, %*{"freq": 220})
    var sc: Script
    check parseScript(text, sc).isOk()
    check sc.commands[1].value == 220.0f
    # `--var` сильнее значения из файла и тоже сохраняет тип.
    var overridden: Script
    check parseScript(text, overridden, @[("freq", "330")]).isOk()
    check overridden.commands[1].value == 330.0f

  test "неизвестная переменная — отказ с адресом места":
    let commands = %*[
      {"kind": "param.set", "nodeId": 1, "paramName": "freq",
       "value": "${nope}"},
    ]
    var sc: Script
    let frame = parseScript(scenarioJson(commands), sc)
    check not frame.isOk()
    check frame.code == ecInvalidArgument
    check "commands[0]" in frame.message
    check "nope" in frame.message

suite "script: план и транзакция (#333)":
  test "preview не меняет документ, но показывает изменение":
    var doc = newDoc()
    let before = snapshot(doc)
    let sc = parseOk(scenarioJson(createAndConnect()))
    let run = previewScript(doc, sc, "тест")
    check run.frame.isOk()
    check run.changed
    check snapshot(doc) == before
    check run.summary["nodes"]["delta"].getInt == 2
    check run.summary["connections"]["delta"].getInt == 1

  test "apply меняет документ, план знает обратные команды":
    var doc = newDoc()
    let sc = parseOk(scenarioJson(createAndConnect()))
    let run = applyScript(doc, sc, "тест")
    check run.frame.isOk()
    check doc.proj.graph.nodes.len == 2
    check doc.proj.graph.connections.len == 1
    check run.plan.undo.len > 0
    check run.plan.redo.len == 4

  test "один сценарий на одном документе даёт побайтово тот же снимок":
    var first = newDoc()
    var second = newDoc()
    let sc = parseOk(scenarioJson(createAndConnect()))
    check applyScript(first, sc, "тест").frame.isOk()
    check applyScript(second, sc, "тест").frame.isOk()
    check snapshot(first) == snapshot(second)

  test "отказ не оставляет половины изменений":
    var doc = newDoc()
    let before = snapshot(doc)
    # Вторая команда ссылается на ноду, которой нет: транзакция обязана
    # отмениться целиком, хотя первая команда прошла бы.
    let commands = %*[
      {"kind": "node.create", "nodeType": "test.osc", "name": "osc"},
      {"kind": "param.set", "nodeId": 99, "paramName": "freq", "value": 10.0},
    ]
    let sc = parseOk(scenarioJson(commands))
    let run = applyScript(doc, sc, "тест")
    check not run.frame.isOk()
    check run.frame.code == ecNotFound
    check snapshot(doc) == before

  test "сценарий из данных и код собирают один и тот же документ (#148)":
    # «Из реестра Editor'а» здесь означает: тот же `applyScript`, но команды
    # собраны конструкторами control-слоя, а не JSON.
    var fromData = newDoc()
    let sc = parseOk(scenarioJson(createAndConnect()))
    check applyScript(fromData, sc, "сценарий").frame.isOk()

    var fromCode = newDoc()
    let direct = @[
      createNode("test.osc", "osc"),
      createNode("test.gain", "out"),
      connect(port(1, cpkAudio, 0), port(2, cpkAudio, 0)),
      setParameter(2, 0.5f, "gain"),
    ]
    let directScript = Script(version: ScriptFormatVersion, commands: direct)
    check applyScript(fromCode, directScript, "сценарий").frame.isOk()
    check snapshot(fromData) == snapshot(fromCode)


suite "script: эталон рендера (#335)":
  proc baseline(): Baseline =
    Baseline(frames: 100, sampleRate: 48000, bits: 16, peak: 0.5, rms: 0.25,
             silent: false, measured: true, fileSha1: "abc",
             samplesSha1: "def", scenarioSha1: "s1")

  test "совпадение: различий нет, включая сэмплы":
    let b = baseline()
    check compareBaseline(b, b, samples = true).len == 0

  test "различие метрик названо полем и значениями":
    var changed = baseline()
    changed.peak = 0.75
    let diffs = compareBaseline(baseline(), changed, samples = false)
    check diffs.len == 1
    check "пик:" in diffs[0]

  test "правка сценария требует явного обновления эталона":
    var changed = baseline()
    changed.scenarioSha1 = "s2"
    let diffs = compareBaseline(baseline(), changed, samples = false)
    check diffs.len == 1
    check "--update-baseline" in diffs[0]

  test "сэмплы сравниваются только с --samples":
    var changed = baseline()
    changed.samplesSha1 = "zzz"
    check compareBaseline(baseline(), changed, samples = false).len == 0
    check compareBaseline(baseline(), changed, samples = true).len == 1

  test "эталон без метрик не выдаёт себя за совпадение":
    let empty = Baseline(scenarioSha1: "s1", frames: 100, sampleRate: 48000,
                         bits: 16)
    let diffs = compareBaseline(empty, baseline(), samples = true)
    check diffs.len == 1
    check "без метрик" in diffs[0]

  test "запись эталона детерминирована и читается обратно":
    let text = encodeBaseline(baseline())
    check text == encodeBaseline(baseline())
    var parsed: Baseline
    check parseBaseline(parseJson(text), parsed).isOk()
    check parsed.frames == 100
    check parsed.peak == 0.5
    check encodeBaseline(parsed) == text

  test "чужая версия эталона отвергается":
    var parsed: Baseline
    let node = %*{"format": BaselineFormatName, "version": 99}
    let frame = parseBaseline(node, parsed)
    check not frame.isOk()
    check frame.code == ecInvalidArgument

