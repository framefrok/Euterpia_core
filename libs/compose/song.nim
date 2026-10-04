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
#   * `writeProject` / `writeNotes` — запись `.eut` и текстовых партитур.
#
# Слой: верхний (libs). Зависит от Core и Nodes — наоборот быть не может.

import std/[json, os, times]

import signal_types
import transport
import project
import sdk/node_registry
import builtin/builtin_registry
import compose/builder
import compose/score

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

  Arrangement* = object
    ## Пьеса: метаданные и список партий в порядке следования дорожек.
    ## Порядок важен: загрузчик сцены сопоставляет дорожки с нотными нодами
    ## по возрастанию id, а мы создаём их в этом же порядке.
    name*: string
    tempo*: float32
    sampleRate*: float32
    mixLevel*: float32
    entries*: seq[PartEntry]

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

proc add*(arr: var Arrangement; inst: Instrument; p: Part) =
  ## Добавить партию. Порядок вызовов = порядок дорожек = порядок нотных нод.
  arr.entries.add PartEntry(inst: inst, part: p)

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
                            volume: 1.0f32, pan: 0.0f32)
    track.clips.add clip
    result.sequencer.tracks.add track

  result.graph.nodes.add makeNode(reg, "euterpia.mix", "Mix", mixId,
                                  @[("level", arr.mixLevel)])

# ============================================================================
# Запись
# ============================================================================

proc writeProject*(arr: Arrangement; path: string) {.raises: [IOError].} =
  ## Записать проект в `.eut` (JSON из Core — формат не разъезжается).
  writeFile(path, pretty(toJson(buildProject(arr))))

proc writeNotes*(arr: Arrangement; dir: string) {.raises: [IOError].} =
  ## Записать текстовые партитуры (нотация ядра) — человеку и CLI.
  for e in arr.entries:
    let path = dir / (e.part.name & ".notes")
    writeFile(path, "# " & e.part.name & " — " & arr.name & " (generated)\n" &
              e.part.toNotation())

{.pop.}

