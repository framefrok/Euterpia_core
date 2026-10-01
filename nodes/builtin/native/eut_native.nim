# nodes/builtin/native/eut_native.nim
#
# Единственная точка, где Nim знает о C-ядрах DSP.
#
# Почему именно так (MANIFEST §42, §95):
#   - все C-файлы компилируются прямо здесь через {.compile.},
#     поэтому проект собирается одной командой nim/nimble без Makefile;
#   - наружу торчат только непрозрачные обёртки состояния и функции,
#     поэтому переписать DSP на чистом Nim — это замена одного файла,
#     а не правка десяти нод.
#
# ОГРАНИЧЕНИЕ Nim 2, которое здесь работает (проверено на 2.2):
#   1. Поля типа, объявленного как {.importc.}, видны ТОЛЬКО внутри
#      модуля, где этот тип объявлен. Ни completeStruct, ни bycopy
#      этого не меняют.
#   2. sizeof для {.importc.} типов требует completeStruct, а он
#      требует разбора C-заголовка, который ломается на макросах.
#
#   Вывод: C-состояние наружу не выставляется ВООБЩЕ. Обёртка хранит
#   `pointer`, а размер выделяемой памяти запрашивается у C.
#   Бонус: Nim больше ничем не связан с C-layout, поэтому расхождение
#   раскладки невозможно в принципе, а не «маловероятно».
#
# ВАЖНО: этот модуль не содержит DSP-логики. Он переводит типы.
# Всё поведение живёт в C.

import std/os

{.passC: "-I" & (currentSourcePath.parentDir / ".." / "csrc") & "/".}

{.compile: "../csrc/eut_biquad.c".}
{.compile: "../csrc/eut_svf.c".}
{.compile: "../csrc/eut_osc.c".}
{.compile: "../csrc/eut_noise.c".}
{.compile: "../csrc/eut_mix.c".}
{.compile: "../csrc/eut_comp.c".}
{.compile: "../csrc/eut_delay.c".}
{.compile: "../csrc/eut_abi.c".}

{.push raises: [].}

const
  EutMaxChannels* = 8.cint
  EutCompMaxBlock* = 1024.cint

  EutHasSimdDispatch* =
    when defined(x86_64) or defined(amd64):
      # На x86-64 C-ядра помечены target_clones("avx2","default"):
      # компилятор собирает AVX2-версию и выбирает её через IFUNC
      # один раз при загрузке процесса.
      true
    else:
      false

# ==============================================================================
# Константы (зеркалят enum'ы из eut_dsp.h)
# ==============================================================================

const
  EutBiquadLowpass*   = 0.cint
  EutBiquadHighpass*  = 1.cint
  EutBiquadBandpass*  = 2.cint
  EutBiquadNotch*     = 3.cint
  EutBiquadPeak*      = 4.cint
  EutBiquadLowshelf*  = 5.cint
  EutBiquadHighshelf* = 6.cint

  EutSvfLowpass*  = 0.cint
  EutSvfHighpass* = 1.cint
  EutSvfBandpass* = 2.cint
  EutSvfNotch*    = 3.cint

  EutOscSine*     = 0.cint
  EutOscSaw*      = 1.cint
  EutOscSquare*   = 2.cint
  EutOscTriangle* = 3.cint

  EutNoiseWhite* = 0.cint
  EutNoisePink*  = 1.cint
  EutNoiseBrown* = 2.cint

  EutCompPeak* = 0.cint
  EutCompRms*  = 1.cint

# ==============================================================================
# C-состояния: приватные, наружу не выходят
# ==============================================================================

type
  EutBiquadState {.importc: "EutBiquadState", bycopy.} = object
    b0, b1, b2: float32
    a1, a2: float32
    z1, z2: float32

  EutSvfState {.importc: "EutSvfState", bycopy.} = object
    ic1, ic2: float32
    g, k: float32
    a1, a2, a3: float32

  EutOscState {.importc: "EutOscState", bycopy.} = object
    phase, inc, pulseWidth: float32
    phaseR: float32          # фаза правого канала (detune)

  EutNoiseState {.importc: "EutNoiseState", bycopy.} = object
    rng: uint32
    b0, b1, b2, b3, b4, b5, b6: float32
    brown: float32

  EutComp {.importc: "EutComp", bycopy.} = object
    sampleRate: float32
    detector: cint
    channels: cint
    attackCoef, releaseCoef, avgCoef: float32
    thresholdDb, slope, kneeDb, makeupLin: float32
    env: float32
    rmsEnv: float32
    gainLin, gainDb: float32
    gainCurve: array[EutCompMaxBlock.int, float32]

  EutDelay {.importc: "EutDelay", bycopy.} = object
    buf: ptr float32
    capacity, writePos: cint
    delayL, delayR, feedback, mix: float32
    pingPong: cint
    lpStateL, lpStateR: float32

