# undo_redo.nim
#
# Editor-only command history system.
# НЕ использовать из realtime audio thread.
#
# Ответственность модуля:
# - хранение undo/redo истории;
# - поддержка групп/транзакций;
# - сериализация истории;
# - делегирование фактического apply/undo/redo во внешний CommandExecutor.
#
# Модуль НЕ знает о Graph, Nodes, Tracks, Clips и т.д.
# Он оперирует только CommandData и Callback'ами исполнителя.

import std/[options, json, times, os, sequtils]

const
  MaxUndoSteps* = 2048
  MaxCommandNameLen* = 64
  UndoHistoryVersion = 1

type
  CommandType* = enum
    ctAddNode
    ctRemoveNode
    ctMoveNode
    ctAddConnection
    ctRemoveConnection
    ctAddTrack
    ctRemoveTrack
    ctAddClip
    ctRemoveClip
    ctAddNote
    ctRemoveNote
    ctChangeParameter
    ctChangeAutomation
    ctRenameTrack
    ctGroupCommand

  # Serializable command payload.
  # Для сложных операций вроде RemoveNode/RemoveClip полезно хранить
  # сериализованный memento в blob или strData.
  CommandData* = object
    commandType*: CommandType
    timestamp*: int64
    description*: string

    intData*: array[8, int64]
    floatData*: array[8, float32]
    strData*: array[4, string]

    nodeId*: int32
    nodeType*: int32
    posX*, posY*: float32

    srcNodeId*, srcPort*: int32
    dstNodeId*, dstPort*: int32
    sigType*: int32

    trackId*, clipId*: int32
    startTick*, duration*: int32
    pitch*, velocity*: uint8

    paramId*: uint32
    oldValue*, newValue*: float32

    # Optional serialized memento / payload.
    blob*: string

  # Интерпретатор команд.
  #
  # Возвращаемый bool означает:
  # - true  -> операция выполнена успешно;
  # - false -> операция не выполнена, историю не менять.
  #
  # Ответственность за атомарность/целостность лежит на реализации
  # этих обработчиков. Менеджер не может откатывать частичные эффекты.
  CommandHandler* = proc (cmd: CommandData): bool {.closure, raises: [].}

  CommandExecutor* = object
    applyImpl: CommandHandler
    undoImpl: CommandHandler
    redoImpl: CommandHandler

  UndoEntryKind* = enum
    uekCommand
    uekGroup

  TransactionGroup* = object
    description*: string
    timestamp*: int64
    children*: seq[UndoEntry]

  UndoEntry* = object
    case kind*: UndoEntryKind
    of uekCommand:
      command*: CommandData
    of uekGroup:
      group*: TransactionGroup

  UndoStack* = object
    entries: seq[UndoEntry]

  RedoStack* = object
    entries: seq[UndoEntry]

  UndoRedoManager* = object
    undoStack: UndoStack
    redoStack: RedoStack
    groupStack: seq[TransactionGroup]
    limit: int

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc clampToInt32(v: int64): int32 =
  if v < int64(low(int32)):
    low(int32)
  elif v > int64(high(int32)):
    high(int32)
  else:
    int32(v)

proc clampToUint8(v: int64): uint8 =
  if v <= 0:
    0'u8
  elif v >= int64(high(uint8)):
    high(uint8)
  else:
    uint8(v)

proc clampToUint32(v: int64): uint32 =
  if v <= 0:
    0'u32
  elif v >= int64(high(uint32)):
    high(uint32)
  else:
    uint32(v)

proc entryDescription(entry: UndoEntry): string =
  case entry.kind
  of uekCommand:
    result = entry.command.description
  of uekGroup:
    result = entry.group.description

# ---------------------------------------------------------------------------
# Entry constructors
# ---------------------------------------------------------------------------

proc commandEntry*(cmd: CommandData): UndoEntry =
  UndoEntry(kind: uekCommand, command: cmd)

proc groupEntry*(group: TransactionGroup): UndoEntry =
  UndoEntry(kind: uekGroup, group: group)

# ---------------------------------------------------------------------------
# Stack internals
# ---------------------------------------------------------------------------

proc len*(stack: UndoStack): int =
  stack.entries.len

proc len*(stack: RedoStack): int =
  stack.entries.len

proc isEmpty*(stack: UndoStack): bool =
  stack.entries.len == 0

proc isEmpty*(stack: RedoStack): bool =
  stack.entries.len == 0

