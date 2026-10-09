# libs/compose/song.nim
#
# Сборка НАСТОЯЩЕГО проекта EUTERPIA из партитуры (libs/compose/score) —
# «композиция как код» (#285).
#
# Зачем: проект — это данные Core (`core/project`), и генерировать их лучше
# тем же типом, что читает ядро. Тогда формат не разъезжается (JSON и
# структура — из одного `toJson`), а параметры нод берутся из описателей
# типов (`NodeDesc`), а не пишутся руками. Ошибка в типе ноды или имени
# параметра видна сразу, а не в тихом расхождении с CLI.
#
# Что даёт библиотека:
#   * `instrument` — описание партии-инструмента (тип ноды, имя, нотная нода,
#     параметры);
#   * `arrangement` + `add` — раскладка партий;
#   * `buildProject` — `ProjectFormat`: ноды (ноты + инструмент на партию,
#     сумматор в конце), события и аудиосвязи, дорожки с нотами;
#   * `writeProject` / `writeNotes` — запись `.eproj` и текстовых партитур.
#
# Слой: верхний (libs). Зависит от Core и Nodes — наоборот быть не может.

import std/[algorithm, json, math, os, strutils, tables, times]

import signal_types
import transport
import project
import sdk/node_registry
import builtin/builtin_registry
import compose/builder
import compose/score
import compose/automation
  # AutoLane/AutoPoint — DSL автоматизации; компиляция в тики и paramId — здесь.

{.push raises: [].}

type
  Instrument* = object
    ## Партия-инструмент: тип ноды, человеческое имя, имя нотной ноды и
    ## переопределения параметров (имя → значение). Остальные параметры
    ## берутся из описателя типа — как если бы ноду добавили через CLI.
    nodeType*: string
    nodeName*: string
    notesName*: string
    params*: seq[tuple[name: string; value: float32]]

  PartEntry* = object
    inst*: Instrument
    part*: Part
    mute*: bool
      ## Дорожка выключена (TrackFormat.mute): ноты читаются, но не звучат —
      ## то же, что mute дорожки в секвенсоре Core (#COMPOSE-012).

  Arrangement* = object
    ## Пьеса: метаданные и список партий в порядке следования дорожек.
    ## Порядок важен: загрузчик сцены сопоставляет дорожки с нотными нодами
    ## по возрастанию id, а мы создаём их в этом же порядке.
    name*: string
    tempo*: float32
    sampleRate*: float32
    mixLevel*: float32
    entries*: seq[PartEntry]
    automation*: seq[AutoLane]
      ## Дорожки автоматизации (масштаб: такты). Компилируются в
      ## `sequencer.automationLanes` с числовыми id параметров (#COMPOSE-011).

# ============================================================================
# Описание
# ============================================================================

proc instrument*(nodeType, nodeName, notesName: string): Instrument =
  Instrument(nodeType: nodeType, nodeName: nodeName, notesName: notesName)

proc setParam*(inst: var Instrument; name: string; value: float32) =
  ## Переопределить параметр инструмента (level, pan, tone, bars…).
  inst.params.add (name, value)

proc arrangement*(name: string; tempo: float32 = 120.0f32;
                  sampleRate: float32 = 48000.0f32): Arrangement =
  Arrangement(name: name, tempo: tempo, sampleRate: sampleRate, mixLevel: 0.0f32)

proc add*(arr: var Arrangement; inst: Instrument; p: Part;
          mute: bool = false) =
  ## Добавить партию. Порядок вызовов = порядок дорожек = порядок нотных нод.
  arr.entries.add PartEntry(inst: inst, part: p, mute: mute)

# ============================================================================
# Внутреннее
# ============================================================================

proc stamp(): string =
  now().format("yyyy-MM-dd'T'HH:mm:ss")

proc ceilToBar(ticks, barTicks: int32): int32 =
  if ticks <= 0:
    return barTicks
  let bars = (ticks + barTicks - 1) div barTicks
  bars * barTicks

proc makeNode(reg: NodeRegistry; typeId, name: string; nodeId: int;
              overrides: seq[tuple[name: string; value: float32]]): NodeFormat =
  ## Нода по описателю типа (делегат к `compose/builder`).
  nodeFrom(reg, typeId, name, nodeId, overrides)

# ============================================================================
# Проверка ДО сборки (issue #311)
# ============================================================================
#
# Правило простое: «ошибка:» — сборка невозможна, «внимание:» — сборка
# возможна, но человек должен знать. Разделение нужно, потому что пустой
# проект законен, а опечатка в параметре — нет.

