# nodes/builtin/instruments/instrument_common.nim
#
# Общая часть инструментов-эмуляторов (орган, фортепиано, гитара, ударные):
# перевод потока MIDI-событий узла в вызовы C-ядра из `eut_inst.c`.
#
# Все четыре движка живут по одному контракту, и он же задаёт обязанности
# этого модуля:
#
#   * память под состояние и голоса выделяет хост (движок не аллоцирует),
#     голоса управляются только note-on/note-off/педалью;
#   * `*_process` ПРИБАВЛЯЕТ в out-буферы, поэтому нода обязана сначала
#     очистить выход — иначе в него попадёт чужой остаток от прошлого блока;
#   * `stride` (1 — planar, 2 — interleaved) задаёт раскладку каналов,
#     которую нода определяет по своему выходному буферу.
#
# Отсюда два действия, общих для четырёх нод:
#   1) разложить блок по событиям: события в очереди отсортированы по
#      `frameOffset`, значит блок делится на непрерывные куски, и в каждом
#      куске ядру отдаётся ровно то, что уже «слышно» (sample-accurate);
#   2) применить события к движку: note on/off, CC64 (сустейн), CC1
#      (модуляция), CC120/123 (all notes off), pitch bend.
#
# Аллокаций здесь нет: только арифметика указателей и вызовы C.
#
# Непрерывные контроллеры (колесо, модуляция) сглаживаются ParamSmoother'ом
# и обновляются раз в блок. Это control-rate по определению MIDI: события
# внутри блока выстраивают голоса во времени (note-on), а CC квантуются
# блоком — так же, как у любого инструмента с блочной обработкой.

import
  signal_types,
  ../../sdk/audio_buffers,
  ../native/eut_native

{.push raises: [].}

const
  ## Полный ход колеса высоты звука в полутонах: значение по умолчанию
  ## для RPN 0 (GM), которое использует весь остальной MIDI-путь ядра.
  BendRangeSemitones* = 2.0'f32

  ## Полный ход CC1 (модуляция) в центах: движки принимают модуляцию
  ## в центах, потому что для органа это вибрато, а не выбор LFO-формы.
  ModFullCents* = 50.0'f32

  ## Время сглаживания непрерывных контроллеров. Колесо и модуляция
  ## приходят шагами MIDI, и без сглаживания слышны «ступеньки».
  MidiSmoothMs* = 10.0'f32
    ## Время сглаживания непрерывных контроллеров. Колесо и модуляция
    ## приходят ступенями MIDI, и без сглаживания слышны «ступеньки».

  InstScratchFrames* = int32(MaxBlockSize)
    ## Ёмкость временного буфера инструмента (кадров НА КАНАЛ) для
    ## interleaved-выхода. Инструмент, стоящий последним в цепочке,
    ## получает от движка буфер драйвера: каналы в нём идут зигзагом,
    ## непрерывного указателя на канал нет, а C-ядру нужен именно он.
    ## Буфер лежит в состоянии ноды (control-path, `create`), поэтому
    ## audio thread только читает и пишет в него.
    ##
    ## Размер = `MaxBlockSize`: блок движка длиннее не бывает, а блок
    ## больше целого буфера обрабатывается по частям.

