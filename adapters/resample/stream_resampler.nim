# adapters/resample/stream_resampler.nim
#
# Адаптер ресемплинга за `core/src_api.nim` (issue #8).
#
# Почему свой polyphase-ресемплер, а не libsamplerate/speexdsp:
#   * ядро не тянет внешних зависимостей (§8): адаптер обязан работать на
#     «чистой» машине и в CI без пакетов — так же, как miniaudio (#31);
#   * контракт `src_api` не меняется, если позже появится адаптер на
#     libsamplerate: Core увидит другую таблицу методов и ничего больше.
#
# Алгоритм: оконный sinc (Hann-окно, 24 отсчёта) с нормировкой суммы
# коэффициентов на каждый выходной отсчёт. Нормировка даёт единичный
# коэффициент передачи на DC независимо от дробной фазы — без неё на
# медленных sweep'ах появлялась бы амплитудная модуляция.
#
# Realtime-дисциплина:
#   * вся память (состояние + история) выделяется в `createConverter`;
#   * `process` не аллоцирует, не блокируется и не бросает исключений;
#   * история хранится ПО КАНАЛАМ и обновляется после блока, поэтому
#     стыки блоков не дают щелчков.
#
# MANIFEST §8, §9, §41, §42, §78.

import std/math
import src_api

{.push raises: [].}

const
  SrcBackendName* = "polyphase-sinc"

  SrcTaps* = 24
    ## Число отсчётов окна. 24 — компромисс: подавление зеркал лучше 60 дБ
    ## на типовых 44.1↔48 кГц, а стоимость — 24 умножения на отсчёт.

  SrcHalfTaps = SrcTaps div 2

  SrcMaxChannels* = 2
    ## Проект стерео (signal_types.MaxAudioChannels); контракт допускает
    ## меньше, больше — ошибка `seBadChannels`.

  SrcMinRatio = 1.0 / 16.0
  SrcMaxRatio = 16.0
    ## Отношение частот вне этого диапазона — почти наверняка ошибка
    ## вызывающего (перепутаны Гц и кГц), а не музыкальный сценарий.

  SrcMaxInputFrames* = 8192
    ## Верхняя граница входного блока: по ней выделяется история, поэтому
    ## `process` обходится без аллокаций.

type
  SrcState = object
    ## Состояние потока. POD: лежит в shared-куче, GC-полей нет.
    inRate: float64
    outRate: float64
    ratio: float64        ## inRate / outRate: сколько входных кадров на выходной
    channels: int32
    maxInFrames: int32
    pos: float64
      ## Позиция следующего выходного отсчёта в расширенном буфере
      ## [history(taps) + input]. Начало — taps - 1: все taps доступны.
    history: array[SrcMaxChannels, array[SrcTaps, float32]]

  SrcImpl = object
    initCalls: int32

proc implOf(api: ptr SrcApi): ptr SrcImpl {.inline.} =
  cast[ptr SrcImpl](api.impl)

proc stateOf(handle: SrcHandle): ptr SrcState {.inline.} =
  cast[ptr SrcState](handle)

proc isFiniteRate(rate: float64): bool {.inline.} =
  ## `rate != rate` — NaN; сравнение с 0.0 отсекает Inf на обеих сторонах.
  rate == rate and rate > 0.0 and rate < 1.0e9

# ==============================================================================
# Ядро: оконный sinc
# ==============================================================================

proc sincSample(st: ptr SrcState; ch: int32; idx: int; inFrames: int32;
                src: ptr UncheckedArray[float32];
                srcStride: int32): float32 {.inline.} =
  ## Значение расширенного буфера по индексу `idx`, где [0, taps) —
  ## история, [taps, taps + inFrames) — текущий вход.
  if idx < SrcTaps:
    let h = idx
    if h < 0: return 0.0f
    return st.history[ch][h]
  let frame = idx - SrcTaps
  if frame >= inFrames:
    # Край блока: продолжаем последним доступным отсчётом, а не нулём.
    # Ноль дал бы на границе блока импульс (слышимый щелчок).
    if inFrames <= 0:
      return 0.0f
    return src[ch * srcStride + (inFrames - 1)]
  src[ch * srcStride + frame]

proc filterAt(st: ptr SrcState; ch: int32; pos: float64; inFrames: int32;
              src: ptr UncheckedArray[float32]; srcStride: int32): float32 =
  ## Один выходной отсчёт: сумма taps входных, взвешенных оконным sinc.
  ## Коэффициенты нормируются суммой — единичный gain на DC.
  let center = int(floor(pos))
  let frac = pos - float64(center)
  let cutoff =
    if st.inRate > st.outRate: st.outRate / st.inRate
    else: 1.0
  var acc = 0.0'f64
  var weightSum = 0.0'f64
  var k = -SrcHalfTaps + 1
  while k <= SrcHalfTaps:
    let d = frac - float64(k)
    # Окно Ханна по расстоянию в отсчётах входа.
    let w = 0.5 + 0.5 * cos(PI * d / float64(SrcHalfTaps + 1))
    let x = PI * d * cutoff
    let sinc =
      if abs(x) < 1.0e-12: 1.0
      else: sin(x) / x
    let coeff = w * sinc * cutoff
    acc += float64(sincSample(st, ch, center + k, inFrames, src, srcStride)) *
           coeff
    weightSum += coeff
    inc k
  if abs(weightSum) > 1.0e-12:
    float32(acc / weightSum)
  else:
    0.0f

