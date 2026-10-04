# libs/compose/builder.nim
#
# Низкоуровневая сборка ПРОИЗВОЛЬНОГО проекта (issue #300): ноды любых типов,
# связи любых видов, дорожки с нотами — без «одной формы» на все случаи.
#
# Зачем отдельно от `song` (высокоуровневый Arrangement «4 партии + сумматор»):
#   * Arrangement удобен для типовой пьесы, но не выражает граф с эффектами,
#     шинами, вставками;
#   * Builder — это «конструктор»: что добавил и как соединил, то и получилось.
#
# Порт/параметры берутся из описателей типов (`NodeRegistry`), поэтому Builder
# не может «выдумать» ноду, которой нет, или параметр вне диапазона.

import std/[json, tables, times]

import transport
import project
import sdk/node_api
import sdk/node_registry
import builtin/builtin_registry
import compose/score

{.push raises: [].}

type
  PortKind* = enum
    ## Вид порта в Builder. Порядок совпадает с `SignalType`
    ## (sigAudio, sigControl, sigEvent), поэтому `ord(kind)` — тот же номер.
    pkAudio, pkCtrl, pkEvent

  Builder* = object
    reg: NodeRegistry
    proj: ProjectFormat
    nextId: int

proc stamp(): string =
  now().format("yyyy-MM-dd'T'HH:mm:ss")

proc ceilToBar(ticks, barTicks: int32): int32 =
  if ticks <= 0:
    return barTicks
  ((ticks + barTicks - 1) div barTicks) * barTicks

proc nodeFrom*(reg: NodeRegistry; typeId, name: string; nodeId: int;
               overrides: openArray[(string, float32)]): NodeFormat =
  ## Нода по описателю типа: порты и умолчания параметров — из реестра,
  ## затем переопределения. Так проект получает ровно то, что умеет нода.
  let entry = reg.findNodeType(typeId)
  doAssert(not entry.isNil, "неизвестный тип ноды: " & typeId)
  let d = entry.desc
  result.id = nodeId
  result.nodeType = typeId
  result.name = name
  result.audioInCount = int(d.audioInCount)
  result.audioOutCount = int(d.audioOutCount)
  result.ctrlInCount = int(d.ctrlInCount)
  result.ctrlOutCount = int(d.ctrlOutCount)
  result.eventInCount = int(d.eventInCount)
  result.eventOutCount = int(d.eventOutCount)
  for k in 0 ..< int(d.paramCount):
    result.parameters[readFixed(d.params[k].name)] = d.params[k].defaultValue
  for ov in overrides:
    result.parameters[ov[0]] = ov[1]

proc builder*(name: string; tempo: float32 = 120.0f32;
              sampleRate: float32 = 48000.0f32): Builder =
  ## Новый проект: пустой граф, пустой секвенсор.
  result.reg = initNodeRegistry()
  discard registerBuiltinNodes(result.reg)
  result.proj.format = ProjectFormatName
  result.proj.version = ProjectFormatVersion
  result.proj.metadata = ProjectMetadata(
    name: name, author: "", sampleRate: sampleRate, tempo: tempo,
    timeSignature: TimeSignatureFormat(numerator: 4, denominator: 4),
    created: stamp(), modified: stamp())
  result.nextId = 1

proc addNode*(b: var Builder; typeId, name: string;
              params: openArray[(string, float32)] = []): int =
  ## Добавить ноду, вернуть её id (нужен для связей и дорожек).
  result = b.nextId
  inc b.nextId
  b.proj.graph.nodes.add nodeFrom(b.reg, typeId, name, result, params)

proc connect*(b: var Builder; src, srcPort, dst, dstPort: int;
              kind: PortKind = pkAudio) =
  ## Соединить выход ноды со входом другой. Виды портов не проверяются
  ## здесь — это работа `graph check`/компилятора, он же даст внятную ошибку.
  b.proj.graph.connections.add ConnectionFormat(
    srcNodeId: src, srcPortIdx: srcPort, dstNodeId: dst, dstPortIdx: dstPort,
    sigType: ord(kind))

proc addTrack*(b: var Builder; name: string; part: Part;
               channel: int = 0): int32 =
  ## Дорожка с одной клипой: ноты партии, позиция 0.
  result = int32(b.proj.sequencer.tracks.len + 1)
  let barTicks = PpqTicksPerQuarter * 4'i32
  var clip = ClipFormat(
    id: result, clipType: 0, name: name, startTick: 0,
    lengthTicks: ceilToBar(part.lengthTicks, barTicks), loopEnabled: false,
    audioBufferId: -1, color: 0xFFAA66'u32)
  clip.notes = part.toNotes(channel)
  var track = TrackFormat(id: result, name: name, trackType: 0,
                          volume: 1.0f32, pan: 0.0f32)
  track.clips.add clip
  b.proj.sequencer.tracks.add track

proc setParam*(b: var Builder; nodeId: int; name: string; value: float32) =
  ## Правка параметра уже добавленной ноды.
  for i in 0 ..< b.proj.graph.nodes.len:
    if b.proj.graph.nodes[i].id == nodeId:
      b.proj.graph.nodes[i].parameters[name] = value
      return

proc build*(b: Builder): ProjectFormat =
  b.proj

proc writeProject*(b: Builder; path: string) {.raises: [IOError].} =
  writeFile(path, pretty(toJson(b.proj)))

{.pop.}