proc trim(entries: var seq[UndoEntry], limit: int) =
  if limit <= 0:
    entries.setLen(0)
  elif entries.len > limit:
    let excess = entries.len - limit
    entries.delete(0 ..< excess)

proc trim(stack: var UndoStack, limit: int) =
  trim(stack.entries, limit)

proc trim(stack: var RedoStack, limit: int) =
  trim(stack.entries, limit)

proc push(stack: var UndoStack, entry: UndoEntry, limit: int) =
  stack.entries.add(entry)
  trim(stack.entries, limit)

proc push(stack: var RedoStack, entry: UndoEntry, limit: int) =
  stack.entries.add(entry)
  trim(stack.entries, limit)

proc peek(stack: UndoStack): Option[UndoEntry] =
  if stack.entries.len == 0:
    return none(UndoEntry)
  result = some(stack.entries[stack.entries.high])

proc peek(stack: RedoStack): Option[UndoEntry] =
  if stack.entries.len == 0:
    return none(UndoEntry)
  result = some(stack.entries[stack.entries.high])

proc removeLast(stack: var UndoStack) =
  if stack.entries.len > 0:
    stack.entries.setLen(stack.entries.len - 1)

proc removeLast(stack: var RedoStack) =
  if stack.entries.len > 0:
    stack.entries.setLen(stack.entries.len - 1)

proc clear(stack: var UndoStack) =
  stack.entries.setLen(0)

proc clear(stack: var RedoStack) =
  stack.entries.setLen(0)

# ---------------------------------------------------------------------------
# CommandExecutor
# ---------------------------------------------------------------------------

proc initCommandExecutor*(
    applyImpl: CommandHandler = nil,
    undoImpl: CommandHandler = nil,
    redoImpl: CommandHandler = nil
): CommandExecutor =
  CommandExecutor(
    applyImpl: applyImpl,
    undoImpl: undoImpl,
    redoImpl: redoImpl
  )

proc apply*(executor: CommandExecutor, cmd: CommandData): bool =
  if executor.applyImpl == nil:
    true
  else:
    executor.applyImpl(cmd)

proc undo*(executor: CommandExecutor, cmd: CommandData): bool =
  if executor.undoImpl == nil:
    true
  else:
    executor.undoImpl(cmd)

proc redo*(executor: CommandExecutor, cmd: CommandData): bool =
  if executor.redoImpl != nil:
    executor.redoImpl(cmd)
  elif executor.applyImpl != nil:
    executor.applyImpl(cmd)
  else:
    true

proc apply*(executor: CommandExecutor, entry: UndoEntry): bool =
  case entry.kind
  of uekCommand:
    result = executor.apply(entry.command)
  of uekGroup:
    result = true
    for child in entry.group.children:
      if not executor.apply(child):
        return false

proc undo*(executor: CommandExecutor, entry: UndoEntry): bool =
  case entry.kind
  of uekCommand:
    result = executor.undo(entry.command)
  of uekGroup:
    result = true
    var i = entry.group.children.len - 1
    while i >= 0:
      if not executor.undo(entry.group.children[i]):
        return false
      dec i

proc redo*(executor: CommandExecutor, entry: UndoEntry): bool =
  case entry.kind
  of uekCommand:
    result = executor.redo(entry.command)
  of uekGroup:
    result = true
    for child in entry.group.children:
      if not executor.redo(child):
        return false

# ---------------------------------------------------------------------------
# UndoRedoManager
# ---------------------------------------------------------------------------

proc initUndoRedoManager*(maxSteps: int = MaxUndoSteps): UndoRedoManager =
  result.undoStack = UndoStack(entries: @[])
  result.redoStack = RedoStack(entries: @[])
  result.groupStack = @[]
  result.limit = if maxSteps >= 0: maxSteps else: 0

proc maxSteps*(mgr: UndoRedoManager): int =
  mgr.limit

proc setMaxSteps*(mgr: var UndoRedoManager, steps: int) =
  mgr.limit = if steps >= 0: steps else: 0
  mgr.undoStack.trim(mgr.limit)
  mgr.redoStack.trim(mgr.limit)

proc canUndo*(mgr: UndoRedoManager): bool =
  mgr.undoStack.len > 0

proc canRedo*(mgr: UndoRedoManager): bool =
  mgr.redoStack.len > 0

proc undoLen*(mgr: UndoRedoManager): int =
  mgr.undoStack.len

proc redoLen*(mgr: UndoRedoManager): int =
  mgr.redoStack.len

proc isGrouping*(mgr: UndoRedoManager): bool =
  mgr.groupStack.len > 0

