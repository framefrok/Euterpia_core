# signal_types.nim
import std/math

{.push raises: [].}

const
  MaxBlockSize* = 4096
  MaxBlockEvents* = 128

type
  SignalType* = enum
    sigAudio
    sigControl
    sigEvent

  RealtimeEventKind* = enum
    evNoteOn
    evNoteOff
    evCC
    evPitchBend
    evAftertouch
    evProgramChange
    evParamChange
    evTrigger
    evTransport

  RealtimeEvent* = object
    frameOffset*: uint32
    subFrame*: float32
    kind*: RealtimeEventKind
    port*: uint8
    channel*: uint8
    data*: array[4, float32]

  EventQueue* = object
    count*: int32
    events* {.align: 64.}: array[MaxBlockEvents, RealtimeEvent]

  AudioBuffer* = object
    data*: ptr UncheckedArray[float32]
    channels*: int32
    frames*: int32
    stride*: int32

  PAudioBuffer* = ptr AudioBuffer

  MonoBuffer* = object
    samples* {.align: 64.}: array[MaxBlockSize, float32]

  StereoBuffer* = object
    left* {.align: 64.}: array[MaxBlockSize, float32]
    right* {.align: 64.}: array[MaxBlockSize, float32]

  ParamSmoother* = object
    target*: float32
    current*: float32
    coeff*: float32

# ==============================================================================
# EventQueue Helpers
# ==============================================================================

proc clearEvents*(q: ptr EventQueue) {.cdecl, inline.} =
  q.count = 0

proc pushEvent*(q: ptr EventQueue, ev: RealtimeEvent): bool {.cdecl, inline.} =
  if q.count < MaxBlockEvents:
    q.events[q.count] = ev
    inc q.count
    return true
  return false

proc sortEvents*(q: ptr EventQueue) {.cdecl.} =
  for i in 1 ..< q.count:
    var j = i
    while j > 0:
      let a = q.events[j-1]
      let b = q.events[j]
      if a.frameOffset > b.frameOffset or 
         (a.frameOffset == b.frameOffset and a.subFrame > b.subFrame):
        q.events[j-1] = b
        q.events[j] = a
        dec j
      else:
        break

proc clipEvents*(q: ptr EventQueue, maxFrames: uint32) {.cdecl.} =
  var writeIdx = 0
  for i in 0 ..< q.count:
    if q.events[i].frameOffset < maxFrames:
      if writeIdx != i:
        q.events[writeIdx] = q.events[i]
      inc writeIdx
  q.count = writeIdx.int32

proc findEventAtFrame*(q: ptr EventQueue, frame: uint32): int32 {.cdecl.} =
  ## Индекс первого события, чей `frameOffset` НЕ РАНЬШЕ `frame`.
  ##
  ## Контракт (issue #80):
  ##   * `>= 0` — индекс в `q.events[0 ..< q.count]`;
  ##   * `-1` — событий не раньше `frame` нет (все раньше ИЛИ очередь пуста).
  ##
  ## Это позиция вставки по времени, а не «ошибка»: -1 здесь равнозначен
  ## «все события уже в прошлом относительно кадра». Порядок событий
  ## подразумевается отсортированным (`sortEvents`).
  for i in 0 ..< q.count:
    if q.events[i].frameOffset >= frame:
      return i.int32
  return -1

# ==============================================================================
# ParamSmoother
# ==============================================================================

const
  # Контракт времени сглаживания EUTERPIA:
  #   timeMs — это время, за которое сглаживатель проходит 99% пути
  #   от текущего значения к целевому.
  #
  # Важно: НЕ путать с постоянной времени one-pole. Классическая формула
  # exp(-1/(timeMs*sr)) даёт только 63% пути за timeMs и никогда точно
  # не сходится: при timeMs=10 и 1000 сэмплах параметр залипал на 87.5%.
  # Здесь коэффициент подобран так, чтобы остаточная ошибка была 1%
  # ровно через timeMs.
  SmootherSettleFraction* = 0.01'f64

  # Ниже этого порога current считается равным target.
  # Это закрывает хвост сглаживания и не даёт FPU уйти в denormal-режим
  # (denormals медленные и по-разному ведут себя на разных CPU).
  #
  # Порог относительный к масштабу target (но не меньше абсолютного):
  # рекурентность current = target - coeff*diff в float32 застывает,
  # когда diff опускается до ~50 ULP target (у target=1.0 это 3e-6,
  # у target=1000 это 3e-3) — дальше арифметика не двигается вовсе.
  # Порог обязан лежать ВЫШЕ этой границы округления, иначе снап
  # никогда не сработает, а контракт «current == target» не закроется.
  SmootherSnapEpsilon* = 1e-5'f32