proc validate*(arr: Arrangement): seq[string] =
  ## Проблемы раскладки, найденные ДО сборки проекта. Пустой список —
  ## всё в порядке. Собирается всё сразу, а не падает на первом: пять
  ## опечаток должны быть видны за один запуск, а не за пять.
  var reg = initNodeRegistry()
  discard registerBuiltinNodes(reg)

  if arr.entries.len == 0:
    result.add "внимание: в раскладке нет ни одной партии — проект будет пустым"

  var used: Table[string, int]
  for i, e in arr.entries:
    let who = "партия " & $i & " («" & e.part.name & "»)"
    for problem in nodeProblems(reg, e.inst.nodeType, e.inst.nodeName,
                                e.inst.params):
      result.add who & ": " & problem
    if e.inst.notesName.len == 0:
      result.add who & ": ошибка: пустое имя нотной ноды (notesName)"
    for key in [e.inst.nodeName, e.inst.notesName]:
      if key.len == 0:
        continue
      # getOrDefault, а не `used[key]`: под `raises: []` обращение к
      # отсутствующему ключу компилятор считает KeyError — проверка ниже
      # делает KeyError недостижимым, но сигнатуру это не отменяет.
      let prior = used.getOrDefault(key, -1)
      if prior >= 0:
        result.add who & ": ошибка: имя ноды «" & key &
                 "» уже занято партией " & $prior &
                 " — имена нод должны быть уникальны"
      else:
        used[key] = i
    if e.part.bars.len == 0:
      result.add who & ": внимание: партия без тактов — будет тишина"

  # Автоматизация: дорожка и параметр должны существовать (#COMPOSE-011).
  # Проверка до сборки важна: `buildProject` пропускает проблемные дорожки, и
  # без этого автоматизация исчезла бы молча (та же болезнь, что #311).
  for lane in arr.automation:
    let who = "automation («" & lane.track & "».«" & lane.param & "»)"
    var nodeType = ""
    if lane.track == MixTrack:
      nodeType = "euterpia.mix"
    else:
      for e in arr.entries:
        if e.part.name == lane.track:
          nodeType = e.inst.nodeType
          break
    if nodeType.len == 0:
      result.add who & ": ошибка: дорожки «" & lane.track &
                 "» нет в раскладке (или её параметр перепутан со «@mix»)"
      continue
    if paramIdByName(reg, nodeType, lane.param) < 0:
      result.add who & ": ошибка: у ноды " & nodeType & " нет параметра «" &
                 lane.param & "»\n       допустимые параметры: " &
                 paramNames(reg, nodeType).join(", ")
    if lane.points.len == 0:
      result.add who & ": внимание: пустая дорожка автоматизации"

proc isError*(problem: string): bool =
  ## Проблема — ошибка (а не предупреждение)?
  ##
  ## Ищем маркер ВНУТРИ строки, а не в её начале: текст собирается как
  ## «партия 2 («Flute»): ошибка: …», и проверка `startsWith` на такой строке
  ## молча даёт false — то есть ровно тот дефект, который мы чиним (#311).
  problem.find("ошибка:") >= 0

proc hasErrors*(problems: seq[string]): bool =
  ## Есть ли среди проблем нечто, из-за чего сборка невозможна.
  for p in problems:
    if isError(p):
      return true
  false

proc problemBlock*(problems: seq[string]): string =
  ## Текст для stderr: заголовок и список. Отдельная функция, чтобы
  ## одинаково печатали и `writeProject`, и рендер.
  if problems.len == 0:
    return ""
  result = "compose: пьеса не собрана, проблем: " & $problems.len
  for p in problems:
    for line in p.splitLines():
      result.add "\n  " & line

proc toStderr*(text: string) =
  ## Запись в stderr не должна ронять рендер из-за сломанного потока —
  ## то же правило, что в `cli/context.nim` и `compose/progress`.
  try:
    stderr.writeLine(text)
    stderr.flushFile()
  except CatchableError:
    discard

proc warnComposition*(problems: seq[string]) =
  ## Предупреждения — в stderr и всегда. Скрипт `nim r generate.nim`
  ## может их и не смотреть, а человек обязан знать, что партия пустая.
  for p in problems:
    if not isError(p):
      toStderr("compose: " & p)

proc failComposition*(problems: seq[string]) {.noreturn.} =
  ## Громкая остановка без стектрейма: понятный текст и ненулевой код.
  ## Раньше тот же случай давал `AssertionDefect` и падение в
  ## `builder.nim` — диагностика, которой нельзя воспользоваться (#311).
  toStderr(problemBlock(problems))
  quit(1)

# ============================================================================
# Сборка
# ============================================================================