type
  InstNoteOnProc* = proc(state: pointer; note: cint; velocity: float32)
      {.nimcall, raises: [], gcsafe.}
  InstNoteOffProc* = proc(state: pointer; note: cint) {.nimcall, raises: [], gcsafe.}
  InstAllOffProc* = proc(state: pointer) {.nimcall, raises: [], gcsafe.}
  InstPedalProc* = proc(state: pointer; down: bool) {.nimcall, raises: [], gcsafe.}
  InstProcessProc* = proc(state: pointer; outL, outR: ptr float32;
                          stride, frames: cint;
                          bendSemitones, modCents: float32)
      {.nimcall, raises: [], gcsafe.}

  InstAbi* = object
    ## Таблица вызовов движка. Инструменты отличаются составом параметров,
    ## но не способом управления голосами, поэтому render-путь общий:
    ## он получает таблицу и не знает, орган это или ударные.
    ##
    ## `pedal` может быть nil — тогда CC64 копится в `InstMidi.sustainDown`,
    ## но движку не передаётся (у ударных, органа и гитары сустейна нет).
    state*: pointer
    noteOn*: InstNoteOnProc
    noteOff*: InstNoteOffProc
    allOff*: InstAllOffProc
    pedal*: InstPedalProc
    process*: InstProcessProc

  InstMidi* = object
    ## MIDI-состояние инструмента: то, что живёт между блоками.
    bend*: ParamSmoother         # полутоны, [-BendRangeSemitones .. +]
    modCents*: ParamSmoother     # центы модуляции
    sustainDown*: bool           # последнее состояние CC64

proc initInstMidi*(sampleRate: float32): InstMidi =
  result.bend = initSmoother(MidiSmoothMs, sampleRate, 0.0f)
  result.modCents = initSmoother(MidiSmoothMs, sampleRate, 0.0f)

proc instSetSampleRate*(midi: var InstMidi; sampleRate: float32) =
  ## Переносит MIDI-состояние на новую частоту дискретизации.
  ##
  ## Шаг сглаживателя считается в сэмплах, поэтому при смене частоты
  ## его обязательно нужно пересчитать — иначе 10 мс превратятся в
  ## 9 мс на 44.1 кГц и в 20 мс на 96 кГц. Текущие и целевые значения
  ## сохраняются: смена частоты не должна «щёлкать» контроллером,
  ## который в этот момент вёз колесо к цели.
  let bendTarget = midi.bend.target
  let bendCurrent = midi.bend.current
  let modTarget = midi.modCents.target
  let modCurrent = midi.modCents.current
  let sustain = midi.sustainDown

  midi = initInstMidi(sampleRate)
  midi.bend = initSmoother(MidiSmoothMs, sampleRate, bendTarget)
  midi.bend.current = bendCurrent
  midi.modCents = initSmoother(MidiSmoothMs, sampleRate, modTarget)
  midi.modCents.current = modCurrent
  midi.sustainDown = sustain

# =============================================================================
# Адаптеры под формат таблицы
#
# C-функции принимают типизированные состояния (`EutOrgan*`), а таблица —
# `pointer`: без тонкой обёртки на каждую функцию указатель не подставить.
# =============================================================================

proc organNoteOnAbi(state: pointer; note: cint; velocity: float32) {.nimcall, raises: [], gcsafe.} =
  organNoteOn(cast[ptr Organ](state), note.int, velocity)

proc organNoteOffAbi(state: pointer; note: cint) {.nimcall, raises: [], gcsafe.} =
  organNoteOff(cast[ptr Organ](state), note.int)

proc organAllOffAbi(state: pointer) {.nimcall, raises: [], gcsafe.} =
  organAllOff(cast[ptr Organ](state))

proc organProcessAbi(state: pointer; outL, outR: ptr float32; stride, frames: cint;
                     bendSemitones, modCents: float32) {.nimcall, raises: [], gcsafe.} =
  organProcess(cast[ptr Organ](state), outL, outR, stride.int, frames.int,
               bendSemitones, modCents)

proc organAbi*(g: ptr Organ): InstAbi {.inline.} =
  ## Таблица вызовов органа. Орган «барочный»: педали сустейна у него нет,
  ## нота держится до note-off.
  InstAbi(
    state: cast[pointer](g),
    noteOn: organNoteOnAbi, noteOff: organNoteOffAbi, allOff: organAllOffAbi,
    pedal: nil, process: organProcessAbi
  )

proc pianoNoteOnAbi(state: pointer; note: cint; velocity: float32) {.nimcall, raises: [], gcsafe.} =
  pianoNoteOn(cast[ptr Piano](state), note.int, velocity)