# ==============================================================================
# Обёртки состояния
#
# Поле непрозрачное: это единственная причина, по которой ноды не могут
# случайно испортить C-состояние и по которой Nim не зависит от раскладки C.
# ==============================================================================

type
  Biquad* {.bycopy.} = object
    p: pointer
  Svf* {.bycopy.} = object
    p: pointer
  Osc* {.bycopy.} = object
    p: pointer
  Noise* {.bycopy.} = object
    p: pointer
  Compressor* {.bycopy.} = object
    p: pointer
  Delay* {.bycopy.} = object
    p: pointer

# ==============================================================================
# C-функции
# ==============================================================================

proc c_biquad_design(st: ptr EutBiquadState; kind: cint; sampleRate, freq,
                     q, gainDb: float32) {.importc: "eut_biquad_design", header: "eut_dsp.h".}
proc c_biquad_reset(st: ptr EutBiquadState) {.importc: "eut_biquad_reset", header: "eut_dsp.h".}
proc c_biquad_process(st: ptr EutBiquadState; input, output: ptr float32;
                      n: cint) {.importc: "eut_biquad_process", header: "eut_dsp.h".}
proc c_biquad_process_one(st: ptr EutBiquadState; x: float32): float32
      {.importc: "eut_biquad_process_one", header: "eut_dsp.h".}

proc c_svf_design(st: ptr EutSvfState; kind: cint; sampleRate, cutoff,
                  resonance: float32) {.importc: "eut_svf_design", header: "eut_dsp.h".}
proc c_svf_reset(st: ptr EutSvfState) {.importc: "eut_svf_reset", header: "eut_dsp.h".}
proc c_svf_process(st: ptr EutSvfState; kind: cint; input, output: ptr float32;
                   n: cint) {.importc: "eut_svf_process", header: "eut_dsp.h".}
proc c_svf_process_one(st: ptr EutSvfState; kind: cint; x: float32): float32
      {.importc: "eut_svf_process_one", header: "eut_dsp.h".}

proc c_osc_init(st: ptr EutOscState; sampleRate, freq: float32) {.importc: "eut_osc_init", header: "eut_dsp.h".}
proc c_osc_set_freq(st: ptr EutOscState; sampleRate, freq: float32) {.importc: "eut_osc_set_freq", header: "eut_dsp.h".}
proc c_osc_set_pulse_width(st: ptr EutOscState; width: float32) {.importc: "eut_osc_set_pulse_width", header: "eut_dsp.h".}
proc c_osc_reset(st: ptr EutOscState) {.importc: "eut_osc_reset", header: "eut_dsp.h".}
proc c_osc_render(st: ptr EutOscState; kind: cint; outBuf: ptr float32;
                  n: cint; gain: float32) {.importc: "eut_osc_render", header: "eut_dsp.h".}
proc c_osc_render_stereo(st: ptr EutOscState; kind: cint; outL, outR: ptr float32;
                         n: cint; gain, detuneCents: float32)
      {.importc: "eut_osc_render_stereo", header: "eut_dsp.h".}

proc c_noise_init(st: ptr EutNoiseState; seed: uint32) {.importc: "eut_noise_init", header: "eut_dsp.h".}
proc c_noise_render(st: ptr EutNoiseState; kind: cint; outBuf: ptr float32;
                    n: cint; gain: float32) {.importc: "eut_noise_render", header: "eut_dsp.h".}

proc c_gain_apply(input, output: ptr float32; n: cint; gain: float32)
      {.importc: "eut_gain_apply", header: "eut_dsp.h".}
proc c_pan_gains(pan: float32; gainL, gainR: ptr float32)
      {.importc: "eut_pan_gains", header: "eut_dsp.h".}
proc c_pan_apply(inL, inR, outL, outR: ptr float32; n: cint; gainL, gainR: float32)
      {.importc: "eut_pan_apply", header: "eut_dsp.h".}
proc c_saturate(buf: ptr float32; n: cint; drive, ceiling: float32)
      {.importc: "eut_saturate", header: "eut_dsp.h".}

proc c_comp_init(c: ptr EutComp; channels, detector: cint; sampleRate: float32)
      {.importc: "eut_comp_init", header: "eut_dsp.h".}
