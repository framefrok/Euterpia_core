# nodes/builtin/sequencer/notes.nim
#
# Нотный секвенсор: паттерн (ноты, контроллеры, bend) превращается в поток
# событий на выходе `eventOut` с точностью до сэмпла.
#
# Нода — источник событий: аудиовыходов у неё нет, а адресат (орган,
# фортепиано, гитара, ударные, плагин) подключается к `eventOut`. Это тот
# же контракт, что и у MIDI-входа с звуковой карты: инструменты не знают,
# играет живой музыкант или секвенсор (`instrument_common.nim`).
#
# Модель времени:
#
#   * паттерн хранится в тиках, `TicksPerQuarter` тиков на четверть —
#     то же разрешение, что у транспорта ядра (960 PPQ);
#   * `samplePosition` блока переводится в тики через темп транспорта,
#     поэтому нода следует за `Tempo`/`timesig` и не хранит свою шкалу;
#   * позиция события внутри блока считается как
#     `(tick - tickStart) * samplesPerTick` и кладётся в `frameOffset`.
#     Это делает атаки sample-accurate: инструмент нарезает блок по
#     `frameOffset` и запускает голос ровно в нужном сэмпле.
#
# Что секвенсор НЕ делает: он не «играет» сам и не знает, сколько нот
# отведено инструменту. Паттерн — это расписание, а не голос.
#
# Паттерн всегда отсортирован по тику: `notesAddEvent` вставляет событие
# в нужное место (двоичный поиск + сдвиг). Дубли и порядок «сначала off,
# потом on» на одном тике сохраняются: для повторяющейся ноты это
# ровно то, что нужно, чтобы голос перезапустился, а не «залип».

import
  std/math,
  signal_types,
  node_interface,
  ../../sdk/node_api

{.push raises: [].}

const
  # Идентификаторы параметров числовые и стабильные (как у инструментов):
  # автоматизация и CLI ссылаются на них, а не на названия.
  NotesParamTranspose* = 0'u32  # полутоны, -36..+36
  NotesParamVelocity*  = 1'u32  # множитель velocity, 0..2
  NotesParamChannel*   = 2'u32  # 0..15; 16 — «как записано в паттерне»
  NotesParamLoop*      = 3'u32  # 0..1: повторять паттерн
  NotesParamLength*    = 4'u32  # тики; 0 — «до последнего события»
  NotesParamSwing*     = 5'u32  # 0..0.75: сдвиг слабых восьмых

  ## Идентификатор типа ноды в реестре. Одна константа на весь проект:
  ## загрузчик сцены ищет нотные ноды по ней, а дескриптор берёт её же —
  ## строка не может разойтись сама с собой.
  NotesTypeId* = "euterpia.notes"

  ## Разрешение паттерна. Совпадает с PPQ транспорта ядра
  ## (`transport.PpqTicksPerQuarter`, issue #387), поэтому позицию блока
  ## можно считать без пересчёта шкал.
  TicksPerQuarter* = 960'i32

  ## Значение параметра `channel`, означающее «не переопределять канал»:
  ## у нот сохраняется тот канал, с которым они записаны в паттерн.
  NotesChannelAsWritten = 16.0'f32

  ## Потолок паттерна: 4096 событий — столько же, сколько у клипа
  ## в проекте (`MaxNotesPerClip`). Ноты занимают по два события
  ## (on и off), значит в паттерн влезает 2048 нот.
  MaxPatternEvents* = 4096

  ## Потолок параметра `length`: 65536 тиков = 68 тактов 4/4.
  MaxLengthTicks = 65_536.0'f32

  ## Сколько копий паттерна разрешено просмотреть за один блок. Защита от
  ## вырожденного случая «паттерн в один тик на огромном блоке»: без неё
  ## работа на блок росла бы как blockSize / length.
  MaxLoopIterations = 64

type
  PatternEvent* = object
    ## Событие паттерна в терминах очереди событий ядра: то же, чем
    ## закончится `RealtimeEvent`, но без позиции в блоке (её считает
    ## процессор по тику).
    kind*: RealtimeEventKind
    tick*: int32
    channel*: uint8
    data*: array[4, float32]

  NotesState* = object
    ## Состояние ноды. POD: владение памятью — за хостом, внутри только
    ## массив событий и «медленные» параметры.
    events: array[MaxPatternEvents, PatternEvent]
    count: int32

    lengthTicks: int32        # 0 — авто (по последнему событию)

    transpose: int32
    velocity: float32
    channel: uint8            # 16 — как записано в паттерне
    loop: bool
    swing: float32

    droppedEvents: int64      # события, не влезшие в очередь блока
    rejected: int64           # события, не влезшие в паттерн
    lastTick: int64           # последний отыгранный тик (диагностика)
    panicPending: bool        # сброс: погасить голоса на первом блоке

    live: bool