proc groupDepth*(mgr: UndoRedoManager): int =
  mgr.groupStack.len

proc clear*(mgr: var UndoRedoManager) =
  mgr.undoStack.clear()
  mgr.redoStack.clear()
  mgr.groupStack.setLen(0)

proc undoDescription*(mgr: UndoRedoManager): Option[string] =
  let entry = mgr.undoStack.peek()
  if entry.isNone:
    return none(string)
  result = some(entryDescription(entry.get()))

proc redoDescription*(mgr: UndoRedoManager): Option[string] =
  let entry = mgr.redoStack.peek()
  if entry.isNone:
    return none(string)
  result = some(entryDescription(entry.get()))

proc recordCommand(mgr: var UndoRedoManager, cmd: CommandData) =
  let entry = commandEntry(cmd)

  if mgr.groupStack.len > 0:
    mgr.groupStack[mgr.groupStack.high].children.add(entry)
  else:
    mgr.undoStack.push(entry, mgr.limit)

  # Новая редакторская операция инвалидирует redo.
  mgr.redoStack.clear()

proc execute*(
    mgr: var UndoRedoManager,
    executor: CommandExecutor,
    cmd: CommandData
): bool =
  if not executor.apply(cmd):
    return false

  mgr.recordCommand(cmd)
  result = true

proc beginGroup*(mgr: var UndoRedoManager, description: string) =
  mgr.groupStack.add(
    TransactionGroup(
      description: description,
      timestamp: getTime().toUnix(),
      children: @[]
    )
  )

proc endGroup*(mgr: var UndoRedoManager): bool =
  if mgr.groupStack.len == 0:
    return false

  let group = mgr.groupStack.pop()

  # Пустая группа не должна создавать undo-шаг.
  if group.children.len == 0:
    return true

  let entry = groupEntry(group)

  if mgr.groupStack.len > 0:
    # Вложенная группа становится дочерним элементом внешней группы.
    mgr.groupStack[mgr.groupStack.high].children.add(entry)
  else:
    # Корневая группа попадает в обычный undo стек как один шаг.
    mgr.undoStack.push(entry, mgr.limit)

  result = true

proc undo*(mgr: var UndoRedoManager, executor: CommandExecutor): bool =
  # Нельзя делать undo внутри незакрытой группы.
  if mgr.isGrouping():
    return false

  let entryOpt = mgr.undoStack.peek()
  if entryOpt.isNone:
    return false

  let entry = entryOpt.get()

  if not executor.undo(entry):
    return false

  mgr.undoStack.removeLast()
  mgr.redoStack.push(entry, mgr.limit)
  result = true

proc redo*(mgr: var UndoRedoManager, executor: CommandExecutor): bool =
  # Нельзя делать redo внутри незакрытой группы.
  if mgr.isGrouping():
    return false

  let entryOpt = mgr.redoStack.peek()
  if entryOpt.isNone:
    return false

  let entry = entryOpt.get()

  if not executor.redo(entry):
    return false

  mgr.redoStack.removeLast()
  mgr.undoStack.push(entry, mgr.limit)
  result = true

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------

proc getStringField(j: JsonNode, key: string, default: string = ""): string =
  if j.kind != JObject or not j.hasKey(key):
    return default

  let v = j[key]
  if v.isNil or v.kind != JString:
    return default

  result = v.getStr()

proc getIntField(j: JsonNode, key: string, default: int64 = 0): int64 =
  if j.kind != JObject or not j.hasKey(key):
    return default

  let v = j[key]
  if v.isNil:
    return default

  case v.kind
  of JInt:
    result = v.getBiggestInt()
  of JFloat:
    result = int64(v.getFloat())
  else:
    result = default

proc getFloatField(
    j: JsonNode,
    key: string,
    default: float32 = 0.0'f32
): float32 =
  if j.kind != JObject or not j.hasKey(key):
    return default

  let v = j[key]
  if v.isNil:
    return default

  case v.kind
  of JFloat:
    result = float32(v.getFloat())
  of JInt:
    result = float32(v.getBiggestInt())
  else:
    result = default

