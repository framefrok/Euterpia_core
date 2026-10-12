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
    ## Запись реестра. Хранится в ref (issue #388, EUT-NEW-015): указатель
    ## на запись стабилен при росте реестра — раньше `seq[NodeTypeEntry]`
    ## мог переаллоцироваться при `add`, и ранее выданный
    ## `ptr NodeTypeEntry` становился висячим, вопреки комментарию о
    ## стабильности. descriptor и фабрика по-прежнему живут столько же,
    ## сколько сам тип ноды (статические объекты вызывающего).
    desc*: ptr NodeDesc
    factory*: ptr NodeFactory

  NodeRegistry* = object
    entries*: seq[ref NodeTypeEntry]

proc initNodeRegistry*(): NodeRegistry =
  result.entries = @[]

proc registerNodeType*(reg: var NodeRegistry; desc: ptr NodeDesc;
                       factory: ptr NodeFactory;
                       err: var string): bool =
  ## Регистрирует тип ноды. Возвращает false и заполняет err причиной.
  ##
  ## Порядок проверок — часть контракта (issue #388, EUT-NEW-016):
  ##   1. nil-проверки и полнота фабрики — трогаем только наши указатели;
  ##   2. сверка structSize/apiVersion ДО записи в структуру: для чужого
  ##      или старого дескриптора (меньший structSize, другая версия API)
  ##      запись наших полей вышла бы за пределы чужой памяти;
  ##   3. структурный gate (`validateNodeDesc`): порты, параметры, диапазоны
  ##      (EUT-NEW-017) — дескриптор с audioOutCount=100 не должен попасть
  ##      в пайплайн с фиксированными массивами портов;
  ##   4. только после всех проверок — запись ABI-полей и добавление.
  ##
  ## Дубликат id отклоняется: молча перетирать тип нельзя — проект становится
  ## невоспроизводимым.
  err = ""

  if desc.isNil:
    err = "дескриптор nil"
    return false

  if factory.isNil or factory.create.isNil or factory.destroy.isNil or
     factory.process.isNil:
    err = "фабрика неполна: нужны create/destroy/process"
    return false

  # EUT-NEW-016: ABI-поля перезаписываются ТОЛЬКО после сверки. Ноль означает
  # «наш свежий дескриптор, поля ещё не проставлены».
  if desc.structSize != 0 and
     desc.structSize != uint32(sizeof(NodeDesc)):
    err = "чужой или устаревший дескриптор: structSize=" & $desc.structSize &
          ", ядро ждёт " & $sizeof(NodeDesc)
    return false

  if desc.apiVersion != 0 and desc.apiVersion != NodeApiVersion:
    err = "несовместимая версия Node API: " & $desc.apiVersion &
          ", ядро ждёт " & $NodeApiVersion
    return false

  let id = readFixed(desc.id)
  if id.len == 0:
    err = "пустой id ноды"
    return false

  for e in reg.entries:
    if readFixed(e.desc.id) == id:
      err = "тип ноды уже зарегистрирован: " & id
      return false

  let structErr = validateNodeDesc(desc)
  if structErr.len > 0:
    err = structErr
    return false

  desc.structSize = uint32(sizeof(NodeDesc))
  desc.apiVersion = NodeApiVersion

  var entry = new NodeTypeEntry
  entry.desc = desc
  entry.factory = factory
  reg.entries.add entry
  true

proc registerNodeType*(reg: var NodeRegistry; desc: ptr NodeDesc;
                       factory: ptr NodeFactory): bool =
  ## Тот же контракт, но причина отказа недоступна вызывающему.
  ## Новые вызывающие должны предпочесть вариант с `err`: реестр перестал
  ## отвечать одним «false» на любую причину (issue #388).
  var ignored = ""
  registerNodeType(reg, desc, factory, ignored)

proc findNodeType*(reg: NodeRegistry; typeId: string): ptr NodeTypeEntry =
  ## Указатель стабилен, пока жив реестр: запись лежит в ref-объекте, а не
  ## в теле переаллоцируемого seq (issue #388, EUT-NEW-015).
  for e in reg.entries:
    if readFixed(e.desc.id) == typeId:
      return cast[ptr NodeTypeEntry](e)
  return nil

proc count*(reg: NodeRegistry): int {.inline.} = reg.entries.len

iterator items*(reg: NodeRegistry): NodeTypeEntry =
  ## Обход реестра. Холодная сторона: CLI --json node list, Editor,
  ## валидация проекта при загрузке.
  for entry in reg.entries:
    yield entry[]

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
