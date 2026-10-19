# nodes/sdk/pipeline_builder.nim
#
# Сборка рабочего пайплайна из графа: компиляция + привязка мастер-выхода
# к буферу аудиодрайвера + маршрутизация параметров по nodeId.
#
# Почему это в Nodes, а не в Core:
#   Core знает, как скомпилировать граф в шаги пайплайна, но не знает,
#   какой нод считается мастером — это политика проекта, а не свойство
#   ядра (MANIFEST §54, §95). Здесь эта политика и живёт.
#
# Владение памятью:
#   - binding выделяется здесь и хранится в CompiledPipeline.userData;
#   - освобождается автоматически через CompiledPipeline.destroyProc,
#     то есть обычный destroyPipeline() из Core освобождает всё.
#
# Потокобезопасность: сборка — только холодная сторона. После сборки
# в audio thread работают только bindMasterProc и applyParamProc.

import std/tables
import
  signal_types,
  node_interface,
  graph_compiler,
  compiled_pipeline,
  node_api,
  node_registry

{.push raises: [].}

type
  PipelineBinding* = object
    # Всё, что ядру не нужно знать, но без чего пайплайн не звучит.
    # Лежит в CompiledPipeline.userData.

    # Привязанный мастер-буфер. Живёт здесь, а не в стеке bindMasterProc:
    # порт ноды хранит указатель на структуру, значит она обязана
    # пережить вызов.
    masterOut: AudioBuffer

    masterStep: int32

    # Таблица «nodeId -> состояние ноды». Нужна, потому что
    # PipelineStep не хранит nodeId: ядро не знает про идентификаторы
    # нод, а applyParamProc в Audio Engine приходит именно с nodeId.
    nodeIds: ptr UncheckedArray[int32]
    states: ptr UncheckedArray[pointer]
    descs: ptr UncheckedArray[ptr NodeDesc]
    factories: ptr UncheckedArray[ptr NodeFactory]
    count: int32

proc destroyBinding(p: ptr CompiledPipeline) {.cdecl, raises: [], gcsafe.} =
  if p.isNil:
    return
  let b = cast[ptr PipelineBinding](p.userData)
  if b.isNil:
    return

  if not b.nodeIds.isNil: deallocShared(b.nodeIds)
  if not b.states.isNil: deallocShared(b.states)
  if not b.descs.isNil: deallocShared(b.descs)
  if not b.factories.isNil: deallocShared(b.factories)
  deallocShared(b)
  p.userData = nil

proc bindMasterProc(p: ptr CompiledPipeline; outBuf: ptr UncheckedArray[float32];
                    frames: int32) {.cdecl, raises: [].} =
  ## Вызывается Audio Engine перед каждым блоком.
  ##
  ## Привязывает выход мастер-ноды прямо к буферу драйвера (zero-copy).
  ##
  ## Раскладка драйверного буфера — INTERLEAVED stereo. Это кодируется
  ## шагом между каналами: stride = 1 (соседние каналы лежат подряд).
  ## Раньше здесь стояло stride = frames, а это для аудио-буферов означает
  ## planar (см. nodes/sdk/audio_buffers.isPlanar: planar при stride >= frames),
  ## из-за чего мастер писал L в первую половину буфера, а R во вторую —
  ## то есть отдавал драйверу planar-раскладку вместо interleaved.
  let b = cast[ptr PipelineBinding](p.userData)
  if b.isNil or p.steps.isNil:
    return

  let step = addr p.steps[b.masterStep]
  if step.audio.outputCount < 1:
    return

  b.masterOut.data = cast[ptr UncheckedArray[float32]](outBuf)
  b.masterOut.channels = signal_types.MaxAudioChannels
  b.masterOut.frames = frames
  b.masterOut.stride = 1
  b.masterOut.layout = alInterleaved
  step.audio.outputs[0] = addr b.masterOut

proc applyParamProc(p: ptr CompiledPipeline; nodeId: int32; paramId: uint32;
                    value: float32; normalized: bool) {.cdecl, raises: [].} =
  let b = cast[ptr PipelineBinding](p.userData)
  if b.isNil:
    return

  var i: int32 = 0
  while i < b.count:
    if b.nodeIds[i] == nodeId:
      let desc = b.descs[i]
      let factory = b.factories[i]
      let state = b.states[i]
      if state.isNil or desc.isNil or factory.isNil:
        return
      if factory.setParam.isNil:
        return
      # Нормализацию делаем здесь: нода получает всегда абсолютное
      # значение в единицах ноды, независимо от того, откуда пришла
      # команда (CLI, автоматизация или UI).
      let v =
        if normalized: desc[].paramFromNormalized(paramId, value) else: value
      factory.setParam(state, paramId, v, false)
      return
    inc i