proc c_comp_set_params(c: ptr EutComp; thresholdDb, ratio, kneeDb, attackSec,
                       releaseSec, makeupDb: float32)
      {.importc: "eut_comp_set_params", header: "eut_dsp.h".}
proc c_comp_reset(c: ptr EutComp) {.importc: "eut_comp_reset", header: "eut_dsp.h".}
proc c_comp_detect(c: ptr EutComp; input: ptr float32; n: cint)
      {.importc: "eut_comp_detect", header: "eut_dsp.h".}
proc c_comp_apply(gainCurve, input, output: ptr float32; n: cint)
      {.importc: "eut_comp_apply", header: "eut_dsp.h".}
proc c_comp_gain_db(c: ptr EutComp): float32 {.importc: "eut_comp_gain_db", header: "eut_dsp.h".}
proc c_comp_gain_at(c: ptr EutComp; index: cint): float32
      {.importc: "eut_comp_gain_at", header: "eut_dsp.h".}

proc c_delay_init(d: ptr EutDelay; memory: ptr float32; capacityFrames: cint)
      {.importc: "eut_delay_init", header: "eut_dsp.h".}
proc c_delay_reset(d: ptr EutDelay) {.importc: "eut_delay_reset", header: "eut_dsp.h".}
proc c_delay_set(d: ptr EutDelay; sampleRate, timeL, timeR, feedback, mix: float32;
                 pingPong: cint) {.importc: "eut_delay_set", header: "eut_dsp.h".}
proc c_delay_process(d: ptr EutDelay; inL, inR, outL, outR: ptr float32; n: cint)
      {.importc: "eut_delay_process", header: "eut_dsp.h".}

proc c_size_biquad(): cint {.importc: "eut_abi_sizeof_biquad", header: "eut_dsp.h".}
proc c_size_svf(): cint {.importc: "eut_abi_sizeof_svf", header: "eut_dsp.h".}
proc c_size_osc(): cint {.importc: "eut_abi_sizeof_osc", header: "eut_dsp.h".}
proc c_size_noise(): cint {.importc: "eut_abi_sizeof_noise", header: "eut_dsp.h".}
proc c_size_comp(): cint {.importc: "eut_abi_sizeof_comp", header: "eut_dsp.h".}
proc c_size_delay(): cint {.importc: "eut_abi_sizeof_delay", header: "eut_dsp.h".}

# ==============================================================================
# Предикаты готовности
#
# Поле p намеренно не экспортируется: нода не должна ни читать, ни писать
# C-состояние напрямую. Проверка «выделено ли состояние» — тоже часть
# контракта этого модуля.
# ==============================================================================

proc isReady*(b: Biquad): bool {.inline.} = not b.p.isNil
proc isReady*(v: Svf): bool {.inline.} = not v.p.isNil
proc isReady*(o: Osc): bool {.inline.} = not o.p.isNil
proc isReady*(nz: Noise): bool {.inline.} = not nz.p.isNil
proc isReady*(c: Compressor): bool {.inline.} = not c.p.isNil
proc isReady*(d: Delay): bool {.inline.} = not d.p.isNil

# ==============================================================================
# Внутренние помощники
# ==============================================================================

proc allocState(sizeBytes: int): pointer {.inline.} =
  ## Холодная сторона: ноде нельзя аллоцировать в audio thread,
  ## поэтому память под состояние выделяется ровно один раз.
  allocShared0(sizeBytes)

# ==============================================================================
# Публичный API
# ==============================================================================

# --- biquad ------------------------------------------------------------------

proc newBiquad*(): Biquad =
  result.p = allocState(c_size_biquad().int)

proc freeBiquad*(b: ptr Biquad) {.inline.} =
  if b.isNil or b.p.isNil:
    return
  deallocShared(b.p)
  b.p = nil

proc biquadDesign*(b: ptr Biquad; kind: cint; sampleRate, freq, q, gainDb: float32) {.inline.} =
  if b.isNil or b.p.isNil: return
  c_biquad_design(cast[ptr EutBiquadState](b.p), kind, sampleRate, freq, q, gainDb)

proc biquadReset*(b: ptr Biquad) {.inline.} =
  if b.isNil or b.p.isNil: return
  c_biquad_reset(cast[ptr EutBiquadState](b.p))

proc biquadProcess*(b: ptr Biquad; input, output: ptr float32; n: int) {.inline.} =
  if b.isNil or b.p.isNil or n <= 0: return
  c_biquad_process(cast[ptr EutBiquadState](b.p), input, output, n.cint)

proc biquadProcessOne*(b: ptr Biquad; x: float32): float32 {.inline.} =
  if b.isNil or b.p.isNil: return 0.0f
  c_biquad_process_one(cast[ptr EutBiquadState](b.p), x)

