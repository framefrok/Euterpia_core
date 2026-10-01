# nodes/sdk/node_registry.nim
#
# Реестр типов нод. Нужен ровно для одной вещи: превратить строку
# "gain" из файла проекта или команды CLI в живой EditorNode.
#
# Core о существовании этого реестра НЕ знает (MANIFEST §54):
# ядро оперирует готовым графом, список нод — свойство верхнего слоя.
#
# Потокобезопасность: реестр принадлежит control plane. Регистрация
# происходит при старте приложения или при загрузке плагина, до того
# как audio thread начнёт рендерить. В audio thread реестр только читается
# (и то редко: обычно состояние уже создано и лежит в userData).

import
  graph_compiler,
  node_api

type
  NodeTypeEntry* = object
    ## Запись реестра. Указатели статичны: descriptor и фабрика живут
    ## столько же, сколько сам тип ноды.
    desc*: ptr NodeDesc
    factory*: ptr NodeFactory

  NodeRegistry* = object
    entries*: seq[NodeTypeEntry]

proc initNodeRegistry*(): NodeRegistry =
  result.entries = @[]

proc registerNodeType*(reg: var NodeRegistry; desc: ptr NodeDesc;
                       factory: ptr NodeFactory): bool =
  ## Возвращает false, если тип с таким id уже зарегистрирован:
  ## молча перетирать тип нельзя, это делает проект невоспроизводимым.
  if desc.isNil or factory.isNil:
    return false

  if factory.create.isNil or factory.destroy.isNil or factory.process.isNil:
    return false

  let id = readFixed(desc.id)
  if id.len == 0:
    return false

  for e in reg.entries:
    if readFixed(e.desc.id) == id:
      return false

  desc.structSize = uint32(sizeof(NodeDesc))
  desc.apiVersion = NodeApiVersion

  reg.entries.add NodeTypeEntry(desc: desc, factory: factory)
  true

proc findNodeType*(reg: NodeRegistry; typeId: string): ptr NodeTypeEntry =
  for i in 0 ..< reg.entries.len:
    if readFixed(reg.entries[i].desc.id) == typeId:
      return addr reg.entries[i]
  return nil

proc count*(reg: NodeRegistry): int {.inline.} = reg.entries.len

iterator items*(reg: NodeRegistry): NodeTypeEntry =
  ## Обход реестра. Холодная сторона: CLI --json node list, Editor,
  ## валидация проекта при загрузке.
  for entry in reg.entries:
    yield entry

proc instantiateNode*(reg: NodeRegistry; typeId: string; nodeId: int;
                      outNode: var EditorNode): bool =
  ## Создаёт состояние ноды и заполняет outNode.
  ## Владение состоянием переходит к вызывающему: он обязан вызвать
  ## destroyNodeState, когда нода удаляется из проекта.
  let entry = reg.findNodeType(typeId)
  if entry.isNil:
    return false

  let state = entry.factory.create(entry.desc, nil)
  if state.isNil:
    return false

  outNode = makeEditorNode(entry.desc, entry.factory, nodeId, state)
  true

proc destroyNodeState*(entry: ptr NodeTypeEntry; state: pointer) {.inline.} =
  if entry.isNil or entry.factory.isNil or state.isNil:
    return
  entry.factory.destroy(state)