proc commandToJson(cmd: CommandData): JsonNode =
  result = newJObject()
  result["type"] = %BiggestInt(ord(cmd.commandType))
  result["timestamp"] = %cmd.timestamp
  result["description"] = %cmd.description

  result["nodeId"] = %cmd.nodeId
  result["nodeType"] = %cmd.nodeType
  result["posX"] = %float(cmd.posX)
  result["posY"] = %float(cmd.posY)

  result["srcNodeId"] = %cmd.srcNodeId
  result["srcPort"] = %cmd.srcPort
  result["dstNodeId"] = %cmd.dstNodeId
  result["dstPort"] = %cmd.dstPort
  result["sigType"] = %cmd.sigType

  result["trackId"] = %cmd.trackId
  result["clipId"] = %cmd.clipId
  result["startTick"] = %cmd.startTick
  result["duration"] = %cmd.duration
  result["pitch"] = %BiggestInt(cmd.pitch)
  result["velocity"] = %BiggestInt(cmd.velocity)

  result["paramId"] = %BiggestInt(cmd.paramId)
  result["oldValue"] = %float(cmd.oldValue)
  result["newValue"] = %float(cmd.newValue)
  result["blob"] = %cmd.blob

  var intArr = newJArray()
  for v in cmd.intData:
    intArr.add(%v)
  result["intData"] = intArr

  var floatArr = newJArray()
  for v in cmd.floatData:
    floatArr.add(%float(v))
  result["floatData"] = floatArr

  var strArr = newJArray()
  for v in cmd.strData:
    strArr.add(%v)
  result["strData"] = strArr

