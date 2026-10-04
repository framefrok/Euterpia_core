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

import std/[algorithm, json, strutils, tables, times]

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
    issues*: seq[string]
      ## Проблемы, накопленные сборкой (#311). Проверяющий сам решает, что
      ## с ними делать: `writeProjectChecked` откажется писать, а
      ## `render` вернёт ошибку. Молча игнорировать их нельзя — именно так
      ## опечатка в имени параметра терялась раньше.

proc stamp(): string =
  now().format("yyyy-MM-dd'T'HH:mm:ss")

proc ceilToBar(ticks, barTicks: int32): int32 =
  if ticks <= 0:
    return barTicks
  ((ticks + barTicks - 1) div barTicks) * barTicks

proc typeIds*(reg: NodeRegistry): seq[string] =
  ## Все типы нод, зарегистрированные в реестре, по алфавиту. Нужен для
  ## подсказки «доступные типы: …» в ошибке неизвестного типа (#311):
  ## сообщение без списка оставляет человека в ощупь.
  for entry in reg:
    result.add readFixed(entry.desc.id)
  result.sort()

proc paramNames*(reg: NodeRegistry; typeId: string): seq[string] =
  ## Параметры типа по именам. Аналогично: подсказка «допустимые
  ## параметры: …» превращает опечатку в понятную ошибку (#311).
  let entry = reg.findNodeType(typeId)
  if entry.isNil:
    return
  let d = entry.desc
  for k in 0 ..< int(d.paramCount):
    result.add readFixed(d.params[k].name)

proc nodeProblems*(reg: NodeRegistry; typeId, name: string;
                   overrides: openArray[(string, float32)] = []): seq[string] =
  ## Что не так с нодой ДО сборки проекта. Пустой список — всё в порядке.
  ##
  ## Проверяется ровно то, что Builder не может «проверить» в рантайме:
  ## существование типа (раньше это был `doAssert`, то есть падение с
  ## стектреймом) и существование параметра (раньше опечатка молча
  ## ложилась в таблицу и просто не применялась).
  if typeId.len == 0:
    return @["ошибка: пустой идентификатор типа ноды (партия «" & name & "»)"]
  let entry = reg.findNodeType(typeId)
  if entry.isNil:
    return @["ошибка: неизвестный тип ноды: " & typeId &
             "\n       доступные типы: " & typeIds(reg).join(", ")]
  for ov in overrides:
    if ov[0] notin paramNames(reg, typeId):
      return @["ошибка: у ноды " & typeId & " нет параметра «" & ov[0] &
               "»\n       допустимые параметры: " &
               paramNames(reg, typeId).join(", ")]

proc nodeFrom*(reg: NodeRegistry; typeId, name: string; nodeId: int;
               overrides: openArray[(string, float32)]): NodeFormat =
  ## Нода по описателю типа: порты и умолчания параметров — из реестра,
  ## затем переопределения. Так проект получает ровно то, что умеет нода.
  ##
  ## Неизвестный тип НЕ роняет процесс: возвращается нода без портов, а
  ## текст ошибки уже собран в `nodeProblems` (раньше здесь стоял `doAssert`
  ## — AssertionDefect со стектреймом вместо внятного сообщения, #311).
  let entry = reg.findNodeType(typeId)
  result.id = nodeId
  result.nodeType = typeId
  result.name = name
  if entry.isNil:
    return
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
  ## Проблемы (неизвестный тип, чужой параметр) не роняют сборку, а
  ## попадают в `b.issues` — дальше решает вызывающий (#311).
  b.issues.add nodeProblems(b.reg, typeId, name, params)
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