var
  notesDesc: NodeDesc
  notesFactory: NodeFactory
  notesReady = false

# ==============================================================================
# Descriptor (холодная сторона)
# ==============================================================================

proc initNotesDesc() =
  notesDesc = NodeDesc(
    id: fixedId(NotesTypeId),
    name: fixedName("Notes"),
    category: fixedName("sequencer"),
    audioInCount: 0,       # источник событий: ни аудиовхода, ни аудиовыхода
    audioOutCount: 0,
    ctrlInCount: 0, ctrlOutCount: 0,
    eventInCount: 0,
    eventOutCount: 1,      # сюда подключается инструмент (eventIn)
    latencyFrames: 0,
    maxChannels: 0,
    paramCount: 6
  )

  notesDesc.params[0] = NodeParamDesc(
    id: NotesParamTranspose, name: fixedParamName("transpose"),
    minValue: -36.0f, maxValue: 36.0f, defaultValue: 0.0f, step: 1.0f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  notesDesc.params[1] = NodeParamDesc(
    id: NotesParamVelocity, name: fixedParamName("velocity"),
    minValue: 0.0f, maxValue: 2.0f, defaultValue: 1.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
  notesDesc.params[2] = NodeParamDesc(
    id: NotesParamChannel, name: fixedParamName("channel"),
    minValue: 0.0f, maxValue: 16.0f, defaultValue: NotesChannelAsWritten,
    step: 1.0f,
    flags: uint32(npfAutomatable)
  )
  notesDesc.params[3] = NodeParamDesc(
    id: NotesParamLoop, name: fixedParamName("loop"),
    minValue: 0.0f, maxValue: 1.0f, defaultValue: 0.0f, step: 1.0f,
    flags: uint32(npfAutomatable)
  )
  notesDesc.params[4] = NodeParamDesc(
    id: NotesParamLength, name: fixedParamName("length"),
    minValue: 0.0f, maxValue: MaxLengthTicks, defaultValue: 0.0f, step: 1.0f,
    flags: uint32(npfAutomatable)
  )
  notesDesc.params[5] = NodeParamDesc(
    id: NotesParamSwing, name: fixedParamName("swing"),
    minValue: 0.0f, maxValue: 0.75f, defaultValue: 0.0f, step: 0.01f,
    flags: uint32(npfAutomatable) or uint32(npfModulatable)
  )
# ==============================================================================
# Паттерн (control plane)
#
# Запись в паттерн — холодная операция: она двигает память и вызывается
# загрузчиком проекта, а не audio thread. Во время звучания паттерн
# читается, а меняется только его длина и «медленные» параметры.
# ==============================================================================

proc notesClear*(st: var NotesState) =
  ## Пустой паттерн: события снимаются, счётчики обнуляются.
  st.count = 0
  st.droppedEvents = 0
  st.rejected = 0
  st.lastTick = 0

proc insertIndex(st: ptr NotesState; tick: int32): int =
  ## Первое событие, чей тик строго больше `tick`. Вставка на это место
  ## держит события отсортированными и сохраняет порядок равных тиков:
  ## `note-off`, добавленный раньше, останется перед `note-on` той же ноты —
  ## повторяющаяся нота перезапустит голос, а не «залипнет».
  var lo = 0
  var hi = st.count.int
  while lo < hi:
    let mid = (lo + hi) shr 1
    if st.events[mid].tick <= tick:
      lo = mid + 1
    else:
      hi = mid
  lo

proc notesAddEvent*(st: var NotesState; kind: RealtimeEventKind; tick: int32;
                    channel: int;
                    data: array[4, float32]): bool =
  ## Кладёт событие в паттерн. Возвращает false, если места нет или тик
  ## отрицательный: молча терять события нельзя, поэтому отказ виден
  ## вызывающему, а счётчик `rejected` доступен диагностике.
  if tick < 0:
    inc st.rejected
    return false
  if st.count >= MaxPatternEvents:
    inc st.rejected
    return false

  let ch = if channel < 0: 0 elif channel > 15: 15 else: channel
  let idx = insertIndex(addr st, tick)

  var i = st.count
  while i > idx:
    st.events[i] = st.events[i - 1]
    dec i

  st.events[idx] = PatternEvent(kind: kind, tick: tick, channel: uint8(ch),
                                data: data)
  inc st.count
  true

proc notesAddNote*(st: var NotesState; startTick, durationTicks: int;
                   pitch: int; velocity: float32;
                   channel: int = 0): bool =
  ## Нота — это ДВА события: note-on в начале и note-off в конце.
  ## Секвенсор не следит за парами и не «держит» голос: он играет то,
  ## что записано, а что с этим делать, решает инструмент.
  if pitch < 0 or pitch > 127:
    return false

  var on: array[4, float32]
  on[0] = float32(pitch)
  on[1] = clamp(velocity, 0.0f, 1.0f)

  var off: array[4, float32]
  off[0] = float32(pitch)

  let dur = if durationTicks > 0: durationTicks else: 1
  result = notesAddEvent(st, evNoteOn, int32(startTick), channel, on)
  result = notesAddEvent(st, evNoteOff, int32(startTick + dur), channel, off) and
    result

proc notesAddCC*(st: var NotesState; tick, controller: int; value: float32;
                 channel: int = 0): bool =
  ## Контроллер. Значение — 0..1, как во всём событийном пути ядра
  ## (`core/midi_events.nim`): CC64 = 1.0 — «педаль вниз».
  if controller < 0 or controller > 127:
    return false

  var d: array[4, float32]
  d[0] = float32(controller)
  d[1] = clamp(value, 0.0f, 1.0f)
  result = notesAddEvent(st, evCC, int32(tick), channel, d)

proc notesAddBend*(st: var NotesState; tick: int; value: float32;
                   channel: int = 0): bool =
  ## Колесо высоты: -1..+1 от центра (как в MIDI-пути ядра).
  var d: array[4, float32]
  d[0] = clamp(value, -1.0f, 1.0f)
  result = notesAddEvent(st, evPitchBend, int32(tick), channel, d)

proc notesEventCount*(st: NotesState): int {.inline.} =
  st.count.int

proc notesEventAt*(st: NotesState; index: int): PatternEvent {.inline.} =
  st.events[index]

proc notesLastTick*(st: NotesState): int32 {.inline.} =
  ## Тик последнего события: паттерн отсортирован, поэтому это максимум.
  if st.count > 0: st.events[st.count - 1].tick else: 0'i32

proc patternLengthOf(st: ptr NotesState): int32 {.inline.} =
  ## Длина паттерна в тиках. Отдельная версия от указателя — её зовёт
  ## audio thread: передавать туда состояние по значению значило бы
  ## копировать весь массив событий на каждом блоке.
  if st.lengthTicks > 0:
    st.lengthTicks
  elif st.count > 0:
    st.events[st.count - 1].tick
  else:
    0'i32

proc notesPatternLength*(st: NotesState): int32 =
  ## Длина паттерна в тиках: параметр `length`, а при нуле — последнее
  ## событие. Ноль означает «паттерн пуст».
  if st.lengthTicks > 0: st.lengthTicks else: notesLastTick(st)

proc notesDroppedEvents*(st: NotesState): int64 {.inline.} =
  ## Сколько событий не влезло в очередь блока: ненулевое значение —
  ## признак того, что блок перегружен событиями (диагностика).
  st.droppedEvents

proc notesRejectedEvents*(st: NotesState): int64 {.inline.} =
  ## Сколько событий не влезло в паттерн.
  st.rejected

# ==============================================================================
# Состояние (холодная сторона)
# ==============================================================================

proc createNotesState(desc: ptr NodeDesc; userData: pointer): pointer
    {.cdecl, raises: [], gcsafe.} =
  discard userData
  if desc.isNil:
    return nil
  if not notesReady:
    initNotesDesc()
    notesReady = true

  result = allocShared0(sizeof(NotesState))
  if result.isNil:
    return nil

  let st = cast[ptr NotesState](result)
  st.transpose = int32(notesDesc.params[0].defaultValue)
  st.velocity = notesDesc.params[1].defaultValue
  st.channel = uint8(NotesChannelAsWritten)
  st.loop = false
  st.lengthTicks = 0
  st.swing = 0.0f

proc destroyNotesState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  deallocShared(state)

proc resetNotesState(state: pointer) {.cdecl, raises: [], gcsafe.} =
  ## Паника: паттерн остаётся на месте (его содержимое — данные проекта),
  ## а голоса инструментов надо погасить. Своего аудиопотока у ноды нет,
  ## поэтому сброс откладывается до первого блока: там в очередь уйдут
  ## CC120/CC123, которые инструмент понимает как «все ноты выключить».
  if state.isNil:
    return
  let st = cast[ptr NotesState](state)
  st.panicPending = true

# ==============================================================================
# Параметры
#
# setParam зовётся и из control plane, и из audio thread (команда
# `cmdSetParam`), поэтому здесь только запись цели в поле состояния.
# ==============================================================================

proc setNotesParam(state: pointer; paramId: uint32; value: float32;
                   normalized: bool) {.cdecl, raises: [], gcsafe.} =
  if state.isNil:
    return
  let st = cast[ptr NotesState](state)
  let raw = if normalized: notesDesc.paramFromNormalized(paramId, value)
            else: value

  case paramId
  of NotesParamTranspose:
    st.transpose = int32(clamp(round(raw), -36.0f, 36.0f))
  of NotesParamVelocity:
    st.velocity = clamp(raw, 0.0f, 2.0f)
  of NotesParamChannel:
    st.channel = uint8(clamp(round(raw), 0.0f, NotesChannelAsWritten))
  of NotesParamLoop:
    st.loop = raw >= 0.5f
  of NotesParamLength:
    st.lengthTicks = int32(clamp(round(raw), 0.0f, MaxLengthTicks))
  of NotesParamSwing:
    st.swing = clamp(raw, 0.0f, 0.75f)
  else:
    return

  st.live = true

proc getNotesParam(state: pointer; paramId: uint32; outValue: ptr float32): bool
    {.cdecl, raises: [], gcsafe.} =
  if state.isNil or outValue.isNil:
    return false
  let st = cast[ptr NotesState](state)

  case paramId
  of NotesParamTranspose: outValue[] = float32(st.transpose)
  of NotesParamVelocity:  outValue[] = st.velocity
  of NotesParamChannel:   outValue[] = float32(st.channel)
  of NotesParamLoop:      outValue[] = if st.loop: 1.0f else: 0.0f
  of NotesParamLength:    outValue[] = float32(st.lengthTicks)
  of NotesParamSwing:     outValue[] = st.swing
  else: return false

  true

# ==============================================================================
# Обработка (audio thread)
#
# Аллокаций здесь нет: паттерн — обычный массив состояния, а события
# кладутся в очередь блока, которую выделяет хост пайплайна.
# ==============================================================================

proc swingShiftTicks(st: ptr NotesState; ev: PatternEvent): float64 {.inline.} =
  ## Сдвиг слабой восьмой. Как в «железных» секвенсорах, двигается начало
  ## ноты (note-on), а не её конец: иначе длительность сократилась бы
  ## дважды. Полная swing = 1/3 четверти — триольный грув.
  if st.swing <= 0.0f or ev.kind != evNoteOn:
    return 0.0
  let half = TicksPerQuarter div 2
  if half <= 0 or ev.tick < 0:
    return 0.0
  if (ev.tick mod half) == 0 and ((ev.tick div half) mod 2) == 1:
    return float64(st.swing) * float64(TicksPerQuarter div 3)
  0.0

proc emitIteration(st: ptr NotesState; q: ptr EventQueue; base: int64;
                   windowStart, windowEnd, samplesPerTick: float64;
                   frames: int32) =
  ## Одна копия паттерна: события, попавшие в тиковое окно блока, уходят
  ## в очередь с посчитанным `frameOffset`.
  var i = 0'i32
  while i < st.count:
    let ev = st.events[i]
    let t = float64(base) + float64(ev.tick) + swingShiftTicks(st, ev)
    if t >= windowStart and t < windowEnd:
      let exact = (t - windowStart) * samplesPerTick
      let clamped =
        if exact < 0.0: 0.0
        elif exact > float64(frames): float64(frames)
        else: exact

      var evOut: RealtimeEvent
      evOut.frameOffset = uint32(clamp(round(clamped), 0.0, float64(frames - 1)))
      evOut.subFrame = 0.0f
      evOut.kind = ev.kind
      evOut.port = 0
      evOut.channel = if st.channel >= 16'u8: ev.channel else: st.channel
      evOut.data = ev.data

      if ev.kind == evNoteOn or ev.kind == evNoteOff:
        # Транспонирование и velocity применяются на выходе, а не в
        # паттерне: паттерн остаётся записью нот, а параметры — тем,
        # что музыкант крутит поверх неё.
        let pitch = clamp(int(round(ev.data[0])) + st.transpose, 0, 127)
        evOut.data[0] = float32(pitch)
        if ev.kind == evNoteOn:
          evOut.data[1] = clamp(ev.data[1] * st.velocity, 0.0f, 1.0f)

      if not q.pushEvent(evOut):
        inc st.droppedEvents

    inc i

proc processNotesNode*(
    ctx: ptr NodeProcessContext;
    audio: ptr NodeAudioPorts;
    ctrl: ptr NodeControlPorts;
    events: ptr NodeEventPorts;
    userData: pointer
) {.cdecl, raises: [], gcsafe.} =
  discard audio
  discard ctrl
  if ctx.isNil or userData.isNil:
    return

  let st = cast[ptr NotesState](userData)

  var q: ptr EventQueue = nil
  if not events.isNil and events.outputCount > 0:
    q = events.outputs[0]
  if q.isNil:
    return

  # Очередь блока принадлежит хосту и может содержать чужие события
  # (например, метрономы) — источник обязан начать с пустой очереди.
  q.clearEvents()

  # Отложенная паника после `reset`: инструмент должен узнать, что играть
  # больше нечего, иначе голос останется висеть до следующего note-off.
  if st.panicPending:
    st.panicPending = false
    var panic: RealtimeEvent
    panic.kind = evCC
    panic.port = 0
    panic.channel = 0
    panic.data[0] = 123.0f   # CC123 All Notes Off
    panic.data[1] = 0.0f
    discard q.pushEvent(panic)

  let frames = ctx.blockSize
  if frames <= 0:
    return
  if pfTransportPlaying notin ctx.flags:
    return
  if not (ctx.sampleRate > 0.0f):
    return

  let tempo = if ctx.transport.tempo > 1.0: ctx.transport.tempo else: 120.0
  let samplesPerTick =
    float64(ctx.sampleRate) * 60.0 / (tempo * float64(TicksPerQuarter))
  if samplesPerTick <= 0.0:
    return

  let len = patternLengthOf(st)
  if len <= 0:
    return                  # пустой паттерн: играть нечего

  # Окно блока в тиках: от `samplePosition` до его конца. Тик считается
  # непрерывной величиной, поэтому атака попадает в сэмпл, а не в блок.
  let windowStart = float64(ctx.samplePosition) / samplesPerTick
  let windowEnd = windowStart + float64(frames) / samplesPerTick
  st.lastTick = int64(windowStart)

  if st.loop:
    var kFrom = int64(floor(windowStart / float64(len)))
    # +1 копия сверх окна: swing заносит слабую восьмую за границу
    # паттерна, и её событие обязано прозвучать в своём блоке.
    var kTo = int64(floor(windowEnd / float64(len))) + 1'i64
    if kFrom < 0:
      kFrom = 0
    if kTo - kFrom > int64(MaxLoopIterations):
      kTo = kFrom + int64(MaxLoopIterations)

    var k = kFrom
    while k <= kTo:
      emitIteration(st, q, k * int64(len), windowStart, windowEnd,
                    samplesPerTick, frames)
      inc k
  else:
    # Без повтора копия одна: паттерн играет от начала транспорта и
    # заканчивается сам — события позднее `len` просто не находятся.
    emitIteration(st, q, 0'i64, windowStart, windowEnd, samplesPerTick, frames)


# ==============================================================================
# Экспорт
# ==============================================================================

proc getNotesDesc*(): ptr NodeDesc =
  if not notesReady:
    initNotesDesc()
    notesReady = true
  addr notesDesc

proc getNotesFactory*(): ptr NodeFactory =
  if not notesReady:
    initNotesDesc()
    notesReady = true
  if notesFactory.create.isNil:
    notesFactory = NodeFactory(
      create: createNotesState,
      destroy: destroyNotesState,
      process: processNotesNode,
      setParam: setNotesParam,
      getParam: getNotesParam,
      reset: resetNotesState
    )
  addr notesFactory

{.pop.}

