# tests/unit/test_node_registry.nim
#
# Реестр типов нод (issue #388, EUT-NEW-015/016/017):
#   - указатель на запись реестра стабилен при росте реестра;
#   - чужой/старый дескриптор отклоняется ДО записи ABI-полей;
#   - структурный gate: порты, параметры, диапазоны.

import std/[strutils, unittest]
import node_interface
import sdk/node_api
import sdk/node_registry
import builtin/builtin_registry

var
  gFakeFactory: NodeFactory
  gDescs: array[64, NodeDesc]
    ## Стабильный пул дескрипторов: addr валиден, пока живёт процесс,
    ## в отличие от seq, который переаллоцировался бы при росте.
  gDescCount = 0

# Фиктивная фабрика: реестр требует только непустых create/destroy/process.
proc fakeCreate(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard desc
  discard userData
  cast[pointer](0x1)

proc fakeDestroy(state: pointer) {.cdecl, raises: [], gcsafe.} =
  discard state

proc fakeProcess(ctx: ptr NodeProcessContext; audio: ptr NodeAudioPorts;
                 ctrl: ptr NodeControlPorts; events: ptr NodeEventPorts;
                 userData: pointer) {.cdecl, raises: [], gcsafe.} =
  discard ctx
  discard audio
  discard ctrl
  discard events
  discard userData

proc fakeFactory(): ptr NodeFactory =
  ## Адресация через глобальную переменную: ptr должен жить дольше вызова.
  gFakeFactory = NodeFactory(create: fakeCreate, destroy: fakeDestroy,
                             process: fakeProcess)
  addr gFakeFactory

proc testDesc(id: string; audioOut: int32 = 1): ptr NodeDesc =
  ## Свежий дескриптор в пуле (structSize/apiVersion == 0 — «наш»).
  doAssert gDescCount < gDescs.len
  gDescs[gDescCount] = NodeDesc(
    id: fixedId(id), name: fixedName(id), category: fixedName("test"),
    audioInCount: 0, audioOutCount: audioOut, latencyFrames: 0,
    maxChannels: 2, paramCount: 0)
  result = addr gDescs[gDescCount]
  inc gDescCount

suite "SDK: реестр типов нод (#388)":
  test "регистрация N+1 типов не инвалидирует ранее выданный ptr":
    var reg = initNodeRegistry()
    check registerBuiltinNodes(reg) == BuiltinCount

    # Указатель на первую запись — ДО дальнейших регистраций.
    let first = reg.findNodeType("euterpia.input")
    check not first.isNil
    let firstDescId = readFixed(first.desc.id)
    check firstDescId == "euterpia.input"

    # Рост реестра после выдачи указателя: раньше seq[NodeTypeEntry]
    # переаллоцировался, и `first` указывал в освобождённую память.
    check reg.registerNodeType(testDesc("test.tail"), fakeFactory())
    check reg.registerNodeType(testDesc("test.tail2"), fakeFactory())

    let firstAfter = reg.findNodeType("euterpia.input")
    check not firstAfter.isNil
    check readFixed(firstAfter.desc.id) == firstDescId
    check firstAfter.desc == first.desc
    check firstAfter.factory == first.factory

  test "дескриптор с audioOutCount=100 отклоняется с внятной ошибкой":
    var reg = initNodeRegistry()
    let desc = testDesc("test.toowide", audioOut = 100)
    var err = ""
    check not reg.registerNodeType(desc, fakeFactory(), err)
    check "audioOutCount" in err
    check err.contains("100")
    # Отклонённый тип не появился в реестре.
    check reg.findNodeType("test.toowide").isNil
    check reg.count == 0

  test "чужой structSize отклоняется и НЕ перезаписывается":
    var reg = initNodeRegistry()
    let desc = testDesc("test.foreign")
    # Чужой/старый ABI: заявлен меньший размер структуры. Раньше ядро
    # перезаписывало structSize/apiVersion ДО всякой проверки.
    desc.structSize = 4'u32
    desc.apiVersion = 0'u32
    var err = ""
    check not reg.registerNodeType(desc, fakeFactory(), err)
    check err.contains("structSize")
    # Ни одного поля ABI не записано: память чужого дескриптора не тронута.
    check desc.structSize == 4'u32
    check desc.apiVersion == 0'u32

  test "несовместимая версия Node API отклоняется до записи":
    var reg = initNodeRegistry()
    let desc = testDesc("test.oldapi")
    desc.structSize = 0'u32
    desc.apiVersion = NodeApiVersion + 1
    var err = ""
    check not reg.registerNodeType(desc, fakeFactory(), err)
    check err.contains("Node API")
    check desc.apiVersion == NodeApiVersion + 1   # не перезаписана

  test "структурный gate: параметры с default вне диапазона отклоняются":
    var reg = initNodeRegistry()
    let desc = testDesc("test.badrange")
    desc.paramCount = 1
    desc.params[0] = NodeParamDesc(
      id: 7'u32, name: fixedParamName("gain"),
      minValue: 0.0f, maxValue: 1.0f, defaultValue: 2.0f, step: 0.1f)
    var err = ""
    check not reg.registerNodeType(desc, fakeFactory(), err)
    check err.contains("gain")
    check err.contains("default")

  test "структурный gate: step <= 0 и дубликат paramId отклоняются":
    var reg = initNodeRegistry()

    let badStep = testDesc("test.badstep")
    badStep.paramCount = 1
    badStep.params[0] = NodeParamDesc(
      id: 1'u32, name: fixedParamName("p"),
      minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.5f, step: 0.0f)
    var err = ""
    check not reg.registerNodeType(badStep, fakeFactory(), err)
    check err.contains("step")

    let dupParam = testDesc("test.dupparam")
    dupParam.paramCount = 2
    dupParam.params[0] = NodeParamDesc(
      id: 3'u32, name: fixedParamName("a"),
      minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.5f, step: 0.1f)
    dupParam.params[1] = NodeParamDesc(
      id: 3'u32, name: fixedParamName("b"),
      minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.5f, step: 0.1f)
    check not reg.registerNodeType(dupParam, fakeFactory(), err)
    check err.contains("повторно")

  test "отрицательная latency отклоняется":
    var reg = initNodeRegistry()
    let desc = testDesc("test.neglatency")
    desc.latencyFrames = -5
    var err = ""
    check not reg.registerNodeType(desc, fakeFactory(), err)
    check err.contains("latencyFrames")

  test "повтор id отклоняется с причиной, а не молча":
    var reg = initNodeRegistry()
    check reg.registerNodeType(testDesc("test.dup"), fakeFactory())
    var err = ""
    check not reg.registerNodeType(testDesc("test.dup"), fakeFactory(), err)
    check err.contains("уже зарегистрирован")
    check reg.count == 1

  test "успешная регистрация проставляет ABI-поля и заводит запись":
    var reg = initNodeRegistry()
    let desc = testDesc("test.ok")
    var err = ""
    check reg.registerNodeType(desc, fakeFactory(), err)
    check err.len == 0
    check desc.structSize == uint32(sizeof(NodeDesc))
    check desc.apiVersion == NodeApiVersion
    check reg.count == 1
    let found = reg.findNodeType("test.ok")
    check not found.isNil
    check found.desc == desc