proc commandFromJson(j: JsonNode): Option[CommandData] =
  if j.isNil or j.kind != JObject:
    return none(CommandData)

  if not j.hasKey("type"):
    return none(CommandData)

  let typeVal = getIntField(j, "type", -1)
  if typeVal < int64(ord(low(CommandType))) or
     typeVal > int64(ord(high(CommandType))):
    return none(CommandData)

  var cmd = CommandData()
  cmd.commandType = CommandType(int(typeVal))
  cmd.timestamp = getIntField(j, "timestamp", 0)
  cmd.description = getStringField(j, "description", "")

  cmd.nodeId = clampToInt32(getIntField(j, "nodeId", 0))
  cmd.nodeType = clampToInt32(getIntField(j, "nodeType", 0))
  cmd.posX = getFloatField(j, "posX", 0.0'f32)
  cmd.posY = getFloatField(j, "posY", 0.0'f32)

  cmd.srcNodeId = clampToInt32(getIntField(j, "srcNodeId", 0))
  cmd.srcPort = clampToInt32(getIntField(j, "srcPort", 0))
  cmd.dstNodeId = clampToInt32(getIntField(j, "dstNodeId", 0))
  cmd.dstPort = clampToInt32(getIntField(j, "dstPort", 0))
  cmd.sigType = clampToInt32(getIntField(j, "sigType", 0))

  cmd.trackId = clampToInt32(getIntField(j, "trackId", 0))
  cmd.clipId = clampToInt32(getIntField(j, "clipId", 0))
  cmd.startTick = clampToInt32(getIntField(j, "startTick", 0))
  cmd.duration = clampToInt32(getIntField(j, "duration", 0))
  cmd.pitch = clampToUint8(getIntField(j, "pitch", 0))
  cmd.velocity = clampToUint8(getIntField(j, "velocity", 0))

  cmd.paramId = clampToUint32(getIntField(j, "paramId", 0))
  cmd.oldValue = getFloatField(j, "oldValue", 0.0'f32)
  cmd.newValue = getFloatField(j, "newValue", 0.0'f32)
  cmd.blob = getStringField(j, "blob", "")

  if j.hasKey("intData"):
    let arr = j["intData"]
    if not arr.isNil and arr.kind == JArray:
      let n = min(arr.len, cmd.intData.len)
      for idx in 0 ..< n:
        let v = arr[idx]
        if v.isNil or v.kind == JNull:
          continue

        if v.kind == JInt:
          cmd.intData[idx] = v.getBiggestInt()
        elif v.kind == JFloat:
          cmd.intData[idx] = int64(v.getFloat())

  if j.hasKey("floatData"):
    let arr = j["floatData"]
    if not arr.isNil and arr.kind == JArray:
      let n = min(arr.len, cmd.floatData.len)
      for idx in 0 ..< n:
        let v = arr[idx]
        if v.isNil or v.kind == JNull:
          continue

        if v.kind == JFloat:
          cmd.floatData[idx] = float32(v.getFloat())
        elif v.kind == JInt:
          cmd.floatData[idx] = float32(v.getBiggestInt())

  if j.hasKey("strData"):
    let arr = j["strData"]
    if not arr.isNil and arr.kind == JArray:
      let n = min(arr.len, cmd.strData.len)
      for idx in 0 ..< n:
        let v = arr[idx]
        if v.isNil or v.kind == JNull:
          continue

        if v.kind == JString:
          cmd.strData[idx] = v.getStr()

  result = some(cmd)

# Mutual recursion: entry <-> group.
proc entryToJson(entry: UndoEntry): JsonNode
proc groupToJson(group: TransactionGroup): JsonNode

proc groupToJson(group: TransactionGroup): JsonNode =
  result = newJObject()
  result["description"] = %group.description
  result["timestamp"] = %group.timestamp

  var children = newJArray()
  for child in group.children:
    children.add(entryToJson(child))

  result["children"] = children

proc entryToJson(entry: UndoEntry): JsonNode =
  result = newJObject()
  result["kind"] = %BiggestInt(ord(entry.kind))

  case entry.kind
  of uekCommand:
    result["command"] = commandToJson(entry.command)
  of uekGroup:
    result["group"] = groupToJson(entry.group)

proc entryFromJson(j: JsonNode): Option[UndoEntry]
proc groupFromJson(j: JsonNode): Option[TransactionGroup]

proc groupFromJson(j: JsonNode): Option[TransactionGroup] =
  if j.isNil or j.kind != JObject:
    return none(TransactionGroup)

  var group = TransactionGroup(
    description: getStringField(j, "description", ""),
    timestamp: getIntField(j, "timestamp", 0),
    children: @[]
  )

  if j.hasKey("children"):
    let children = j["children"]
    if not children.isNil and children.kind == JArray:
      for idx in 0 ..< children.len:
        let childJson = children[idx]
        let child = entryFromJson(childJson)
        if child.isNone:
          return none(TransactionGroup)
        group.children.add(child.get())

  result = some(group)

proc entryFromJson(j: JsonNode): Option[UndoEntry] =
  if j.isNil or j.kind != JObject:
    return none(UndoEntry)

  # Новый формат:
  #
  # {
  #   "kind": 0,
  #   "command": {...}
  # }
  #
  # или
  #
  # {
  #   "kind": 1,
  #   "group": {...}
  # }
  if j.hasKey("kind"):
    let kindVal = getIntField(j, "kind", -1)

    if kindVal == int64(ord(uekCommand)):
      if not j.hasKey("command"):
        return none(UndoEntry)

      let cmd = commandFromJson(j["command"])
      if cmd.isNone:
        return none(UndoEntry)

      return some(commandEntry(cmd.get()))

    elif kindVal == int64(ord(uekGroup)):
      if not j.hasKey("group"):
        return none(UndoEntry)

      let group = groupFromJson(j["group"])
      if group.isNone:
        return none(UndoEntry)

      return some(groupEntry(group.get()))

    else:
      return none(UndoEntry)

  # Старый формат:
  #
  # {
  #   "data": {...},
  #   "children": [ {...}, {...} ]
  # }
  if j.hasKey("data"):
    let cmdOpt = commandFromJson(j["data"])
    if cmdOpt.isNone:
      return none(UndoEntry)

    let cmd = cmdOpt.get()

    if j.hasKey("children"):
      let children = j["children"]

      if not children.isNil and
         children.kind == JArray and
         children.len > 0:
        var group = TransactionGroup(
          description: cmd.description,
          timestamp: cmd.timestamp,
          children: @[]
        )

        for idx in 0 ..< children.len:
          let childJson = children[idx]
          let childCmd = commandFromJson(childJson)
          if childCmd.isNone:
            return none(UndoEntry)

          group.children.add(commandEntry(childCmd.get()))

        return some(groupEntry(group))

    return some(commandEntry(cmd))

  # Дополнительный совместимый fallback: команда прямо в объекте.
  if j.hasKey("type"):
    let cmd = commandFromJson(j)
    if cmd.isSome:
      return some(commandEntry(cmd.get()))

  result = none(UndoEntry)

# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

proc saveUndoHistory*(mgr: UndoRedoManager, filepath: string): bool =
  var root = newJObject()
  root["version"] = %UndoHistoryVersion
  root["timestamp"] = %getTime().toUnix()
  root["maxSteps"] = %mgr.limit

  var undoArr = newJArray()
  for entry in mgr.undoStack.entries:
    undoArr.add(entryToJson(entry))
  root["undoStack"] = undoArr

  var redoArr = newJArray()
  for entry in mgr.redoStack.entries:
    redoArr.add(entryToJson(entry))
  root["redoStack"] = redoArr

  try:
    writeFile(filepath, pretty(root))
    result = true
  except CatchableError:
    result = false

proc loadUndoHistory*(mgr: var UndoRedoManager, filepath: string): bool =
  if not fileExists(filepath):
    return false

  try:
    let root = parseJson(readFile(filepath))
    if root.kind != JObject:
      return false

    let version = getIntField(root, "version", 0)
    if version > UndoHistoryVersion:
      return false

    mgr.clear()

    if root.hasKey("undoStack"):
      let undoArr = root["undoStack"]
      if not undoArr.isNil and undoArr.kind == JArray:
        for idx in 0 ..< undoArr.len:
          let entry = entryFromJson(undoArr[idx])
          if entry.isSome:
            mgr.undoStack.entries.add(entry.get())

    if root.hasKey("redoStack"):
      let redoArr = root["redoStack"]
      if not redoArr.isNil and redoArr.kind == JArray:
        for idx in 0 ..< redoArr.len:
          let entry = entryFromJson(redoArr[idx])
          if entry.isSome:
            mgr.redoStack.entries.add(entry.get())

    # Важно: лимит применяется и после загрузки.
    mgr.undoStack.trim(mgr.limit)
    mgr.redoStack.trim(mgr.limit)

    result = true
  except CatchableError:
    result = false

# ---------------------------------------------------------------------------
# Command factories
# ---------------------------------------------------------------------------

proc cmdAddNode*(
    nodeId: int32,
    nodeType: int32,
    posX, posY: float32,
    desc: string = "Add Node"
): CommandData =
  CommandData(
    commandType: ctAddNode,
    timestamp: getTime().toUnix(),
    description: desc,
    nodeId: nodeId,
    nodeType: nodeType,
    posX: posX,
    posY: posY
  )

proc cmdRemoveNode*(
    nodeId: int32,
    desc: string = "Remove Node"
): CommandData =
  CommandData(
    commandType: ctRemoveNode,
    timestamp: getTime().toUnix(),
    description: desc,
    nodeId: nodeId
  )

proc cmdMoveNode*(
    nodeId: int32,
    oldX, oldY, newX, newY: float32,
    desc: string = "Move Node"
): CommandData =
  result = CommandData(
    commandType: ctMoveNode,
    timestamp: getTime().toUnix(),
    description: desc,
    nodeId: nodeId,
    posX: newX,
    posY: newY
  )

  # Старая позиция сохраняется в floatData, чтобы undo мог восстановить её.
  result.floatData[0] = oldX
  result.floatData[1] = oldY

proc cmdAddConnection*(
    srcNode, srcPort, dstNode, dstPort: int32,
    sigType: int32
): CommandData =
  CommandData(
    commandType: ctAddConnection,
    timestamp: getTime().toUnix(),
    description: "Add Connection",
    srcNodeId: srcNode,
    srcPort: srcPort,
    dstNodeId: dstNode,
    dstPort: dstPort,
    sigType: sigType
  )

proc cmdRemoveConnection*(
    srcNode, srcPort, dstNode, dstPort: int32
): CommandData =
  CommandData(
    commandType: ctRemoveConnection,
    timestamp: getTime().toUnix(),
    description: "Remove Connection",
    srcNodeId: srcNode,
    srcPort: srcPort,
    dstNodeId: dstNode,
    dstPort: dstPort
  )

proc cmdAddNote*(
    trackId, clipId, startTick, duration: int32,
    pitch, velocity: uint8
): CommandData =
  CommandData(
    commandType: ctAddNote,
    timestamp: getTime().toUnix(),
    description: "Add Note",
    trackId: trackId,
    clipId: clipId,
    startTick: startTick,
    duration: duration,
    pitch: pitch,
    velocity: velocity
  )

proc cmdRemoveNote*(
    trackId, clipId, startTick, duration: int32,
    pitch, velocity: uint8
): CommandData =
  CommandData(
    commandType: ctRemoveNote,
    timestamp: getTime().toUnix(),
    description: "Remove Note",
    trackId: trackId,
    clipId: clipId,
    startTick: startTick,
    duration: duration,
    pitch: pitch,
    velocity: velocity
  )

proc cmdChangeParam*(
    nodeId: int32,
    paramId: uint32,
    oldVal, newVal: float32
): CommandData =
  CommandData(
    commandType: ctChangeParameter,
    timestamp: getTime().toUnix(),
    description: "Change Parameter",
    nodeId: nodeId,
    paramId: paramId,
    oldValue: oldVal,
    newValue: newVal
  )