# --- svf ---------------------------------------------------------------------

proc newSvf*(): Svf =
  result.p = allocState(c_size_svf().int)

proc freeSvf*(v: ptr Svf) {.inline.} =
  if v.isNil or v.p.isNil:
    return
  deallocShared(v.p)
  v.p = nil

proc svfDesign*(v: ptr Svf; kind: cint; sampleRate, cutoff, resonance: float32) {.inline.} =
  if v.isNil or v.p.isNil: return
  c_svf_design(cast[ptr EutSvfState](v.p), kind, sampleRate, cutoff, resonance)

proc svfReset*(v: ptr Svf) {.inline.} =
  if v.isNil or v.p.isNil: return
  c_svf_reset(cast[ptr EutSvfState](v.p))

proc svfProcess*(v: ptr Svf; kind: cint; input, output: ptr float32; n: int) {.inline.} =
  if v.isNil or v.p.isNil or n <= 0: return
  c_svf_process(cast[ptr EutSvfState](v.p), kind, input, output, n.cint)

proc svfProcessOne*(v: ptr Svf; kind: cint; x: float32): float32 {.inline.} =
  if v.isNil or v.p.isNil: return 0.0f
  c_svf_process_one(cast[ptr EutSvfState](v.p), kind, x)

# --- осциллятор -------------------------------------------------------------

proc newOsc*(sampleRate: float32 = 48000.0f; freq: float32 = 440.0f): Osc =
  result.p = allocState(c_size_osc().int)
  if not result.p.isNil:
    c_osc_init(cast[ptr EutOscState](result.p), sampleRate, freq)
    c_osc_set_pulse_width(cast[ptr EutOscState](result.p), 0.5f)

proc freeOsc*(o: ptr Osc) {.inline.} =
  if o.isNil or o.p.isNil:
    return
  deallocShared(o.p)
  o.p = nil

proc oscSetFreq*(o: ptr Osc; sampleRate, freq: float32) {.inline.} =
  if o.isNil or o.p.isNil: return
  c_osc_set_freq(cast[ptr EutOscState](o.p), sampleRate, freq)

proc oscSetPulseWidth*(o: ptr Osc; width: float32) {.inline.} =
  if o.isNil or o.p.isNil: return
  c_osc_set_pulse_width(cast[ptr EutOscState](o.p), width)

proc oscReset*(o: ptr Osc) {.inline.} =
  if o.isNil or o.p.isNil: return
  c_osc_reset(cast[ptr EutOscState](o.p))

proc oscRender*(o: ptr Osc; kind: cint; outBuf: ptr float32; n: int; gain: float32) {.inline.} =
  if o.isNil or o.p.isNil or n <= 0: return
  c_osc_render(cast[ptr EutOscState](o.p), kind, outBuf, n.cint, gain)

proc oscRenderStereo*(o: ptr Osc; kind: cint; outL, outR: ptr float32;
                      n: int; gain, detuneCents: float32) {.inline.} =
  if o.isNil or o.p.isNil or n <= 0: return
  c_osc_render_stereo(cast[ptr EutOscState](o.p), kind, outL, outR, n.cint,
                      gain, detuneCents)

# --- шум ---------------------------------------------------------------------

