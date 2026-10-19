# nodes/builtin/io/sequencer_player.nim
#
# Плеер секвенсора проекта (issue #87): клипы дорожек → события графа.
#
# Зачем эта нода, если есть `euterpia.notes`:
#   `euterpia.notes` играет ОДИН паттерн, который загрузчик сцены раскладывает
#   по дорожкам. Секвенсор ядра (`core/sequencer`) умеет больше: несколько
#   дорожек и клипов, mute/solo, повторы клипа и автоматизацию — и именно он
#   раскрывает клипы для MIDI-экспорта. До этой ноды `SequencerRuntime` вообще
#   не вызывался из графа (см. grep в issue #87): клипы проекта не превращались
#   в события нод, пока их не переупакует загрузчик.
#
# Модель времени:
#   * позиция берётся из `ctx.samplePosition` и темпа транспорта — тик
#     считается непрерывной величиной, поэтому атака попадает в нужный кадр
#     блока (`frameOffset`/`subFrame`), а не в начало блока;
#   * `CompiledSequencer` строится на control-path (загрузчик проекта,
#     `nodes/builtin/scene_loader`) и передаётся сюда указателем:
#     `setCompiledSequencer`. В audio-потоке нет ни компиляции, ни аллокаций —
#     только бинарный поиск по уже отсортированным событиям.
#
# Владение:
#   скомпилированный секвенсор принадлежит ХОСТУ (сцене/редактору), нода
#   хранит только указатель. Хост обязан не освобождать его, пока нода
#   участвует в графе. Это то же правило, что у `euterpia.clip` с сэмплами.
#
# Realtime-дисциплина:
#   * `EventQueue` ноды ограничена `MaxBlockEvents`; переполнение считается
#     (`droppedEvents`), а не теряется молча;
#   * обмен указателем происходит на control-path при остановленном
#     транспорте — это контракт `setCompiledSequencer`, а не «как получится».

import std/math

import
  signal_types,
  node_interface,
  aligned_mem,
  sequencer,
  ../../sdk/node_api

{.push raises: [].}

const
  SequencerPlayerTypeId* = "euterpia.sequencer"
    ## Идентификатор типа ноды-плеера секвенсора.

  SequencerPlayerTicksPerQuarter = 960
    ## Разрешение транспорта ядра (`transport.PpqTicksPerQuarter`). Здесь
    ## константа повторена осознанно: Nodes не должен тянуть `transport`
    ## ради одного числа, а расхождение поймает тест `test_sequencer_player`
    ## (он сверяет позиции событий с `test_sequencer`).

type
  SequencerPlayerState* = object
    ## Состояние ноды. POD без GC-полей: живёт в shared-куче.
    runtime*: SequencerRuntime
    scratch: EventQueue
      ## Очередь блока, которую наполняет `SequencerRuntime.processBlock`.
      ## Своя, а не выходная: `processBlock` очищает очередь, а выходная
      ## может содержать события других источников.

var
  seqDesc: NodeDesc
  seqFactory: NodeFactory
  seqReady = false

proc initSequencerDesc() =
  seqDesc = NodeDesc(
    id: fixedId(SequencerPlayerTypeId),
    name: fixedName("Sequencer"),
    category: fixedName("sequencer"),
    audioInCount: 0, audioOutCount: 0,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 0,
    eventOutCount: 1,      # сюда подключается инструмент (eventIn)
    latencyFrames: 0,
    maxChannels: 0,
    paramCount: 0
  )

# ==============================================================================
# Control-path: привязка скомпилированного секвенсора
# ==============================================================================

proc setCompiledSequencer*(state: pointer; compiled: ptr CompiledSequencer) =
  ## Привязать (или отвязать при `nil`) скомпилированный секвенсор.
  ##
  ## Вызывается ТОЛЬКО на control-path, пока транспорт стоит: audio-поток
  ## читает указатель без синхронизации. Компиляция — холодная операция,
  ## в реальном времени её нет.
  if state.isNil:
    return
  let st = cast[ptr SequencerPlayerState](state)
  st.runtime.compiled = compiled
  st.runtime.droppedEvents = 0

proc compiledSequencer*(state: pointer): ptr CompiledSequencer =
  ## Текущий скомпилированный секвенсор (диагностика/тесты).
  if state.isNil:
    return nil
  cast[ptr SequencerPlayerState](state).runtime.compiled

proc droppedEvents*(state: pointer): uint32 =
  ## Сколько событий не поместилось в очередь блока за всё время.
  if state.isNil:
    return 0
  cast[ptr SequencerPlayerState](state).runtime.droppedEvents

# ==============================================================================
# Состояние (холодная сторона)
# ==============================================================================