proc updateHistory(st: ptr SrcState; inFrames: int32;
                   src: ptr UncheckedArray[float32]; srcStride: int32) =
  ## Сдвинуть историю на `inFrames` и запомнить хвост входа.
  if inFrames <= 0:
    return
  if inFrames >= int32(SrcTaps):
    for ch in 0 ..< int(st.channels):
      let base = ch * int(srcStride) + int(inFrames) - SrcTaps
      for i in 0 ..< SrcTaps:
        st.history[ch][i] = src[base + i]
    return
  let shift = int(inFrames)
  for ch in 0 ..< int(st.channels):
    for i in 0 ..< SrcTaps - shift:
      st.history[ch][i] = st.history[ch][i + shift]
    let base = ch * int(srcStride)
    for i in 0 ..< shift:
      st.history[ch][SrcTaps - shift + i] = src[base + i]

# ==============================================================================
# Таблица методов
# ==============================================================================

proc resampleCreate(
  api: ptr SrcApi;
  inRate, outRate: float64;
  channels: int32;
  maxInputFrames: int32
): SrcHandle {.cdecl, raises: [], gcsafe.} =
  if not isFiniteRate(inRate) or not isFiniteRate(outRate):
    return nil
  let ratio = inRate / outRate
  if ratio < SrcMinRatio or ratio > SrcMaxRatio:
    return nil
  if channels <= 0 or channels > int32(SrcMaxChannels):
    return nil
  if maxInputFrames < int32(SrcTaps) or maxInputFrames > int32(SrcMaxInputFrames):
    return nil

  let st = cast[ptr SrcState](allocShared0(sizeof(SrcState)))
  if st.isNil:
    return nil
  st.inRate = inRate
  st.outRate = outRate
  st.ratio = ratio
  st.channels = channels
  st.maxInFrames = maxInputFrames
  st.pos = float64(SrcTaps - 1)
  cast[SrcHandle](st)

proc resampleDestroy(api: ptr SrcApi; handle: SrcHandle)
    {.cdecl, raises: [], gcsafe.} =
  if handle.isNil:
    return
  deallocShared(cast[pointer](stateOf(handle)))

proc resampleReset(api: ptr SrcApi; handle: SrcHandle)
    {.cdecl, raises: [], gcsafe.} =
  if handle.isNil:
    return
  let st = stateOf(handle)
  st.pos = float64(SrcTaps - 1)
  for ch in 0 ..< int(st.channels):
    for i in 0 ..< SrcTaps:
      st.history[ch][i] = 0.0f

proc resampleProcess(
  api: ptr SrcApi;
  handle: SrcHandle;
  src: ptr UncheckedArray[float32];
  srcStride: int32;
  inFrames: int32;
  dst: ptr UncheckedArray[float32];
  dstStride: int32;
  maxOutFrames: int32
): int32 {.cdecl, raises: [], gcsafe.} =
  if handle.isNil:
    return 0
  let st = stateOf(handle)
  if src.isNil or dst.isNil or inFrames <= 0 or maxOutFrames <= 0:
    return 0
  if inFrames > st.maxInFrames:
    # Контракт createConverter: блок больше заявленного не обслуживается
    # (история рассчитана на maxInputFrames). Лучше отказать, чем читать
    # за границей буфера.
    return 0

  var produced = 0'i32
  # Верхняя граница позиции: последний выход, для которого все taps-1
  # «будущих» отсчётов ещё лежат внутри текущего блока.
  let limit = float64(SrcTaps + inFrames - SrcHalfTaps - 1)
  while produced < maxOutFrames and st.pos < limit:
    for ch in 0 ..< int(st.channels):
      dst[ch * dstStride + produced] =
        filterAt(st, int32(ch), st.pos, inFrames, src, srcStride)
    st.pos += st.ratio
    inc produced

  # Координата расширенного буфера на следующем блоке сдвигается на
  # inFrames: новый индекс 0 — это старый inFrames (хвост ушёл в историю).
  st.pos -= float64(inFrames)
  updateHistory(st, inFrames, src, srcStride)
  produced

proc resampleLatency(api: ptr SrcApi; handle: SrcHandle): int32
    {.cdecl, raises: [], gcsafe.} =
  if handle.isNil:
    return 0
  let st = stateOf(handle)
  # Половина окна в кадрах выхода: входные taps/2 переводятся в выходные
  # делением на ratio (= in/out).
  int32(float64(SrcHalfTaps) / st.ratio + 0.5)

proc resampleInit(api: ptr SrcApi; log: ptr Logger): SrcError
    {.cdecl, raises: [], gcsafe.} =
  if api.isNil:
    return seUnavailable
  let impl = implOf(api)
  if impl.isNil:
    return seUnavailable
  inc impl.initCalls
  seOk

proc resampleShutdown(api: ptr SrcApi) {.cdecl, raises: [], gcsafe.} =
  discard

proc newSrcApi*(): ptr SrcApi =
  ## Создать таблицу методов адаптера. Владелец — вызывающий,
  ## освобождение — `freeSrcApi`.
  let api = cast[ptr SrcApi](allocShared0(sizeof(SrcApi)))
  if api.isNil:
    return nil
  let impl = cast[ptr SrcImpl](allocShared0(sizeof(SrcImpl)))
  if impl.isNil:
    deallocShared(cast[pointer](api))
    return nil
  api.backendName = SrcBackendName
  api.impl = impl
  api.init = resampleInit
  api.shutdown = resampleShutdown
  api.createConverter = resampleCreate
  api.destroyConverter = resampleDestroy
  api.reset = resampleReset
  api.process = resampleProcess
  api.latencyFrames = resampleLatency
  api

proc freeSrcApi*(api: ptr SrcApi) =
  if api.isNil:
    return
  let impl = implOf(api)
  if not impl.isNil:
    deallocShared(cast[pointer](impl))
  deallocShared(cast[pointer](api))

{.pop.}
