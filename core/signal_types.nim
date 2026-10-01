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

{.pop.}