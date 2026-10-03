# core/spectrum.nim
#
# Спектральные примитивы для анализа звука (issue #290, инспектор аудио):
# окна, radix-2 БПФ и спектр мощности кадра. Отдельный модуль, а не часть
# аудио-инспектора, по одной причине: FFT — самостоятельный, тщательно
# тестируемый кирпич, и его хочется проверять отдельно от детекторов.
#
# Почему своя БПФ, а не библиотека:
#   * ядро не тянет внешних зависимостей (тот же принцип, что у WAV/MIDI);
#   * результат обязан быть детерминированным и одинаковым на всех
#     платформах — golden-отчёт инспектора не должен «плыть» от libm;
#   * нужен только прямой спектр степени двойки — это ~40 строк.
#
# Модуль ничего не знает про Core, ноды и realtime: чистая математика над
# буфером. Вызов на control/offline-пути, не в audio thread.

import std/math

{.push raises: [].}

const
  SpectrumTau* = 6.28318530717958647692
    ## 2π: в `std/math` нет константы типа float64 с таким именем.

proc nextPow2*(n: int): int =
  ## Ближайшая степень двойки, не меньшая `n` (минимум 1).
  result = 1
  while result < n:
    result = result shl 1

proc hannWindow*(i, n: int): float32 =
  ## Окно Ханна. Убирает утечку спектра, из-за которой слабый узкий тон
  ## (жужжание) растворялся бы в соседних бинах.
  if n <= 1:
    return 1.0f
  0.5f - 0.5f * cos(SpectrumTau * float64(i) / float64(n - 1)).float32

proc fftRadix2*(re, im: var seq[float32]) =
  ## Прямое БПФ на месте (iterative Cooley-Tukey). `re`/`im` — степени
  ## двойки одинаковой длины. `im` на входе обычно нули.
  let n = re.len
  if n != im.len or n <= 1:
    return

  # Перестановка по битам: без неё «бабочки» работают не с теми парами.
  var j = 0
  for i in 0 ..< n - 1:
    if i < j:
      swap re[i], re[j]
      swap im[i], im[j]
    var m = n shr 1
    while m >= 1 and j >= m:
      j -= m
      m = m shr 1
    j += m

  var len = 2
  while len <= n:
    let ang = SpectrumTau / float64(len)
    let wr = cos(ang).float32
    let wi = sin(ang).float32
    let half = len shr 1
    var i = 0
    while i < n:
      var cr = 1.0f
      var ci = 0.0f
      for k in 0 ..< half:
        let jj = i + k
        let jh = jj + half
        let ur = re[jj]
        let ui = im[jj]
        let xr = re[jh]
        let xi = im[jh]
        let vr = xr * cr - xi * ci
        let vi = xr * ci + xi * cr
        re[jj] = ur + vr
        im[jj] = ui + vi
        re[jh] = ur - vr
        im[jh] = ui - vi
        let ncr = cr * wr - ci * wi
        ci = cr * wi + ci * wr
        cr = ncr
      i += len
    len = len shl 1

proc magnitudeSpectrum*(frame: openArray[float32]; mag: var seq[float32]) =
  ## Спектр амплитуд кадра (len = n div 2 + 1). Окно применяет вызывающий:
  ## окно зависит от назначения (Ханна для тонов, прямоугольное для пиков).
  let n = nextPow2(frame.len)
  if mag.len != n div 2 + 1:
    mag.setLen(n div 2 + 1)
  if frame.len == 0:
    if mag.len > 0:
      mag[0] = 0.0f
    return
  if n <= 1:
    mag[0] = abs(frame[0])
    return
  var re = newSeq[float32](n)
  var im = newSeq[float32](n)
  for i in 0 ..< frame.len:
    re[i] = frame[i]
  fftRadix2(re, im)
  mag[0] = abs(re[0])
  let half = n div 2
  for k in 1 ..< half:
    mag[k] = sqrt(re[k] * re[k] + im[k] * im[k])
  mag[half] = abs(re[half])

proc hzPerBin*(sampleRate: float32; fftSize: int): float32 {.inline.} =
  ## Ширина бина в герцах.
  if fftSize <= 0:
    return 0.0f
  sampleRate / float32(fftSize)

proc binForHz*(hz: float32; sampleRate: float32; fftSize: int): int {.inline.} =
  ## Бин, ближайший к частоте `hz`.
  let width = hzPerBin(sampleRate, fftSize)
  if width <= 0.0f:
    return 0
  int(round(hz / width))

{.pop.}