proc channelsSupported*(desc: ptr NodeDesc): bool {.inline.} =
  ## Укладывается ли обещание ноды в модель каналов ядра (issue #401).
  ##
  ## `maxChannels <= 0` — «нода не заявляет ширину» (например, чисто
  ## событийная). Всё, что больше `MaxAudioChannels`, runtime исполнить не
  ## может: арена, PDC и мастер-выход — стерео. Молча свести такую ноду к
  ## двум каналам означало бы соврать API.
  desc.isNil or desc.maxChannels <= signal_types.MaxAudioChannels

proc validateChannelModel*(reg: var NodeRegistry; g: NodeGraph;
                           offender: var string): bool =
  ## Проверяет, что все типы графа помещаются в стерео-модель Core.
  ##
  ## Это часть контракта SDK, а не «диагностика»: `buildPipeline` вызывает
  ## проверку до компиляции и возвращает false, если нода обещает больше
  ## каналов, чем умеет ядро. `offender` — id типа, чтобы вызывающий мог
  ## объяснить отказ, а не просто получить «не собралось».
  offender = ""
  for _, node in g.nodes:
    let entry = reg.findNodeType(node.nodeType)
    if entry.isNil:
      continue
    if not channelsSupported(entry.desc):
      offender = node.nodeType
      return false
  true

proc buildPipeline*(reg: var NodeRegistry; g: var NodeGraph;
                    masterNodeId: int;
                    cr: var CompileResult;
                    binding: out ptr PipelineBinding): bool =
  ## Компилирует граф и делает его пригодным для Audio Engine.
  ##
  ## masterNodeId — нод, чей выход идёт в аудиодрайвер. Он обязан быть
  ## последним в топологическом порядке (то есть не иметь исходящих связей).
  ##
  ## Возвращает false, если граф не скомпилировался, мастер-нода не
  ## найдена или состояния нод не совпали с порядком шагов.
  binding = nil

  # issue #401: Core v0.x — стерео. Нода, обещающая больше каналов, чем
  # умеет runtime, отвергается здесь, до аллокаций пайплайна: иначе API
  # продолжал бы обещать N каналов, а граф молча работал бы с двумя.
  var offender = ""
  if not validateChannelModel(reg, g, offender):
    return false

  cr = compileGraph(g)
  if not cr.success:
    return false

  let p = cr.pipeline
  if p.isNil or p.steps.isNil or p.stepCount <= 0:
    destroyPipeline(p)
    return false

  # --- Считаем размеры таблиц по числу нод графа ----------------------------
  let nodeCount = g.nodes.len
  if nodeCount <= 0:
    destroyPipeline(p)
    return false

  var masterState: pointer = nil

  binding = cast[ptr PipelineBinding](allocShared0(sizeof(PipelineBinding)))
  if binding.isNil:
    destroyPipeline(p)
    return false

  binding.nodeIds = cast[ptr UncheckedArray[int32]](allocShared0(sizeof(int32) * nodeCount))
  binding.states = cast[ptr UncheckedArray[pointer]](allocShared0(sizeof(pointer) * nodeCount))
  binding.descs = cast[ptr UncheckedArray[ptr NodeDesc]](allocShared0(sizeof(ptr NodeDesc) * nodeCount))
  binding.factories = cast[ptr UncheckedArray[ptr NodeFactory]](allocShared0(sizeof(ptr NodeFactory) * nodeCount))

  if binding.nodeIds.isNil or binding.states.isNil or
     binding.descs.isNil or binding.factories.isNil:
    destroyBinding(p)
    destroyPipeline(p)
    binding = nil
    return false

  for id, node in g.nodes:
    if binding.count >= nodeCount.int32:
      break
    let entry = reg.findNodeType(node.nodeType)
    binding.nodeIds[binding.count] = id.int32
    binding.states[binding.count] = node.userData
    binding.descs[binding.count] = if entry.isNil: nil else: entry.desc
    binding.factories[binding.count] = if entry.isNil: nil else: entry.factory
    inc binding.count

    if id == masterNodeId:
      masterState = node.userData

  if masterState.isNil:
    destroyBinding(p)
    destroyPipeline(p)
    binding = nil
    return false

  # --- Ищем шаг мастер-ноды -------------------------------------------------
  # Шаги идут в топологическом порядке, но nodeId в PipelineStep нет,
  # поэтому шаг находим по указателю на состояние: он уникален.
  var masterStep: int32 = -1
  var i: int32 = 0
  while i < p.stepCount:
    if p.steps[i].userData == masterState:
      masterStep = i
      break
    inc i

  if masterStep < 0:
    destroyBinding(p)
    destroyPipeline(p)
    binding = nil
    return false

  binding.masterStep = masterStep
  binding.masterOut.channels = signal_types.MaxAudioChannels
  binding.masterOut.frames = 0
  binding.masterOut.stride = 0
  binding.masterOut.layout = alPlanar
  binding.masterOut.data = nil

  p.userData = binding
  p.bindMasterProc = bindMasterProc
  p.applyParamProc = applyParamProc
  p.destroyProc = destroyBinding
  true

{.pop.}