proc createSequencerState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not seqReady:
    initSequencerDesc()
    seqReady = true

  # Состояние содержит `EventQueue` с `align: 64`; `allocShared0` даёт только
  # 16 байт, и UBSan ловит member access по misaligned-адресу.
  result = alignedSharedAlloc0(sizeof(SequencerPlayerState),
                               alignof(SequencerPlayerState))
  if result.isNil:
    return nil
  let st = cast[ptr SequencerPlayerState](result)
  st.runtime = initRuntime(nil)

proc destroySequencerState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  ## Компиляция принадлежит хосту, поэтому здесь её НЕ освобождаем: нода
  ## владеет только собственной структурой состояния.
  if state.isNil:
    return
  alignedSharedDealloc(state)

proc resetSequencerState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  ## Паника: снять накопленные dropped-счётчики. Сами события — данные
  ## проекта, они остаются; инструмент получит All Notes Off от своего
  ## `reset` (нода-источник не имеет аудиопотока, чтобы «погасить» голоса).
  if state.isNil:
    return
  let st = cast[ptr SequencerPlayerState](state)
  st.runtime.droppedEvents = 0

# ==============================================================================
# Обработка (audio thread): без файлов, без аллокаций, без локов
# ==============================================================================

proc processSequencerNode*(
    ctx: ptr NodeProcessContext;
    audio: ptr NodeAudioPorts;
    ctrl: ptr NodeControlPorts;
    events: ptr NodeEventPorts;
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard audio
  discard ctrl
  if userData.isNil:
    return

  let st = cast[ptr SequencerPlayerState](userData)

  var q: ptr EventQueue = nil
  if not events.isNil and events.outputCount > 0:
    q = events.outputs[0]
  if q.isNil:
    return

  # Источник обязан начать блок с пустой очереди: иначе события прошлого
  # блока «прилипли» бы к текущему.
  q.clearEvents()

  if ctx.isNil or st.runtime.compiled.isNil:
    return
  if pfTransportPlaying notin ctx.flags:
    return
  if ctx.blockSize <= 0 or ctx.sampleRate <= 0.0f:
    return

  let tempo = if ctx.transport.tempo > 1.0: ctx.transport.tempo else: 120.0
  let samplesPerTick =
    float64(ctx.sampleRate) * 60.0 /
    (tempo * float64(SequencerPlayerTicksPerQuarter))
  if samplesPerTick <= 0.0:
    return

  # Окно блока в тиках. Начало округляется ВНИЗ, конец — ВВЕРХ: событие на
  # границе блока не должно потеряться из-за дробного тика. `processBlock`
  # сам отбрасывает всё, что вышло за `blockEndTick`.
  let ticksPerSample = float32(1.0 / samplesPerTick)
  let startExact = float64(ctx.samplePosition) / samplesPerTick
  let blockStartTick = int64(floor(startExact))
  let blockEndTick =
    blockStartTick + int64(ceil(float64(ctx.blockSize) / samplesPerTick))

  st.runtime.processBlock(blockStartTick, blockEndTick, ticksPerSample,
                          st.scratch)

  # `processBlock` считает смещения от НАЧАЛА ТИКА, а блок может начинаться
  # между тиками (48 кГц и 120 BPM дают 25 кадров на тик — целое, но при
  # других темпах нет). Разница `frac` переводит тиковую сетку в реальную
  # позицию блока: без неё атака «прилипала» бы к сетке тиков.
  let frac = float64(ctx.samplePosition) -
             float64(blockStartTick) * samplesPerTick

  # Перекладываем из локальной очереди в выходную. `pushEvent` держит
  # порядок сам (#397), поэтому сортировать выход не нужно.
  var i = 0
  while i < st.scratch.count:
    var ev = st.scratch.events[i]
    let adjusted = float64(ev.frameOffset) + float64(ev.subFrame) - frac
    if adjusted < 0.0 or adjusted >= float64(ctx.blockSize):
      # Событие относится к соседнему блоку: тик попал в окно поиска из-за
      # округления границы, но звучать в этом блоке не должен.
      inc i
      continue
    let whole = int64(floor(adjusted))
    ev.frameOffset = uint32(whole)
    ev.subFrame = float32(adjusted - float64(whole))
    if not q.pushEvent(ev):
      inc st.runtime.droppedEvents
    inc i

# ==============================================================================
# Экспорт
# ==============================================================================

proc getSequencerPlayerDesc*(): ptr NodeDesc =
  if not seqReady:
    initSequencerDesc()
    seqReady = true
  addr seqDesc

proc getSequencerPlayerFactory*(): ptr NodeFactory =
  if not seqReady:
    initSequencerDesc()
    seqReady = true
  if seqFactory.create.isNil:
    seqFactory = NodeFactory(
      create: createSequencerState,
      destroy: destroySequencerState,
      process: processSequencerNode,
      setParam: nil,
      getParam: nil,
      reset: resetSequencerState
    )
  addr seqFactory

{.pop.}
