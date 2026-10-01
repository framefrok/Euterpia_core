## ============================================================================
## transport.nim — Control-Plane Transport State
## ============================================================================
##
## ИСТОЧНИК ИСТИНЫ для UI и управляющей логики (Control Plane).
## НЕ читается напрямую из Real-Time Audio Callback (Audio Thread).
##
## Архитектурное разделение:
##   - `transport.Transport`: высокоуровневое состояние (UI, такты, лупы, темп).
##   - `audio_engine.TransportRuntime`: компактное состояние внутри аудио-потока,
##     синхронизируемое исключительно через lock-free команды движка.
##
## Любые изменения состояния в этом объекте должны сопровождаться отправкой
## соответствующих команд в AudioEngine:
##   play()               -> postPlay()           (cmdTransportPlay)
##   stop()               -> postStop()           (cmdTransportStop)
##   pause()              -> postPause()          (cmdTransportPause)
##   setTempo(bpm)        -> postSetTempo(bpm)    (cmdTransportSetTempo)
##   setPosition(samples) -> postSeek(samples)    (cmdTransportSeek)
##   setLoop(...)         -> postSetLoop(...)     (cmdTransportSetLoop)
## ============================================================================

import std/atomics

type
  TransportState* = enum
    tsStopped
    tsPlaying
    tsRecording
    tsPaused

  TimeSignature* = object
    numerator*: int32
    denominator*: int32

  ## Снимок состояния транспорта для UI, визуализаторов и фоновых задач.
  ## НЕ используется внутри RT Audio Callback.
  TransportSnapshot* = object
    sampleRate*: float32
    tempo*: float32
    timeSignature*: TimeSignature
    samplePosition*: int64
    barPosition*: float64
    beatPosition*: float64
    tickPosition*: int32
    quarterNotePosition*: float64
    barsToSeconds*: float64
    secondsToBars*: float64
    isPlaying*: bool

  ## Transport — control-plane объект.
  ##
  ## ИСТОЧНИК ИСТИНЫ для UI. НЕ читается из audio thread.
  ## Изменения в этом объекте должны сопровождаться постингом
  ## соответствующих команд в AudioEngine:
  ##   play()              -> postPlay()
  ##   stop()              -> postStop()
  ##   pause()             -> postPause()
  ##   setTempo(bpm)       -> postSetTempo(bpm)
  ##   setPosition(sample) -> postSeekSamples(sample)
  ##   setLoop(...)        -> postSetLoop(...)
  ##
  ## Внутри AudioEngine используется собственный TransportRuntime,
  ## который обновляется из этих команд.
  Transport* = object
    state*: Atomic[TransportState]
    tempo*: Atomic[float32]
    timeSignature*: TimeSignature
    sampleRate*: float32
    samplePosition*: Atomic[int64]
    loopEnabled*: Atomic[bool]
    loopStart*: Atomic[int64]
    loopEnd*: Atomic[int64]
    metronomeEnabled*: Atomic[bool]

proc initTransport*(sampleRate: float32 = 48000.0f): Transport =
  ## Инициализация control-plane транспорта значениями по умолчанию.
  ## Вызывается из Control Thread при старте приложения/движка.
  result.state.store(tsStopped, moRelaxed)
  result.tempo.store(120.0f, moRelaxed)
  result.timeSignature = TimeSignature(numerator: 4, denominator: 4)
  result.sampleRate = sampleRate
  result.samplePosition.store(0, moRelaxed)
  result.loopEnabled.store(false, moRelaxed)
  result.loopStart.store(0, moRelaxed)
  result.loopEnd.store(0, moRelaxed)
  result.metronomeEnabled.store(false, moRelaxed)

# ============================================================================
# Time helpers (Control Thread / Offline math)
# ============================================================================

proc samplesPerQuarter*(t: var Transport): float64 {.inline.} =
  ## Вычисляет количество сэмплов на одну четвертную ноту при текущем темпе.
  ## Control Thread helper.
  let bpm = float64(t.tempo.load(moRelaxed))
  if bpm <= 0.0: return 0.0
  return (float64(t.sampleRate) * 60.0) / bpm