proc pianoNoteOffAbi(state: pointer; note: cint) {.nimcall, raises: [], gcsafe.} =
  pianoNoteOff(cast[ptr Piano](state), note.int)

proc pianoAllOffAbi(state: pointer) {.nimcall, raises: [], gcsafe.} =
  pianoAllOff(cast[ptr Piano](state))

proc pianoPedalAbi(state: pointer; down: bool) {.nimcall, raises: [], gcsafe.} =
  pianoPedal(cast[ptr Piano](state), down)

proc pianoProcessAbi(state: pointer; outL, outR: ptr float32; stride, frames: cint;
                     bendSemitones, modCents: float32) {.nimcall, raises: [], gcsafe.} =
  pianoProcess(cast[ptr Piano](state), outL, outR, stride.int, frames.int,
               bendSemitones, modCents)

proc pianoAbi*(g: ptr Piano): InstAbi {.inline.} =
  ## Таблица вызовов фортепиано. Единственный инструмент с педалью:
  ## CC64 у него не глушит голоса, а снимает демпфер.
  InstAbi(
    state: cast[pointer](g),
    noteOn: pianoNoteOnAbi, noteOff: pianoNoteOffAbi, allOff: pianoAllOffAbi,
    pedal: pianoPedalAbi, process: pianoProcessAbi
  )

proc guitarNoteOnAbi(state: pointer; note: cint; velocity: float32) {.nimcall, raises: [], gcsafe.} =
  guitarNoteOn(cast[ptr Guitar](state), note.int, velocity)

proc guitarNoteOffAbi(state: pointer; note: cint) {.nimcall, raises: [], gcsafe.} =
  guitarNoteOff(cast[ptr Guitar](state), note.int)

proc guitarAllOffAbi(state: pointer) {.nimcall, raises: [], gcsafe.} =
  guitarAllOff(cast[ptr Guitar](state))

proc guitarProcessAbi(state: pointer; outL, outR: ptr float32; stride, frames: cint;
                      bendSemitones, modCents: float32) {.nimcall, raises: [], gcsafe.} =
  guitarProcess(cast[ptr Guitar](state), outL, outR, stride.int, frames.int,
                bendSemitones, modCents)

proc guitarAbi*(g: ptr Guitar): InstAbi {.inline.} =
  ## Таблица вызовов гитары. Педали нет: струна гасится note-off или
  ## palm mute, как у настоящей гитары без сустейн-педали.
  InstAbi(
    state: cast[pointer](g),
    noteOn: guitarNoteOnAbi, noteOff: guitarNoteOffAbi, allOff: guitarAllOffAbi,
    pedal: nil, process: guitarProcessAbi
  )

proc drumsNoteOnAbi(state: pointer; note: cint; velocity: float32) {.nimcall, raises: [], gcsafe.} =
  drumsNoteOn(cast[ptr Drums](state), note.int, velocity)

proc drumsNoteOffAbi(state: pointer; note: cint) {.nimcall, raises: [], gcsafe.} =
  drumsNoteOff(cast[ptr Drums](state), note.int)

proc drumsAllOffAbi(state: pointer) {.nimcall, raises: [], gcsafe.} =
  drumsAllOff(cast[ptr Drums](state))

proc drumsProcessAbi(state: pointer; outL, outR: ptr float32; stride, frames: cint;
                     bendSemitones, modCents: float32) {.nimcall, raises: [], gcsafe.} =
  # Ударные не строят высоту: колесо и модуляция к ним не относятся,
  # но подпись обязана совпадать, иначе ядро не вписать в общую таблицу.
  discard bendSemitones
  discard modCents
  drumsProcess(cast[ptr Drums](state), outL, outR, stride.int, frames.int)

proc drumsAbi*(g: ptr Drums): InstAbi {.inline.} =
  ## Таблица вызовов ударных. Note-off гасит тарелку и хэт (закрытие
  ## открытого хэта), поэтому он передаётся движку, а не игнорируется.
  InstAbi(
    state: cast[pointer](g),
    noteOn: drumsNoteOnAbi, noteOff: drumsNoteOffAbi, allOff: drumsAllOffAbi,
    pedal: nil, process: drumsProcessAbi
  )