proc buildProject*(arr: Arrangement): ProjectFormat =
  ## Собирает `ProjectFormat`: на каждую партию — нотная нода и инструмент,
  ## все инструменты идут в сумматор, дорожки содержат ноты партий.
  var reg = initNodeRegistry()
  discard registerBuiltinNodes(reg)

  let ppq = PpqTicksPerQuarter
  let barTicks = ppq * 4'i32
  let n = arr.entries.len
  let mixId = 1 + 2 * n

  result.format = ProjectFormatName
  result.version = ProjectFormatVersion
  result.metadata = ProjectMetadata(
    name: arr.name, author: "", sampleRate: arr.sampleRate, tempo: arr.tempo,
    timeSignature: TimeSignatureFormat(numerator: 4, denominator: 4),
    created: stamp(), modified: stamp())

  for i, e in arr.entries:
    let notesId = 1 + 2 * i
    let instId = 2 + 2 * i

    result.graph.nodes.add makeNode(reg, "euterpia.notes", e.inst.notesName,
                                    notesId, @[])
    result.graph.nodes.add makeNode(reg, e.inst.nodeType, e.inst.nodeName,
                                    instId, e.inst.params)

    # События: ноты → инструмент (event-порт 0 в оба конца).
    result.graph.connections.add ConnectionFormat(
      srcNodeId: notesId, srcPortIdx: 0, dstNodeId: instId, dstPortIdx: 0,
      sigType: ord(sigEvent))
    # Аудио: инструмент → сумматор (вход i).
    result.graph.connections.add ConnectionFormat(
      srcNodeId: instId, srcPortIdx: 0, dstNodeId: mixId, dstPortIdx: i,
      sigType: ord(sigAudio))

    var clip = ClipFormat(
      id: int32(i + 1), clipType: 0, name: e.part.name, startTick: 0,
      lengthTicks: ceilToBar(e.part.lengthTicks, barTicks), loopEnabled: false,
      audioBufferId: -1, color: 0xFFAA66'u32)
    clip.notes = e.part.toNotes(channel = i mod 16)

    var track = TrackFormat(id: int32(i + 1), name: e.part.name, trackType: 0,
                            volume: 1.0f32, pan: 0.0f32, mute: e.mute)
    track.clips.add clip
    result.sequencer.tracks.add track

  # Автоматизация: имя дорожки → нода инструмента (или `@mix`), имя параметра →
  # числовой id по дескриптору. Точки заданы в тактах — переводим в тики тем же
  # масштабом, что ноты (`barTicks`), и сортируем по тику: порядок в файле
  # детерминирован (§21). Ошибки имени/параметра уже отдал `validate(arr)`,
  # поэтому здесь беспроблемные дорожки просто пропускаются.
  for lane in arr.automation:
    var nodeId = -1
    var nodeType = ""
    if lane.track == MixTrack:
      nodeId = mixId
      nodeType = "euterpia.mix"
    else:
      for i, e in arr.entries:
        if e.part.name == lane.track:
          nodeId = 2 + 2 * i
          nodeType = e.inst.nodeType
          break
    if nodeId < 0:
      continue
    let paramId = paramIdByName(reg, nodeType, lane.param)
    if paramId < 0:
      continue
    var formatted = AutomationLaneFormat(nodeId: int32(nodeId),
                                         paramId: uint32(paramId))
    for p in lane.points:
      formatted.points.add AutomationPointFormat(
        tick: int32(round(float64(p.bar) * float64(barTicks))),
        value: p.value,
        curve: ord(p.curve))
    formatted.points.sort(proc(a, b: AutomationPointFormat): int = cmp(a.tick, b.tick))
    result.sequencer.automationLanes.add formatted

  result.graph.nodes.add makeNode(reg, "euterpia.mix", "Mix", mixId,
                                  @[("level", arr.mixLevel)])

# ============================================================================
# Запись
# ============================================================================

proc writeProjectChecked*(arr: Arrangement; path: string;
                         problems: var seq[string]): bool {.raises: [IOError].} =
  ## Записать проект `.eproj`, если он собираем. Возвращает false и заполняет
  ## `problems`, когда сборка невозможна; сам файл при этом НЕ создаётся —
  ## на диске не должно остаться «полуправленного» результата (#311).
  problems = validate(arr)
  if hasErrors(problems):
    return false
  warnComposition(problems)
  writeFile(path, pretty(toJson(buildProject(arr))))
  true

proc writeProject*(arr: Arrangement; path: string) {.raises: [IOError].} =
  ## Записать проект `.eproj` (JSON из Core — формат не разъезжается).
  ##
  ## Поведение изменилось: раскладка с опечаткой или неизвестным типом
  ## ноды больше не падает `AssertionDefect` и не пишет «полуправленного»
  ## проекта — она печатает список проблем и завершает скрипт с кодом 1
  ## (#311). `render` и `writeProjectChecked` — варианты для вызывающего,
  ## который хочет решать сам.
  var problems: seq[string]
  if not writeProjectChecked(arr, path, problems):
    failComposition(problems)

proc writeNotes*(arr: Arrangement; dir: string) {.raises: [IOError].} =
  ## Записать текстовые партитуры (нотация ядра) — человеку и CLI.
  for e in arr.entries:
    let path = dir / (e.part.name & ".notes")
    writeFile(path, "# " & e.part.name & " — " & arr.name & " (generated)\n" &
              e.part.toNotation())

{.pop.}