proc newNoise*(seed: uint32 = 0x9E3779B9'u32): Noise =
  result.p = allocState(c_size_noise().int)
  if not result.p.isNil:
    c_noise_init(cast[ptr EutNoiseState](result.p), seed)

proc freeNoise*(nz: ptr Noise) {.inline.} =
  if nz.isNil or nz.p.isNil:
    return
  deallocShared(nz.p)
  nz.p = nil

proc noiseRender*(nz: ptr Noise; kind: cint; outBuf: ptr float32; n: int; gain: float32) {.inline.} =
  if nz.isNil or nz.p.isNil or n <= 0: return
  c_noise_render(cast[ptr EutNoiseState](nz.p), kind, outBuf, n.cint, gain)

# --- микс --------------------------------------------------------------------

proc mixGain*(input, output: ptr float32; n: int; gain: float32) {.inline.} =
  ## n — количество float-семплов (для interleaved: frames * channels).
  if n <= 0: return
  c_gain_apply(input, output, n.cint, gain)

proc mixPanGains*(pan: float32; gainL, gainR: var float32) {.inline.} =
  c_pan_gains(pan, addr gainL, addr gainR)

proc mixPan*(inL, inR, outL, outR: ptr float32; n: int; gainL, gainR: float32) {.inline.} =
  if n <= 0: return
  c_pan_apply(inL, inR, outL, outR, n.cint, gainL, gainR)

proc mixSaturate*(buf: ptr float32; n: int; drive, ceiling: float32) {.inline.} =
  if n <= 0: return
  c_saturate(buf, n.cint, drive, ceiling)

# --- компрессор -------------------------------------------------------------

proc newCompressor*(channels: cint = 2; detector: cint = EutCompPeak;
                    sampleRate: float32 = 48000.0f): Compressor =
  result.p = allocState(c_size_comp().int)
  if not result.p.isNil:
    c_comp_init(cast[ptr EutComp](result.p), channels, detector, sampleRate)

proc freeCompressor*(c: ptr Compressor) {.inline.} =
  if c.isNil or c.p.isNil:
    return
  deallocShared(c.p)
  c.p = nil

proc compSetParams*(c: ptr Compressor; thresholdDb, ratio, kneeDb, attackSec,
                    releaseSec, makeupDb: float32) {.inline.} =
  if c.isNil or c.p.isNil: return
  c_comp_set_params(cast[ptr EutComp](c.p), thresholdDb, ratio, kneeDb,
                    attackSec, releaseSec, makeupDb)

proc compReset*(c: ptr Compressor) {.inline.} =
  if c.isNil or c.p.isNil: return
  c_comp_reset(cast[ptr EutComp](c.p))

proc compDetect*(c: ptr Compressor; input: ptr float32; n: int) {.inline.} =
  ## Шаг 1: заполняет внутреннюю кривую gain для блока.
  if c.isNil or c.p.isNil or n <= 0: return
  c_comp_detect(cast[ptr EutComp](c.p), input, n.cint)

proc compApply*(c: ptr Compressor; input, output: ptr float32; n: int) {.inline.} =
  ## Шаг 2: применяет рассчитанную кривую. in == out разрешено.
  if c.isNil or c.p.isNil or n <= 0: return
  c_comp_apply(cast[ptr float32](addr (cast[ptr EutComp](c.p)).gainCurve),
               input, output, n.cint)

proc compGainDb*(c: ptr Compressor): float32 {.inline.} =
  if c.isNil or c.p.isNil: return 0.0f
  c_comp_gain_db(cast[ptr EutComp](c.p))

proc compGainAt*(c: ptr Compressor; index: int): float32 {.inline.} =
  ## Gain кривой в одном сэмпле блока — для interleaved-выхода.
  if c.isNil or c.p.isNil: return 1.0f
  c_comp_gain_at(cast[ptr EutComp](c.p), index.cint)

# --- задержка ---------------------------------------------------------------

proc newDelay*(memory: ptr float32; capacityFrames: int): Delay =
  result.p = allocState(c_size_delay().int)
  if not result.p.isNil:
    c_delay_init(cast[ptr EutDelay](result.p), memory, capacityFrames.cint)

proc freeDelay*(d: ptr Delay) {.inline.} =
  if d.isNil or d.p.isNil:
    return
  deallocShared(d.p)
  d.p = nil

proc delayReset*(d: ptr Delay) {.inline.} =
  if d.isNil or d.p.isNil: return
  c_delay_reset(cast[ptr EutDelay](d.p))

proc delaySet*(d: ptr Delay; sampleRate, timeL, timeR, feedback, mix: float32;
               pingPong: bool) {.inline.} =
  if d.isNil or d.p.isNil: return
  c_delay_set(cast[ptr EutDelay](d.p), sampleRate, timeL, timeR, feedback, mix,
              (if pingPong: 1.cint else: 0.cint))

proc delayProcess*(d: ptr Delay; inL, inR, outL, outR: ptr float32; n: int) {.inline.} =
  if d.isNil or d.p.isNil or n <= 0: return
  c_delay_process(cast[ptr EutDelay](d.p), inL, inR, outL, outR, n.cint)

# --- ABI --------------------------------------------------------------------

proc abiCheck*(): bool =
  ## Размеры C-состояний сверяются с задокументированными значениями.
  ##
  ## Нужен не для того, чтобы «что-то поймать при сборке» (это делает
  ## компилятор), а чтобы изменение структуры в C не осталось незамеченным:
  ## к примеру, добавление поля меняет размер, и это видно сразу.
  c_size_biquad() == 28 and
  c_size_svf() == 28 and
  c_size_osc() == 16 and        # phase, inc, pulseWidth, phaseR
  c_size_noise() == 36 and
  c_size_comp() == 4152 and     # + rmsEnv (усреднённая мощность RMS)
  c_size_delay() == 48

{.pop.}