proc snapEps*(target: float32): float32 {.inline.} =
  ## Порог снапа для данного масштаба цели.
  SmootherSnapEpsilon * (if abs(target) > 1.0f: abs(target) else: 1.0f)

proc initSmoother*(timeMs: float32, sampleRate: float32, initialVal: float32 = 0.0f): ParamSmoother {.inline.} =
  result.target = initialVal
  result.current = initialVal

  if timeMs <= 0.001f or sampleRate <= 0.0f:
    # Нулевое время сглаживания = мгновенный переход.
    result.coeff = 0.0f
  else:
    let settleSamples = float64(timeMs) * 0.001 * float64(sampleRate)
    # coeff ^ settleSamples == SmootherSettleFraction
    result.coeff = float32(exp(ln(SmootherSettleFraction) / settleSamples))

proc process*(s: var ParamSmoother): float32 {.cdecl, inline.} =
  ## Один шаг = один сэмпл: ошибка умножается на coeff (без смены знака).
  let diff = s.target - s.current

  if abs(diff) <= snapEps(s.target):
    s.current = s.target
  else:
    s.current = s.target - s.coeff * diff

  return s.current

proc advance*(s: var ParamSmoother; samples: int32): float32 {.cdecl, inline.} =
  ## Продвижение на samples сэмплов за один вызов.
  ##
  ## Нода вызывает его один раз на блок: сглаживание считается
  ## в сэмплах, а не в «типах» — звук не зависит от blockSize
  ## (128 против 4096 даёт одинаковый результат). Математически
  ## эквивалент samples вызовам process(), но без цикла:
  ## ошибка умножается на coeff^samples.
  if samples <= 0:
    return s.current

  let diff = s.target - s.current

  if abs(diff) <= snapEps(s.target):
    s.current = s.target
  else:
    s.current = s.target - pow(s.coeff, samples.float32) * diff

  return s.current

proc setTarget*(s: var ParamSmoother, val: float32) {.cdecl, inline.} =
  s.target = val

# ==============================================================================
# Per-sample ramp (issue #386)
# ==============================================================================
#
# Проблема: ноды вызывали `advance(frames)` ОДИН раз на блок и применяли это
# ОДНО значение ко ВСЕМУ блоку. Переход параметра становился ступенькой
# размером в блок, а его слышимая форма зависела от blockSize (64 vs 1024).
#
# Решение: разделить «продвижение состояния» и «интерполяцию». `beginRamp`
# продвигает состояние на весь блок (для следующего блока) и возвращает
# генератор, чей `next()` даёт ТОЧНОЕ per-sample значение той же экспоненты.
# Нода применяет значение по одному сэмплу — переход один и тот же при любом
# blockSize, потому что каждый сэмпл делает ровно один шаг one-pole.

type
  ParamRamp* = object
    ## Генератор per-sample значений сглаживателя на один блок.
    target: float32   ## цель (не меняется внутри блока)
    diff: float32     ## target - current ДО очередного шага
    coeff: float32    ## коэффициент one-pole
    eps: float32      ## порог снапа для этой цели

proc beginRamp*(s: var ParamSmoother; samples: int32): ParamRamp {.cdecl, inline.} =
  ## Продвинуть состояние сглаживателя на `samples` (чтобы следующий блок
  ## начался со значения конца текущего) и вернуть per-sample генератор,
  ## воспроизводящий РОВНО ту же траекторию, что `samples` вызовов `process`.
  result.target = s.target
  result.coeff = s.coeff
  result.eps = snapEps(s.target)
  result.diff = s.target - s.current
  discard s.advance(samples)

proc next*(r: var ParamRamp): float32 {.cdecl, inline.} =
  ## Значение сглаживателя на следующем сэмпле блока. Ровно один шаг one-pole,
  ## поэтому результат не зависит от размера блока.
  if abs(r.diff) <= r.eps:
    r.diff = 0.0f
    return r.target
  let nd = r.coeff * r.diff
  let v = r.target - nd
  r.diff = nd
  v

{.pop.}