proc beatsPerBar*(t: var Transport): float64 {.inline.} =
  ## Сколько долей (в единицах знаменателя) в такте.
  ## При некорректном знаменателе считаем его четвёртым: деление на ноль
  ## в UI-хелпере хуже, чем «размер 4/4 по умолчанию».
  let den = t.timeSignature.denominator
  let d = if den > 0: float64(den) else: 4.0
  float64(t.timeSignature.numerator) * 4.0 / d

proc samplesPerBeat*(t: var Transport): float64 {.inline.} =
  ## Сэмплов на долю. Именно ДОЛЯ (знаменатель размера), а не четверть:
  ## в 6/8 доля — восьмая, и BBT обязан считать именно их (issue #58).
  let den = if t.timeSignature.denominator > 0: t.timeSignature.denominator else: 4'i32
  t.samplesPerQuarter() * (4.0 / float64(den))

proc ticksPerBeat*(t: var Transport): int32 {.inline.} =
  ## Тиков на долю при разрешении 960 PPQ.
  let den = if t.timeSignature.denominator > 0: t.timeSignature.denominator else: 4'i32
  let v = 960'i32 * 4'i32 div den
  if v > 0: v else: 960'i32

proc samplesPerBar*(t: var Transport): float64 {.inline.} =
  ## Вычисляет количество сэмплов на один такт с учётом TimeSignature.
  ## Control Thread helper.
  t.samplesPerQuarter() * t.beatsPerBar()

proc sampleToBarBeatTick*(t: var Transport, samplePos: int64): tuple[bar, beat, tick: int32] =
  ## Конвертирует сэмпловую позицию в Bar:Beat:Tick.
  ##
  ## `beat` — доля в единицах знаменателя размера (в 6/8 это восьмые, а не
  ## четверти), `tick` — позиция внутри доли при 960 PPQ, пересчитанных на
  ## долю (для 6/8 это 480 тиков на долю). Control Thread / UI helper.
  let spBar = t.samplesPerBar()
  let spBeat = t.samplesPerBeat()
  let tpb = t.ticksPerBeat()

  if spBar <= 0.0 or spBeat <= 0.0 or tpb <= 0:
    return (1, 1, 0)

  # Точная float64 математика — без накопления ошибки от int truncation
  let barFloat = float64(samplePos) / spBar
  let bar = int32(barFloat) + 1
  let remainderSamples = float64(samplePos) - (float64(bar - 1) * spBar)

  let beatFloat = remainderSamples / spBeat
  let beat = int32(beatFloat) + 1
  let beatRemainderSamples = remainderSamples - (float64(beat - 1) * spBeat)

  let tick = int32((beatRemainderSamples / spBeat) * float64(tpb))

  return (bar, beat, tick)

proc barBeatTickToSample*(t: var Transport, bar, beat, tick: int32): int64 =
  ## Конвертирует Bar:Beat:Tick в абсолютную позицию в сэмплах.
  ## Обратная к `sampleToBarBeatTick` (см. issue #58). Control Thread helper.
  let spBar = t.samplesPerBar()
  let spBeat = t.samplesPerBeat()
  let tpb = t.ticksPerBeat()

  if spBar <= 0.0 or spBeat <= 0.0 or tpb <= 0:
    return 0'i64

  result = int64(float64(bar - 1) * spBar)
  result += int64(float64(beat - 1) * spBeat)
  result += int64((float64(tick) / float64(tpb)) * spBeat)

# ============================================================================
# State mutations (Вызываются из Control Thread)
# ============================================================================

proc play*(t: var Transport) =
  ## Переводит control-plane состояние в tsPlaying.
  ## Control Thread. Должно сопровождаться отправкой `cmdTransportPlay` в AudioEngine.
  t.state.store(tsPlaying, moRelease)

proc stop*(t: var Transport) =
  ## Останавливает воспроизведение и сбрасывает позицию в 0.
  ## Control Thread. Должно сопровождаться отправкой `cmdTransportStop` в AudioEngine.
  t.state.store(tsStopped, moRelease)
  t.samplePosition.store(0, moRelease)

proc pause*(t: var Transport) =
  ## Приостанавливает воспроизведение без сброса позиции.
  ## Control Thread. Должно сопровождаться отправкой `cmdTransportPause` в AudioEngine.
  t.state.store(tsPaused, moRelease)

proc record*(t: var Transport) =
  ## Переводит транспорт в режим записи.
  ## Control Thread. Должно сопровождаться отправкой команды записи в AudioEngine.
  t.state.store(tsRecording, moRelease)

