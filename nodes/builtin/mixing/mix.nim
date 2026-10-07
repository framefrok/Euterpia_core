# nodes/builtin/mixing/mix.nim
#
# Сумматор: несколько аудиовходов складываются в один выход.
#
# Зачем нода нужна: у инструментов нет аудиовхода (они источники), а мастер
# один. Без сумматора несколько инструментов в одном проекте невозможно
# свести — у каждого выхода «свой» мастер, и загрузчик сцены честно откажет
# «на мастер претендует несколько нод». Микшер-консоль (`nodes/mixer_console`)
# — редакторская модель, а не нода; здесь ровно то, что нужно графу.
#
# Порты: `audioInCount` входов (8 — с запасом на ансамбль) → 1 выход.
# Уровень общий и сглаженный: ступенька параметра не должна щёлкать.
# Пустые (не подключённые) входы читаются как 0 — `sampleAt` это гарантирует.

import
  std/math,
  signal_types,
  node_interface,
  ../../sdk/node_api,
  ../../sdk/audio_buffers,
  ../../sdk/dsp_units

{.push raises: [].}

const
  MixParamLevel* = 0'u32
    ## Общий уровень суммы, dB. -80 — тишина. Сглаживается.

  MixInputCount* = 8
    ## Число входов сумматора: ансамбль из четырёх партий плюс запас на
    ## шины эффектов. Меньше — не хватило бы; больше — рос бы размер шага
    ## пайплайна без пользы.

  MixMaxChannels* = 2

  DcBlockerHz* = 10.0f
    ## Частота среза DC-блокера. Сумма инструментов даёт постоянную
    ## составляющую (асимметрия soft-clip, утечка огибающих), а она съедает
    ## запас по уровню и «уводит» ноль. 10 Гц — ниже слышимого низа.

type
  MixState* = object
    smoothDb: ParamSmoother
    ## Состояние DC-блокера на канал: y = x - x1 + R·y1.
    dcX1, dcY1: array[MixMaxChannels, float32]

var
  mixDesc: NodeDesc
  mixFactory: NodeFactory
  mixReady = false

proc initMixDesc() =
  mixDesc = NodeDesc(
    id: fixedId("euterpia.mix"),
    name: fixedName("Mix"),
    category: fixedName("mixing"),
    audioInCount: MixInputCount, audioOutCount: 1,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 0, eventOutCount: 0,
    latencyFrames: 0, maxChannels: 2,
    paramCount: 1
  )

  mixDesc.params[0] = NodeParamDesc(
    id: MixParamLevel, name: fixedParamName("level"),
    minValue: -80.0f, maxValue: 12.0f, defaultValue: 0.0f, step: 0.1f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )

proc createMixState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not mixReady:
    initMixDesc()
    mixReady = true

  result = allocShared0(sizeof(MixState))
  if result.isNil:
    return nil
  let st = cast[ptr MixState](result)
  st.smoothDb = initSmoother(15.0f, 48000.0f, 0.0f)

proc destroyMixState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  deallocShared(state)

proc resetMixState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  discard

proc setMixParam(state: pointer; paramId: uint32; value: float32;
                 normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil or paramId != MixParamLevel:
    return
  let st = cast[ptr MixState](state)
  let raw = if normalized: mixDesc.paramFromNormalized(paramId, value) else: value
  st.smoothDb.setTarget(clamp(raw, -80.0f, 12.0f))

proc getMixParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil or paramId != MixParamLevel:
    return false
  outValue[] = (cast[ptr MixState](state)).smoothDb.target
  true

proc processMixNode(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard ctrl
  discard events
  let st = cast[ptr MixState](userData)
  if st.isNil or audio.isNil or audio.outputCount < 1:
    return
  let outBuf = audio.outputs[0]
  if outBuf.isNil:
    return

  let frames = processFrames(ctx, outBuf)
  if frames <= 0:
    return

  let channels = max(channelCount(outBuf), 1'i32)

  # DC-блокер: сумма даёт постоянную составляющую, и её надо снять здесь,
  # на мастер-шине. R зависит от частоты дискретизации.
  let sr = if ctx.sampleRate > 0.0f: ctx.sampleRate else: 48000.0f
  let dcR = clamp(1.0f - (2.0f * PI * DcBlockerHz / sr), 0.9f, 0.9999f)

  # Пер-сэмпловое сглаживание уровня (#386). Порядок циклов — сэмпл-снаружи,
  # канал-внутри: одно значение усиления на позицию, общее для всех каналов.
  # DC-блокер по-прежнему независим на канал.
  var ramp = st.smoothDb.beginRamp(frames)
  var i: int32 = 0
  while i < frames:
    let g = dbToLin(ramp.next())
    for ch in 0 ..< channels:
      let ci = int(ch) mod MixMaxChannels
      # Каждый сэмпл выхода — сумма соответствующего сэмпла всех входов.
      # `sampleAt` ничего не аллоцирует и безопасен для nil-входа (вернёт 0),
      # поэтому неподключённый вход не создаёт ветвлений в горячем цикле.
      var acc = 0.0f
      for k in 0 ..< audio.inputCount:
        let inBuf = audio.inputs[k]
        if not inBuf.isNil:
          acc += inBuf.sampleAt(ch, i)
      let x = acc * g
      let y = x - st.dcX1[ci] + dcR * st.dcY1[ci]
      st.dcX1[ci] = x
      st.dcY1[ci] = y
      outBuf.setSampleAt(ch, i, y)
    inc i

proc getMixDesc*(): ptr NodeDesc =
  if not mixReady:
    initMixDesc()
    mixReady = true
  addr mixDesc

proc getMixFactory*(): ptr NodeFactory =
  if not mixReady:
    initMixDesc()
    mixReady = true
  if mixFactory.create.isNil:
    mixFactory = NodeFactory(
      create: createMixState, destroy: destroyMixState,
      process: processMixNode, setParam: setMixParam,
      getParam: getMixParam, reset: resetMixState
    )
  addr mixFactory

{.pop.}