# =============================================================================
# Управление голосами
# =============================================================================

proc instNoteOff*(abi: InstAbi; note: int) {.inline.} =
  if not abi.noteOff.isNil:
    abi.noteOff(abi.state, note.cint)

proc instNoteOn*(abi: InstAbi; note: int; velocity: float32) {.inline.} =
  if abi.noteOn.isNil:
    return
  if velocity <= 0.0f:
    # Note On с нулевой скоростью — это Note Off (стандарт MIDI).
    instNoteOff(abi, note)
    return
  abi.noteOn(abi.state, note.cint, velocity)

proc instAllOff*(abi: InstAbi; midi: var InstMidi) {.inline.} =
  ## CC123 «All Notes Off»: голоса снимаются, педаль отпускается.
  ## Иначе после паники остался бы висеть сустейн, и следующий блок
  ## звучал бы как ни в чём не бывало.
  if not abi.allOff.isNil:
    abi.allOff(abi.state)
  if midi.sustainDown:
    midi.sustainDown = false
    if not abi.pedal.isNil:
      abi.pedal(abi.state, false)

proc instApplyEvent*(abi: InstAbi; midi: var InstMidi; ev: RealtimeEvent) =
  ## Одно событие — одно действие. Неизвестные события молча пропускаются:
  ## aftertouch и program change на этих инструментах менять нечего.
  case ev.kind
  of evNoteOn:
    instNoteOn(abi, int(ev.data[0]), ev.data[1])
  of evNoteOff:
    instNoteOff(abi, int(ev.data[0]))
  of evCC:
    case int(ev.data[0])
    of 1:
      midi.modCents.setTarget(ev.data[1] * ModFullCents)
    of 64:
      let down = ev.data[1] >= 0.5f
      midi.sustainDown = down
      if not abi.pedal.isNil:
        abi.pedal(abi.state, down)
    of 120, 123:
      instAllOff(abi, midi)
    else:
      discard
  of evPitchBend:
    midi.bend.setTarget(ev.data[0] * BendRangeSemitones)
  else:
    discard


# =============================================================================
# Рендер блока
# =============================================================================

proc offsetPtr(p: ptr float32; frames: int32): ptr float32 {.inline.} =
  ## Смещение указателя на `frames` сэмплов вперёд.
  ##
  ## Через `uint`-арифметику: складывать указатели разных типов Nim не даёт,
  ## а голоса в этом месте обязаны получить непрерывный указатель на
  ## оставшуюся часть блока.
  if frames <= 0:
    return p
  cast[ptr float32](cast[uint](p) + uint(frames) * uint(sizeof(float32)))