proc setPosition*(t: var Transport, samplePos: int64) =
  ## Устанавливает позицию курсора воспроизведения.
  ## Control Thread. Должно сопровождаться отправкой `cmdTransportSeek` в AudioEngine.
  t.samplePosition.store(samplePos, moRelease)

proc setTempo*(t: var Transport, bpm: float32) =
  ## Устанавливает темп в BPM.
  ## Control Thread. Должно сопровождаться отправкой `cmdTransportSetTempo` в AudioEngine.
  t.tempo.store(bpm, moRelease)

proc setLoop*(t: var Transport, enabled: bool, startSample, endSample: int64) =
  ## Настраивает границы и активность цикла (loop).
  ## Control Thread. Должно сопровождаться отправкой `cmdTransportSetLoop` в AudioEngine.
  t.loopEnabled.store(enabled, moRelease)
  t.loopStart.store(startSample, moRelease)
  t.loopEnd.store(endSample, moRelease)

proc advancePosition*(t: var Transport, blockSamples: int32) {.inline.} =
  ## Сдвигает позицию транспорта вперед с учетом возможного зацикливания.
  ## Control Thread / Offline processing helper.
  ## ВНИМАНИЕ: В real-time режиме позицию в аудио-потоке продвигает сам AudioEngine.
  var pos = t.samplePosition.load(moRelaxed)
  pos += int64(blockSamples)
  
  if t.loopEnabled.load(moRelaxed):
    let loopStart = t.loopStart.load(moRelaxed)
    let loopEnd = t.loopEnd.load(moRelaxed)
    if loopEnd > loopStart:
      let loopLen = loopEnd - loopStart
      if pos >= loopEnd:
        # Корректная обработка wrap-around, даже если blockSize > loopLength
        pos = loopStart + ((pos - loopStart) mod loopLen)
      elif pos < loopStart:
        pos = loopEnd - ((loopStart - pos) mod loopLen)
  
  t.samplePosition.store(pos, moRelease)

proc isPlaying*(t: var Transport): bool {.inline.} =
  ## Возвращает true, если transport находится в режиме tsPlaying или tsRecording.
  ## Control Thread / UI reader.
  let s = t.state.load(moAcquire)
  return s == tsPlaying or s == tsRecording

# ============================================================================
# Snapshot — срез состояния для UI и фоновых задач (Control-Plane)
# ============================================================================

proc getSnapshot*(t: var Transport): TransportSnapshot =
  ## Создаёт снимок текущего состояния транспорта для UI, отрисовки таймлайна
  ## и фоновых задач. НЕ вызывать из Real-Time Audio Callback (DSP thread).
  let pos = t.samplePosition.load(moRelaxed)
  let bpm = t.tempo.load(moRelaxed)
  let spQuarter = t.samplesPerQuarter()
  let spBar = t.samplesPerBar()
  let tpb = t.ticksPerBeat()
  # Долей в такте = числитель размера: `beat` из sampleToBarBeatTick уже в
  # единицах знаменателя, поэтому делить на что-то другое нельзя (#58).
  let beatsPerBar =
    if t.timeSignature.numerator > 0: float64(t.timeSignature.numerator) else: 1.0

  result.sampleRate = t.sampleRate
  result.tempo = bpm
  result.timeSignature = t.timeSignature
  result.samplePosition = pos
  result.isPlaying = t.isPlaying()

  let (bar, beat, tick) = t.sampleToBarBeatTick(pos)
  let beatFraction =
    if tpb > 0: float64(tick) / float64(tpb) else: 0.0
  let beatsSinceBarStart = float64(beat - 1) + beatFraction
  result.barPosition = float64(bar - 1) + beatsSinceBarStart / beatsPerBar
  result.beatPosition = float64(bar - 1) * beatsPerBar + beatsSinceBarStart
  result.tickPosition = tick
  result.quarterNotePosition = if spQuarter > 0.0: float64(pos) / spQuarter else: 0.0
  
  result.barsToSeconds = if spBar > 0.0 and t.sampleRate > 0.0: 
    spBar / float64(t.sampleRate) else: 0.0
  result.secondsToBars = if spBar > 0.0 and t.sampleRate > 0.0: 
    float64(t.sampleRate) / spBar else: 0.0