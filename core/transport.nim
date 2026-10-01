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

proc samplesPerBar*(t: var Transport): float64 {.inline.} =
  ## Вычисляет количество сэмплов на один такт с учётом TimeSignature.
  ## Control Thread helper.
  let spq = t.samplesPerQuarter()
  # Корректный учет denominator (например, для 6/8 или 3/4)
  let quarterNotesPerBar = float64(t.timeSignature.numerator) * 4.0 / float64(t.timeSignature.denominator)
  return spq * quarterNotesPerBar

proc sampleToBarBeatTick*(t: var Transport, samplePos: int64): tuple[bar, beat, tick: int32] =
  ## Конвертирует сэмпловую позицию в Bar:Beat:Tick (960 PPQ).
  ## Control Thread / UI helper.
  let spBar = t.samplesPerBar()
  let spQuarter = t.samplesPerQuarter()
  
  if spBar <= 0.0 or spQuarter <= 0.0:
    return (1, 1, 0)
  
  # Точная float64 математика — без накопления ошибки от int truncation
  let barFloat = float64(samplePos) / spBar
  let bar = int32(barFloat) + 1
  let remainderSamples = float64(samplePos) - (float64(bar - 1) * spBar)
  
  let beatFloat = remainderSamples / spQuarter
  let beat = int32(beatFloat) + 1
  let beatRemainderSamples = remainderSamples - (float64(beat - 1) * spQuarter)
  
  let tick = int32((beatRemainderSamples / spQuarter) * 960.0)
  
  return (bar, beat, tick)

proc barBeatTickToSample*(t: var Transport, bar, beat, tick: int32): int64 =
  ## Конвертирует Bar:Beat:Tick (960 PPQ) в абсолютную позицию в сэмплах.
  ## Control Thread / UI helper.
  let spBar = t.samplesPerBar()
  let spQuarter = t.samplesPerQuarter()
  
  result = int64(float64(bar - 1) * spBar)
  result += int64(float64(beat - 1) * spQuarter)
  result += int64((float64(tick) / 960.0) * float64(spQuarter))

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
  
  result.sampleRate = t.sampleRate
  result.tempo = bpm
  result.timeSignature = t.timeSignature
  result.samplePosition = pos
  result.isPlaying = t.isPlaying()
  
  let (bar, beat, tick) = t.sampleToBarBeatTick(pos)
  result.barPosition = float64(bar - 1) + 
    (float64(beat - 1) + float64(tick) / 960.0) / float64(t.timeSignature.numerator)
  result.beatPosition = float64(bar - 1) * float64(t.timeSignature.numerator) + 
    float64(beat - 1) + float64(tick) / 960.0
  result.tickPosition = tick
  result.quarterNotePosition = if spQuarter > 0.0: float64(pos) / spQuarter else: 0.0
  
  result.barsToSeconds = if spBar > 0.0 and t.sampleRate > 0.0: 
    spBar / float64(t.sampleRate) else: 0.0
  result.secondsToBars = if spBar > 0.0 and t.sampleRate > 0.0: 
    float64(t.sampleRate) / spBar else: 0.0