proc instRenderPlanar(abi: InstAbi; midi: var InstMidi; outL, outR: ptr float32;
                      frames: int32; q: ptr EventQueue; evIdx: var int32;
                      bend, modCents: float32) =
  ## Отрисовка в НЕПРЕРЫВНЫЕ каналы: нарезка по событиям + вызовы ядра.
  ##
  ## `evIdx` — курсор по очереди блока: он общий для всех вызовов, поэтому
  ## блок больше временного буфера обрабатывается по частям, а событие не
  ## применяется дважды.
  var pos = 0'i32
  if not q.isNil:
    while evIdx < q.count:
      let ev = q.events[evIdx]
      var off = ev.frameOffset.int64
      if off < 0:
        off = 0
      elif off > frames.int64:
        off = frames.int64

      let cut = off.int32
      if cut > pos:
        abi.process(abi.state, offsetPtr(outL, pos), offsetPtr(outR, pos),
                    1'i32, (cut - pos).cint, bend, modCents)
        pos = cut

      instApplyEvent(abi, midi, ev)
      inc evIdx

  if pos < frames:
    abi.process(abi.state, offsetPtr(outL, pos), offsetPtr(outR, pos),
                1'i32, (frames - pos).cint, bend, modCents)

proc instRender*(abi: InstAbi; midi: var InstMidi; outBuf: PAudioBuffer;
                 frames: int32; q: ptr EventQueue;
                 scratch: ptr float32 = nil) =
  ## Отрисовка блока инструмента: очистка выхода, нарезка по событиям,
  ## вызовы ядра.
  ##
  ## События считаются отсортированными по `frameOffset` (`sortEvents`
  ## делает это в MIDI-пути). Событие, пришедшее позже уже отрисованного
  ## куска, применяется к голосам сразу, но задним числом звук не
  ## дорисовывается — это ожидаемое поведение для управляющего потока.
  ##
  ## Две раскладки выхода (см. `nodes/sdk/audio_buffers`):
  ##   * planar — обычная работа внутри графа: каналы идут подряд, ядро
  ##     получает указатель на канал напрямую;
  ##   * interleaved — выход прямо в драйвер (инструмент последний в
  ##     цепочке, мастер-шина): непрерывного канала нет, поэтому ядро
  ##     считает в `scratch` (состояние ноды), а результат раскладывается
  ##     по сэмплам. Без `scratch` такой порт остаётся тихим — инструмент
  ##     не имеет права писать в буфер через пересекающиеся указатели.
  if abi.process.isNil or outBuf.isNil or frames <= 0:
    return

  let channels = channelCount(outBuf)
  if channels <= 0:
    return

  # Ядро прибавляет к буферу, а нода обязана выдать ровно свой сигнал:
  # очистка здесь — часть контракта, а не «перестраховка».
  outBuf.fillZero(frames)

  var evIdx = 0'i32

  let outL = outBuf.channelPtr(0, frames)
  if not outL.isNil:
    # Штатный путь. Моно: правый канал указывает на тот же буфер, поэтому
    # ядро складывает L и R — обычная свёртка стерео в моно. Компенсировать
    # её громкость должен микшер: узел не знает, что стоит дальше по графу.
    let outR = if channels >= 2: outBuf.channelPtr(1, frames) else: outL
    let bend = midi.bend.advance(frames)
    let modCents = midi.modCents.advance(frames)
    instRenderPlanar(abi, midi, outL, outR, frames, q, evIdx, bend, modCents)
    return

  if scratch.isNil:
    return

  # Один массив: левая половина — L, правая — R (ёмкость InstScratchFrames
  # на канал). Индексация через UncheckedArray — указатель на канал сам
  # по себе не индексируется.
  let arena = cast[ptr UncheckedArray[float32]](scratch)
  let arenaR = cast[ptr UncheckedArray[float32]](offsetPtr(scratch, InstScratchFrames))
  let scratchL = scratch
  let scratchR = offsetPtr(scratch, InstScratchFrames)

  var pos = 0'i32
  while pos < frames:
    let part = min(InstScratchFrames, frames - pos)
    let bend = midi.bend.advance(part)
    let modCents = midi.modCents.advance(part)

    # Ядро ПРИБАВЛЯЕТ к буферу, а `scratch` — общий на все блоки ноды
    # (в отличие от outBuf, который нода только что очистила). Без этой
    # очистки остаток прошлого блока копился бы: у инструмента, стоящего
    # последним в цепочке (мастер-шина, interleaved-выход), со второго
    # блока нарастал «грязный» призвук. Ошибка была не слышна на planar-
    # пути и в первом блоке — отсюда её долгая жизнь.
    var k = 0'i32
    while k < part:
      arena[k] = 0.0f
      arenaR[k] = 0.0f
      inc k

    instRenderPlanar(abi, midi, scratchL, scratchR, part, q, evIdx,
                     bend, modCents)

    var i = 0'i32
    while i < part:
      let frame = pos + i
      outBuf.setSampleAt(0, frame, arena[i])
      if channels >= 2:
        outBuf.setSampleAt(1, frame, arena[InstScratchFrames + i])
      inc i
    pos += part

{.pop.}
