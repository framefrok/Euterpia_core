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

# ---------------------------------------------------------------------------
# Инвалидация кэша при правке C-заголовка (issue #43)
#
# Nim НЕ отслеживает `#include` для `{.compile.}`: правка `eut_dsp.h` не
# пересобирает C-объекты, и в одном бинарнике оказываются TU, собранные по
# РАЗНЫМ версиям заголовка. На практике это выглядело как «случайные»
# падения тестов после правки размера структуры: stale `sizeof(EutComp)`
# ломал abiCheck(), а рассогласованные TU роняли посторонний тест фильтра.
#
# Лечение: хеш содержимого заголовка становится частью ИМЕНИ объектного
# файла (`{.compile: (cfile, obj)}` берёт имя .o вторым аргументом). Nim
# пересобирает `{.compile.}`-файл, если менялись его исходник или параметры,
# а при новом имени объекта прежний .o просто не переиспользуется.
#
# Проверено на практике:
#   * правка заголовка -> в nimcache появляются объекты с новым префиксом
#     (старые остаются лежать и игнорируются);
#   * намеренно рассогласованный заголовок (`gainCurve[4097]` при макросе
#     4096) теперь ЛОМАЕТ инкрементальную сборку на `_Static_assert`,
#     тогда как раньше stale-объект это маскировал;
#   * `passC` для этого не годится — Nim не пересобирает `{.compile.}` при
#     смене флагов (проверено: объект оставался прежним).
# Старые объекты копятся в nimcache и удаляются вместе с ним.
# ---------------------------------------------------------------------------

func eutHeaderHash(s: string): uint64 =
  ## FNV-1a. Нужен только детерминированный, одинаковый между запусками и
  ## платформами хеш: std/hashes для этого не подходит (не обязан
  ## вычисляться на этапе компиляции).
  result = 14695981039346656037'u64
  for ch in s:
    result = result xor uint64(ord(ch))
    result = result * 1099511628211'u64

const
  EutDspHeaderSource = staticRead("../csrc/eut_dsp.h")
  EutDspHeaderHash = eutHeaderHash(EutDspHeaderSource)
  ## Префикс имени объектного файла ядер: `{.compile: (cfile, obj)}`
  ## принимает имя .o, поэтому смена хеша заголовка меняет и имя объекта —
  ## Nim пересобирает его вместо использования прежнего (issue #43).
  EutDspObjPrefix = "eut_hdr_" & $EutDspHeaderHash & "_"

{.compile: ("../csrc/eut_biquad.c", EutDspObjPrefix & "eut_biquad.o").}
{.compile: ("../csrc/eut_svf.c", EutDspObjPrefix & "eut_svf.o").}
{.compile: ("../csrc/eut_osc.c", EutDspObjPrefix & "eut_osc.o").}
{.compile: ("../csrc/eut_noise.c", EutDspObjPrefix & "eut_noise.o").}
{.compile: ("../csrc/eut_mix.c", EutDspObjPrefix & "eut_mix.o").}
{.compile: ("../csrc/eut_comp.c", EutDspObjPrefix & "eut_comp.o").}
{.compile: ("../csrc/eut_delay.c", EutDspObjPrefix & "eut_delay.o").}
{.compile: ("../csrc/eut_abi.c", EutDspObjPrefix & "eut_abi.o").}
{.compile: ("../csrc/eut_inst.c", EutDspObjPrefix & "eut_inst.o").}

{.push raises: [].}

const
  EutMaxChannels* = 8.cint
  EutCompMaxBlock* = 4096.cint

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

  # Куски установки (порядок обязан совпадать с enum в eut_dsp.h).
  EutDrumKick*      = 0.cint
  EutDrumSnare*     = 1.cint
  EutDrumRim*       = 2.cint
  EutDrumClap*      = 3.cint
  EutDrumTomLow*    = 4.cint
  EutDrumTomMid*    = 5.cint
  EutDrumTomHigh*   = 6.cint
  EutDrumHatClosed* = 7.cint
  EutDrumHatPedal*  = 8.cint
  EutDrumHatOpen*   = 9.cint
  EutDrumCrash*     = 10.cint
  EutDrumRide*      = 11.cint
  EutDrumPieceCount* = 12.cint

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

  # ---------------------------------------------------------------------
  # Инструменты (eut_inst.c)
  #
  # Содержимое этих структур Nim не разбирает и не имеет права разбирать:
  # движку передаётся только `ptr`, а размеры блоков запрашиваются у C
  # (`eut_abi_sizeof_*`). Поэтому поля не объявлены вообще — раскладка
  # структур инструментов может меняться без правки Nim-стороны, а
  # расхождение ловится `abiCheck()`.
  # ---------------------------------------------------------------------
  EutOrganVoice {.importc: "EutOrganVoice", bycopy.} = object
  EutOrgan {.importc: "EutOrgan", bycopy.} = object
  EutPianoVoice {.importc: "EutPianoVoice", bycopy.} = object
  EutPiano {.importc: "EutPiano", bycopy.} = object
  EutGuitarVoice {.importc: "EutGuitarVoice", bycopy.} = object
  EutGuitar {.importc: "EutGuitar", bycopy.} = object
  EutDrumVoice {.importc: "EutDrumVoice", bycopy.} = object
  EutDrums {.importc: "EutDrums", bycopy.} = object
  EutFluteVoice {.importc: "EutFluteVoice", bycopy.} = object
  EutFlute {.importc: "EutFlute", bycopy.} = object
  EutBagpipeVoice {.importc: "EutBagpipeVoice", bycopy.} = object
  EutBagpipe {.importc: "EutBagpipe", bycopy.} = object
  EutStringsVoice {.importc: "EutStringsVoice", bycopy.} = object
  EutStrings {.importc: "EutStrings", bycopy.} = object
  EutBellVoice {.importc: "EutBellVoice", bycopy.} = object
  EutBell {.importc: "EutBell", bycopy.} = object
  EutPluckVoice {.importc: "EutPluckVoice", bycopy.} = object
  EutPluck {.importc: "EutPluck", bycopy.} = object
  EutRecorderVoice {.importc: "EutRecorderVoice", bycopy.} = object
  EutRecorder {.importc: "EutRecorder", bycopy.} = object
  EutBrassVoice {.importc: "EutBrassVoice", bycopy.} = object
  EutBrass {.importc: "EutBrass", bycopy.} = object
  EutTimpaniVoice {.importc: "EutTimpaniVoice", bycopy.} = object
  EutTimpani {.importc: "EutTimpani", bycopy.} = object
  EutChoirVoice {.importc: "EutChoirVoice", bycopy.} = object
  EutChoir {.importc: "EutChoir", bycopy.} = object
  EutReedVoice {.importc: "EutReedVoice", bycopy.} = object
  EutReed {.importc: "EutReed", bycopy.} = object

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
  Organ* {.bycopy.} = object
    p: pointer
    voiceCount: int
      ## Число голосов нужно при переинициализации на другой частоте
      ## дискретизации: C-движок фиксирует `sampleRate` на `*_init`.
  Piano* {.bycopy.} = object
    p: pointer
    voiceCount: int
  Guitar* {.bycopy.} = object
    p: pointer
      ## Струнная память живёт отдельным блоком: её размер зависит от
      ## частоты дискретизации (`sr / 8 Гц`), а не от раскладки C-структуры.
    memory: pointer
    voiceCount: int
    lineCap: int
      ## Кадров линии задержки на одну струну — ёмкость выделенного блока.
      ## Переинициализация на частоте, которой этой ёмкости мало, обязана
      ## отказать, а не выйти за границу памяти.
  Drums* {.bycopy.} = object
    p: pointer
    voiceCount: int
  Flute* {.bycopy.} = object
    p: pointer
    voiceCount: int
  Bagpipe* {.bycopy.} = object
    p: pointer
    voiceCount: int
  Strings* {.bycopy.} = object
    p: pointer
    voiceCount: int
  Bell* {.bycopy.} = object
    p: pointer
    voiceCount: int
  Pluck* {.bycopy.} = object
    p: pointer
      ## Память струн живёт отдельным блоком (как у гитары): её размер зависит
      ## от частоты дискретизации, а не от раскладки C-структуры.
    memory: pointer
    voiceCount: int
    lineCap: int
  Recorder* {.bycopy.} = object
    p: pointer
    voiceCount: int
  Brass* {.bycopy.} = object
    p: pointer
    voiceCount: int
  Timpani* {.bycopy.} = object
    p: pointer
    voiceCount: int
  Choir* {.bycopy.} = object
    p: pointer
    voiceCount: int
  Reed* {.bycopy.} = object
    p: pointer
    voiceCount: int

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

# --- инструменты ------------------------------------------------------------
#
# Общий контракт всех четырёх движков (eut_inst.c):
#   * `*_process` ДОБАВЛЯЕТ результат в буферы вывода, а не перезаписывает
#     их: инструмент обязан суммироваться с тем, что уже пришло по порту;
#   * `stride` — шаг между кадрами канала: 1 — planar (каналы подряд),
#     2 — interleaved (LRLR). Раскладку задаёт граф, движок её не угадывает;
#   * `bendSemitones` и `modCents` приходят на блок целиком (control rate).

proc c_organ_init(g: ptr EutOrgan; voices: ptr EutOrganVoice; voiceCount: cint;
                  sampleRate: float32)
      {.importc: "eut_organ_init", header: "eut_dsp.h".}
proc c_organ_reset(g: ptr EutOrgan) {.importc: "eut_organ_reset", header: "eut_dsp.h".}
proc c_organ_set(g: ptr EutOrgan; bars, tone, clickLevel, vibratoCents, pan,
                 level: float32) {.importc: "eut_organ_set", header: "eut_dsp.h".}
proc c_organ_note_on(g: ptr EutOrgan; note: cint; velocity: float32)
      {.importc: "eut_organ_note_on", header: "eut_dsp.h".}
proc c_organ_note_off(g: ptr EutOrgan; note: cint)
      {.importc: "eut_organ_note_off", header: "eut_dsp.h".}
proc c_organ_all_off(g: ptr EutOrgan) {.importc: "eut_organ_all_off", header: "eut_dsp.h".}
proc c_organ_process(g: ptr EutOrgan; outL, outR: ptr float32; stride, n: cint;
                     bendSemitones, modCents: float32)
      {.importc: "eut_organ_process", header: "eut_dsp.h".}

proc c_piano_init(g: ptr EutPiano; voices: ptr EutPianoVoice; voiceCount: cint;
                  sampleRate: float32)
      {.importc: "eut_piano_init", header: "eut_dsp.h".}
proc c_piano_reset(g: ptr EutPiano) {.importc: "eut_piano_reset", header: "eut_dsp.h".}
proc c_piano_set(g: ptr EutPiano; tone, decay, detuneCents, hammer, release, pan,
                 level: float32) {.importc: "eut_piano_set", header: "eut_dsp.h".}
proc c_piano_note_on(g: ptr EutPiano; note: cint; velocity: float32)
      {.importc: "eut_piano_note_on", header: "eut_dsp.h".}
proc c_piano_note_off(g: ptr EutPiano; note: cint)
      {.importc: "eut_piano_note_off", header: "eut_dsp.h".}
proc c_piano_pedal(g: ptr EutPiano; down: cint)
      {.importc: "eut_piano_pedal", header: "eut_dsp.h".}
proc c_piano_all_off(g: ptr EutPiano) {.importc: "eut_piano_all_off", header: "eut_dsp.h".}
proc c_piano_process(g: ptr EutPiano; outL, outR: ptr float32; stride, n: cint;
                     bendSemitones, modCents: float32)
      {.importc: "eut_piano_process", header: "eut_dsp.h".}

proc c_guitar_init(g: ptr EutGuitar; voices: ptr EutGuitarVoice; voiceCount: cint;
                   memory: ptr float32; lineCap: cint; sampleRate: float32)
      {.importc: "eut_guitar_init", header: "eut_dsp.h".}
proc c_guitar_reset(g: ptr EutGuitar) {.importc: "eut_guitar_reset", header: "eut_dsp.h".}
proc c_guitar_set(g: ptr EutGuitar; pick, damping, tone, drive, mute, release,
                  pan, level: float32)
      {.importc: "eut_guitar_set", header: "eut_dsp.h".}
proc c_guitar_note_on(g: ptr EutGuitar; note: cint; velocity: float32)
      {.importc: "eut_guitar_note_on", header: "eut_dsp.h".}
proc c_guitar_note_off(g: ptr EutGuitar; note: cint)
      {.importc: "eut_guitar_note_off", header: "eut_dsp.h".}
proc c_guitar_all_off(g: ptr EutGuitar)
      {.importc: "eut_guitar_all_off", header: "eut_dsp.h".}
proc c_guitar_process(g: ptr EutGuitar; outL, outR: ptr float32; stride, n: cint;
                      bendSemitones, modCents: float32)
      {.importc: "eut_guitar_process", header: "eut_dsp.h".}

proc c_drums_piece_for_note(note: cint): cint
      {.importc: "eut_drums_piece_for_note", header: "eut_dsp.h".}
proc c_drums_init(g: ptr EutDrums; voices: ptr EutDrumVoice; voiceCount: cint;
                  sampleRate: float32)
      {.importc: "eut_drums_init", header: "eut_dsp.h".}
proc c_drums_reset(g: ptr EutDrums) {.importc: "eut_drums_reset", header: "eut_dsp.h".}
proc c_drums_set(g: ptr EutDrums; tune, decay, snappy, tone, drive, pan,
                 level: float32) {.importc: "eut_drums_set", header: "eut_dsp.h".}
proc c_drums_note_on(g: ptr EutDrums; note: cint; velocity: float32)
      {.importc: "eut_drums_note_on", header: "eut_dsp.h".}
proc c_drums_note_off(g: ptr EutDrums; note: cint)
      {.importc: "eut_drums_note_off", header: "eut_dsp.h".}
proc c_drums_all_off(g: ptr EutDrums) {.importc: "eut_drums_all_off", header: "eut_dsp.h".}
proc c_drums_process(g: ptr EutDrums; outL, outR: ptr float32; stride, n: cint)
      {.importc: "eut_drums_process", header: "eut_dsp.h".}

proc c_flute_init(g: ptr EutFlute; voices: ptr EutFluteVoice; voiceCount: cint;
                  sampleRate: float32)
      {.importc: "eut_flute_init", header: "eut_dsp.h".}
proc c_flute_reset(g: ptr EutFlute) {.importc: "eut_flute_reset", header: "eut_dsp.h".}
proc c_flute_set(g: ptr EutFlute; tone, breath, vibratoCents, pan, level: float32)
      {.importc: "eut_flute_set", header: "eut_dsp.h".}
proc c_flute_note_on(g: ptr EutFlute; note: cint; velocity: float32)
      {.importc: "eut_flute_note_on", header: "eut_dsp.h".}
proc c_flute_note_off(g: ptr EutFlute; note: cint)
      {.importc: "eut_flute_note_off", header: "eut_dsp.h".}
proc c_flute_all_off(g: ptr EutFlute) {.importc: "eut_flute_all_off", header: "eut_dsp.h".}
proc c_flute_process(g: ptr EutFlute; outL, outR: ptr float32; stride, n: cint;
                     bendSemitones, modCents: float32)
      {.importc: "eut_flute_process", header: "eut_dsp.h".}

proc c_bagpipe_init(g: ptr EutBagpipe; voices: ptr EutBagpipeVoice; voiceCount: cint;
                    sampleRate: float32)
      {.importc: "eut_bagpipe_init", header: "eut_dsp.h".}
proc c_bagpipe_reset(g: ptr EutBagpipe) {.importc: "eut_bagpipe_reset", header: "eut_dsp.h".}
proc c_bagpipe_set(g: ptr EutBagpipe; tone, droneLevel, droneFreq, pan, level: float32)
      {.importc: "eut_bagpipe_set", header: "eut_dsp.h".}
proc c_bagpipe_note_on(g: ptr EutBagpipe; note: cint; velocity: float32)
      {.importc: "eut_bagpipe_note_on", header: "eut_dsp.h".}
proc c_bagpipe_note_off(g: ptr EutBagpipe; note: cint)
      {.importc: "eut_bagpipe_note_off", header: "eut_dsp.h".}
proc c_bagpipe_all_off(g: ptr EutBagpipe)
      {.importc: "eut_bagpipe_all_off", header: "eut_dsp.h".}
proc c_bagpipe_process(g: ptr EutBagpipe; outL, outR: ptr float32; stride, n: cint)
      {.importc: "eut_bagpipe_process", header: "eut_dsp.h".}

proc c_strings_init(g: ptr EutStrings; voices: ptr EutStringsVoice; voiceCount: cint;
                    sampleRate: float32)
      {.importc: "eut_strings_init", header: "eut_dsp.h".}
proc c_strings_reset(g: ptr EutStrings)
      {.importc: "eut_strings_reset", header: "eut_dsp.h".}
proc c_strings_set(g: ptr EutStrings; tone, vibratoCents, ensembleCents, pan,
                   level: float32)
      {.importc: "eut_strings_set", header: "eut_dsp.h".}
proc c_strings_note_on(g: ptr EutStrings; note: cint; velocity: float32)
      {.importc: "eut_strings_note_on", header: "eut_dsp.h".}
proc c_strings_note_off(g: ptr EutStrings; note: cint)
      {.importc: "eut_strings_note_off", header: "eut_dsp.h".}
proc c_strings_all_off(g: ptr EutStrings)
      {.importc: "eut_strings_all_off", header: "eut_dsp.h".}
proc c_strings_process(g: ptr EutStrings; outL, outR: ptr float32; stride, n: cint;
                       bendSemitones, modCents: float32)
      {.importc: "eut_strings_process", header: "eut_dsp.h".}

proc c_bell_init(g: ptr EutBell; voices: ptr EutBellVoice; voiceCount: cint;
                 sampleRate: float32)
      {.importc: "eut_bell_init", header: "eut_dsp.h".}
proc c_bell_reset(g: ptr EutBell) {.importc: "eut_bell_reset", header: "eut_dsp.h".}
proc c_bell_set(g: ptr EutBell; tune, decay, tone, pan, level: float32)
      {.importc: "eut_bell_set", header: "eut_dsp.h".}
proc c_bell_note_on(g: ptr EutBell; note: cint; velocity: float32)
      {.importc: "eut_bell_note_on", header: "eut_dsp.h".}
proc c_bell_note_off(g: ptr EutBell; note: cint)
      {.importc: "eut_bell_note_off", header: "eut_dsp.h".}
proc c_bell_all_off(g: ptr EutBell)
      {.importc: "eut_bell_all_off", header: "eut_dsp.h".}
proc c_bell_process(g: ptr EutBell; outL, outR: ptr float32; stride, n: cint)
      {.importc: "eut_bell_process", header: "eut_dsp.h".}

proc c_pluck_init(g: ptr EutPluck; voices: ptr EutPluckVoice; voiceCount: cint;
                  memory: ptr float32; lineCap: cint; sampleRate: float32)
      {.importc: "eut_pluck_init", header: "eut_dsp.h".}
proc c_pluck_reset(g: ptr EutPluck)
      {.importc: "eut_pluck_reset", header: "eut_dsp.h".}
proc c_pluck_set(g: ptr EutPluck; tone, damping, pluck, body, bodyHz, nylon,
                 pan, level: float32)
      {.importc: "eut_pluck_set", header: "eut_dsp.h".}
proc c_pluck_note_on(g: ptr EutPluck; note: cint; velocity: float32)
      {.importc: "eut_pluck_note_on", header: "eut_dsp.h".}
proc c_pluck_note_off(g: ptr EutPluck; note: cint)
      {.importc: "eut_pluck_note_off", header: "eut_dsp.h".}
proc c_pluck_all_off(g: ptr EutPluck)
      {.importc: "eut_pluck_all_off", header: "eut_dsp.h".}
proc c_pluck_process(g: ptr EutPluck; outL, outR: ptr float32; stride, n: cint)
      {.importc: "eut_pluck_process", header: "eut_dsp.h".}

proc c_recorder_init(g: ptr EutRecorder; voices: ptr EutRecorderVoice;
                     voiceCount: cint; sampleRate: float32)
      {.importc: "eut_recorder_init", header: "eut_dsp.h".}
proc c_recorder_reset(g: ptr EutRecorder)
      {.importc: "eut_recorder_reset", header: "eut_dsp.h".}
proc c_recorder_set(g: ptr EutRecorder; tone, breath, vibratoCents, pan,
                    level: float32)
      {.importc: "eut_recorder_set", header: "eut_dsp.h".}
proc c_recorder_note_on(g: ptr EutRecorder; note: cint; velocity: float32)
      {.importc: "eut_recorder_note_on", header: "eut_dsp.h".}
proc c_recorder_note_off(g: ptr EutRecorder; note: cint)
      {.importc: "eut_recorder_note_off", header: "eut_dsp.h".}
proc c_recorder_all_off(g: ptr EutRecorder)
      {.importc: "eut_recorder_all_off", header: "eut_dsp.h".}
proc c_recorder_process(g: ptr EutRecorder; outL, outR: ptr float32;
                        stride, n: cint; bendSemitones, modCents: float32)
      {.importc: "eut_recorder_process", header: "eut_dsp.h".}

proc c_brass_init(g: ptr EutBrass; voices: ptr EutBrassVoice; voiceCount: cint;
                  sampleRate: float32)
      {.importc: "eut_brass_init", header: "eut_dsp.h".}
proc c_brass_reset(g: ptr EutBrass)
      {.importc: "eut_brass_reset", header: "eut_dsp.h".}
proc c_brass_set(g: ptr EutBrass; tone, rasp, vibratoCents, pan, level: float32)
      {.importc: "eut_brass_set", header: "eut_dsp.h".}
proc c_brass_note_on(g: ptr EutBrass; note: cint; velocity: float32)
      {.importc: "eut_brass_note_on", header: "eut_dsp.h".}
proc c_brass_note_off(g: ptr EutBrass; note: cint)
      {.importc: "eut_brass_note_off", header: "eut_dsp.h".}
proc c_brass_all_off(g: ptr EutBrass)
      {.importc: "eut_brass_all_off", header: "eut_dsp.h".}
proc c_brass_process(g: ptr EutBrass; outL, outR: ptr float32; stride, n: cint;
                     bendSemitones, modCents: float32)
      {.importc: "eut_brass_process", header: "eut_dsp.h".}

proc c_timpani_init(g: ptr EutTimpani; voices: ptr EutTimpaniVoice;
                    voiceCount: cint; sampleRate: float32)
      {.importc: "eut_timpani_init", header: "eut_dsp.h".}
proc c_timpani_reset(g: ptr EutTimpani)
      {.importc: "eut_timpani_reset", header: "eut_dsp.h".}
proc c_timpani_set(g: ptr EutTimpani; tune, decay, tone, pan, level: float32)
      {.importc: "eut_timpani_set", header: "eut_dsp.h".}
proc c_timpani_note_on(g: ptr EutTimpani; note: cint; velocity: float32)
      {.importc: "eut_timpani_note_on", header: "eut_dsp.h".}
proc c_timpani_note_off(g: ptr EutTimpani; note: cint)
      {.importc: "eut_timpani_note_off", header: "eut_dsp.h".}
proc c_timpani_all_off(g: ptr EutTimpani)
      {.importc: "eut_timpani_all_off", header: "eut_dsp.h".}
proc c_timpani_process(g: ptr EutTimpani; outL, outR: ptr float32; stride, n: cint)
      {.importc: "eut_timpani_process", header: "eut_dsp.h".}

proc c_choir_init(g: ptr EutChoir; voices: ptr EutChoirVoice; voiceCount: cint;
                  sampleRate: float32)
      {.importc: "eut_choir_init", header: "eut_dsp.h".}
proc c_choir_reset(g: ptr EutChoir)
      {.importc: "eut_choir_reset", header: "eut_dsp.h".}
proc c_choir_set(g: ptr EutChoir; vowel, tone, vibratoCents, pan, level: float32)
      {.importc: "eut_choir_set", header: "eut_dsp.h".}
proc c_choir_note_on(g: ptr EutChoir; note: cint; velocity: float32)
      {.importc: "eut_choir_note_on", header: "eut_dsp.h".}
proc c_choir_note_off(g: ptr EutChoir; note: cint)
      {.importc: "eut_choir_note_off", header: "eut_dsp.h".}
proc c_choir_all_off(g: ptr EutChoir)
      {.importc: "eut_choir_all_off", header: "eut_dsp.h".}
proc c_choir_process(g: ptr EutChoir; outL, outR: ptr float32; stride, n: cint;
                     bendSemitones, modCents: float32)
      {.importc: "eut_choir_process", header: "eut_dsp.h".}

proc c_reed_init(g: ptr EutReed; voices: ptr EutReedVoice; voiceCount: cint;
                 sampleRate: float32)
      {.importc: "eut_reed_init", header: "eut_dsp.h".}
proc c_reed_reset(g: ptr EutReed)
      {.importc: "eut_reed_reset", header: "eut_dsp.h".}
proc c_reed_set(g: ptr EutReed; tone, detuneCents, noise, attackSeconds,
                formantHz, pan, level: float32)
      {.importc: "eut_reed_set", header: "eut_dsp.h".}
proc c_reed_note_on(g: ptr EutReed; note: cint; velocity: float32)
      {.importc: "eut_reed_note_on", header: "eut_dsp.h".}
proc c_reed_note_off(g: ptr EutReed; note: cint)
      {.importc: "eut_reed_note_off", header: "eut_dsp.h".}
proc c_reed_all_off(g: ptr EutReed)
      {.importc: "eut_reed_all_off", header: "eut_dsp.h".}
proc c_reed_process(g: ptr EutReed; outL, outR: ptr float32; stride, n: cint;
                    bendSemitones, modCents: float32)
      {.importc: "eut_reed_process", header: "eut_dsp.h".}

proc c_size_inst_voice(): cint {.importc: "eut_abi_sizeof_inst_voice", header: "eut_dsp.h".}
proc c_size_organ_voice(): cint {.importc: "eut_abi_sizeof_organ_voice", header: "eut_dsp.h".}
proc c_size_organ(): cint {.importc: "eut_abi_sizeof_organ", header: "eut_dsp.h".}
proc c_size_piano_voice(): cint {.importc: "eut_abi_sizeof_piano_voice", header: "eut_dsp.h".}
proc c_size_piano(): cint {.importc: "eut_abi_sizeof_piano", header: "eut_dsp.h".}
proc c_size_guitar_voice(): cint {.importc: "eut_abi_sizeof_guitar_voice", header: "eut_dsp.h".}
proc c_size_guitar(): cint {.importc: "eut_abi_sizeof_guitar", header: "eut_dsp.h".}
proc c_size_drum_voice(): cint {.importc: "eut_abi_sizeof_drum_voice", header: "eut_dsp.h".}
proc c_size_drums(): cint {.importc: "eut_abi_sizeof_drums", header: "eut_dsp.h".}
proc c_size_flute_voice(): cint {.importc: "eut_abi_sizeof_flute_voice", header: "eut_dsp.h".}
proc c_size_flute(): cint {.importc: "eut_abi_sizeof_flute", header: "eut_dsp.h".}
proc c_size_bagpipe_voice(): cint {.importc: "eut_abi_sizeof_bagpipe_voice", header: "eut_dsp.h".}
proc c_size_bagpipe(): cint {.importc: "eut_abi_sizeof_bagpipe", header: "eut_dsp.h".}
proc c_size_strings_voice(): cint {.importc: "eut_abi_sizeof_strings_voice", header: "eut_dsp.h".}
proc c_size_strings(): cint {.importc: "eut_abi_sizeof_strings", header: "eut_dsp.h".}
proc c_size_bell_voice(): cint {.importc: "eut_abi_sizeof_bell_voice", header: "eut_dsp.h".}
proc c_size_bell(): cint {.importc: "eut_abi_sizeof_bell", header: "eut_dsp.h".}
proc c_size_pluck_voice(): cint {.importc: "eut_abi_sizeof_pluck_voice", header: "eut_dsp.h".}
proc c_size_pluck(): cint {.importc: "eut_abi_sizeof_pluck", header: "eut_dsp.h".}
proc c_size_recorder_voice(): cint {.importc: "eut_abi_sizeof_recorder_voice", header: "eut_dsp.h".}
proc c_size_recorder(): cint {.importc: "eut_abi_sizeof_recorder", header: "eut_dsp.h".}
proc c_size_brass_voice(): cint {.importc: "eut_abi_sizeof_brass_voice", header: "eut_dsp.h".}
proc c_size_brass(): cint {.importc: "eut_abi_sizeof_brass", header: "eut_dsp.h".}
proc c_size_timpani_voice(): cint {.importc: "eut_abi_sizeof_timpani_voice", header: "eut_dsp.h".}
proc c_size_timpani(): cint {.importc: "eut_abi_sizeof_timpani", header: "eut_dsp.h".}
proc c_size_choir_voice(): cint {.importc: "eut_abi_sizeof_choir_voice", header: "eut_dsp.h".}
proc c_size_choir(): cint {.importc: "eut_abi_sizeof_choir", header: "eut_dsp.h".}
proc c_size_reed_voice(): cint {.importc: "eut_abi_sizeof_reed_voice", header: "eut_dsp.h".}
proc c_size_reed(): cint {.importc: "eut_abi_sizeof_reed", header: "eut_dsp.h".}

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
proc isReady*(g: Organ): bool {.inline.} = not g.p.isNil
proc isReady*(g: Piano): bool {.inline.} = not g.p.isNil
proc isReady*(g: Guitar): bool {.inline.} = not g.p.isNil
proc isReady*(g: Drums): bool {.inline.} = not g.p.isNil
proc isReady*(g: Flute): bool {.inline.} = not g.p.isNil
proc isReady*(g: Bagpipe): bool {.inline.} = not g.p.isNil
proc isReady*(g: Strings): bool {.inline.} = not g.p.isNil
proc isReady*(g: Bell): bool {.inline.} = not g.p.isNil
proc isReady*(g: Pluck): bool {.inline.} = not g.p.isNil
proc isReady*(g: Recorder): bool {.inline.} = not g.p.isNil
proc isReady*(g: Brass): bool {.inline.} = not g.p.isNil
proc isReady*(g: Timpani): bool {.inline.} = not g.p.isNil
proc isReady*(g: Choir): bool {.inline.} = not g.p.isNil
proc isReady*(g: Reed): bool {.inline.} = not g.p.isNil

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

# --- инструменты ------------------------------------------------------------
#
# Общая схема владения памятью: состояние движка и массив голосов лежат в
# ОДНОМ блоке `allocState` (голоса — сразу за состоянием). Так освобождение
# сводится к одному `deallocShared`, а раскладку Nim не знает: адрес голосов
# считается как «начало блока + размер состояния», который сообщает сам C.

proc instVoices(state: pointer; stateBytes: int): pointer {.inline.} =
  ## Адрес массива голосов внутри блока состояния (`eut_inst.c` кладёт
  ## голоса сразу за состоянием движка). Байты к указателю добавляются
  ## байтовой арифметикой: складывать указатели разных типов нельзя.
  ## Хост обязан передать ровно `sizeof(состояние)`: движок сам размечает
  ## голоса шагом `sizeof(голос)`, и любое «улучшение» выравнивания на
  ## стороне Nim сдвинуло бы массив относительно ожидаемого движком.
  cast[pointer](cast[uint](state) + uint(stateBytes))

proc newOrgan*(voiceCount: int = 12; sampleRate: float32 = 48000.0f): Organ =
  let n = max(voiceCount, 1)
  let stateBytes = c_size_organ().int
  let voiceBytes = c_size_organ_voice().int
  result.p = allocState(stateBytes + voiceBytes * n)
  if result.p.isNil:
    return
  result.voiceCount = n
  c_organ_init(cast[ptr EutOrgan](result.p),
               cast[ptr EutOrganVoice](instVoices(result.p, stateBytes)),
               n.cint, sampleRate)

proc freeOrgan*(g: ptr Organ) {.inline.} =
  if g.isNil or g.p.isNil:
    return
  deallocShared(g.p)
  g.p = nil

proc organReset*(g: ptr Organ) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_organ_reset(cast[ptr EutOrgan](g.p))

proc organSet*(g: ptr Organ; bars, tone, clickLevel, vibratoCents, pan, level: float32) {.inline.} =
  ## `bars` — положение регистра (0 — флейты, 1 — полный микст) внутри
  ## фиксированной таблицы 8 частий; наружу выходит одним параметром,
  ## чтобы автоматизация регистровой ручки оставалась одномерной.
  if g.isNil or g.p.isNil: return
  c_organ_set(cast[ptr EutOrgan](g.p), bars, tone, clickLevel, vibratoCents, pan, level)

proc organNoteOn*(g: ptr Organ; note: int; velocity: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_organ_note_on(cast[ptr EutOrgan](g.p), note.cint, velocity)

proc organNoteOff*(g: ptr Organ; note: int) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_organ_note_off(cast[ptr EutOrgan](g.p), note.cint)

proc organAllOff*(g: ptr Organ) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_organ_all_off(cast[ptr EutOrgan](g.p))

proc organProcess*(g: ptr Organ; outL, outR: ptr float32; stride, n: int;
                   bendSemitones: float32 = 0.0f; modCents: float32 = 0.0f) {.inline.} =
  if g.isNil or g.p.isNil or n <= 0: return
  c_organ_process(cast[ptr EutOrgan](g.p), outL, outR, stride.cint, n.cint,
                  bendSemitones, modCents)

# --- фортепиано -------------------------------------------------------------

proc newPiano*(voiceCount: int = 16; sampleRate: float32 = 48000.0f): Piano =
  let n = max(voiceCount, 1)
  let stateBytes = c_size_piano().int
  let voiceBytes = c_size_piano_voice().int
  result.p = allocState(stateBytes + voiceBytes * n)
  if result.p.isNil:
    return
  result.voiceCount = n
  c_piano_init(cast[ptr EutPiano](result.p),
               cast[ptr EutPianoVoice](instVoices(result.p, stateBytes)),
               n.cint, sampleRate)

proc freePiano*(g: ptr Piano) {.inline.} =
  if g.isNil or g.p.isNil:
    return
  deallocShared(g.p)
  g.p = nil

proc pianoReset*(g: ptr Piano) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_piano_reset(cast[ptr EutPiano](g.p))

proc pianoSet*(g: ptr Piano; tone, decay, detuneCents, hammer, release, pan,
               level: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_piano_set(cast[ptr EutPiano](g.p), tone, decay, detuneCents, hammer, release,
              pan, level)

proc pianoNoteOn*(g: ptr Piano; note: int; velocity: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_piano_note_on(cast[ptr EutPiano](g.p), note.cint, velocity)

proc pianoNoteOff*(g: ptr Piano; note: int) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_piano_note_off(cast[ptr EutPiano](g.p), note.cint)

proc pianoPedal*(g: ptr Piano; down: bool) {.inline.} =
  ## CC64: нажатая педаль не гасит голос при note off, а удлиняет его
  ## затухание — то же поведение, что и в C-движке.
  if g.isNil or g.p.isNil: return
  c_piano_pedal(cast[ptr EutPiano](g.p), (if down: 1.cint else: 0.cint))

proc pianoAllOff*(g: ptr Piano) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_piano_all_off(cast[ptr EutPiano](g.p))

proc pianoProcess*(g: ptr Piano; outL, outR: ptr float32; stride, n: int;
                   bendSemitones: float32 = 0.0f; modCents: float32 = 0.0f) {.inline.} =
  if g.isNil or g.p.isNil or n <= 0: return
  c_piano_process(cast[ptr EutPiano](g.p), outL, outR, stride.cint, n.cint,
                  bendSemitones, modCents)

# --- гитара ------------------------------------------------------------------

const GuitarLowestHz* = 8.0f
  ## Нижняя граница строя, под которую считается струнная память: MIDI 0
  ## ≈ 8.18 Гц, а амплитудная модуляция длины струны (bend, вибрато) может
  ## период удлинить, поэтому нужен запас.

const GuitarMaxSampleRate* = 96000.0f
  ## Частота дискретизации, под которую память струн выделяется сразу.
  ##
  ## Нода не знает фактическую частоту на момент создания состояния, а
  ## перевыделять струны в audio thread нельзя. Поэтому память берётся
  ## с запасом до 96 кГц: переинициализация на 44.1/48/88.2/96 кГц
  ## помещается в уже выделенный блок, а выше — честно отказывает
  ## (`guitarInitAt`), вместо того чтобы выйти за границу.

proc guitarMemoryFrames*(sampleRate, lowestHz: float32): int =
  ## Кадров линии задержки на одну струну. Не меньше 2: при меньшем
  ## значении C-движок отказывается инициализироваться.
  max(int(sampleRate / max(lowestHz, 1.0f)) + 8, 2)

proc newGuitar*(voiceCount: int = 8; sampleRate: float32 = 48000.0f): Guitar =
  let n = max(voiceCount, 1)
  let stateBytes = c_size_guitar().int
  let voiceBytes = c_size_guitar_voice().int
  let lineCap = guitarMemoryFrames(max(sampleRate, GuitarMaxSampleRate),
                                  GuitarLowestHz)
  result.p = allocState(stateBytes + voiceBytes * n)
  if result.p.isNil:
    return
  result.voiceCount = n
  result.lineCap = lineCap
  result.memory = allocState(lineCap * n * sizeof(float32))
  if result.memory.isNil:
    deallocShared(result.p)
    result.p = nil
    return
  c_guitar_init(cast[ptr EutGuitar](result.p),
                cast[ptr EutGuitarVoice](instVoices(result.p, stateBytes)),
                n.cint, cast[ptr float32](result.memory), lineCap.cint, sampleRate)

proc freeGuitar*(g: ptr Guitar) {.inline.} =
  if g.isNil:
    return
  if not g.memory.isNil:
    deallocShared(g.memory)
    g.memory = nil
  if not g.p.isNil:
    deallocShared(g.p)
    g.p = nil

proc guitarReset*(g: ptr Guitar) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_guitar_reset(cast[ptr EutGuitar](g.p))

proc guitarSet*(g: ptr Guitar; pick, damping, tone, drive, mute, release, pan,
                level: float32) {.inline.} =
  ## `mute` — глушение ладонью (0 — открытая струна, 1 — плотный palm mute),
  ## `drive` — кабинетный перегруз с компенсацией усиления.
  if g.isNil or g.p.isNil: return
  c_guitar_set(cast[ptr EutGuitar](g.p), pick, damping, tone, drive, mute,
               release, pan, level)

proc guitarNoteOn*(g: ptr Guitar; note: int; velocity: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_guitar_note_on(cast[ptr EutGuitar](g.p), note.cint, velocity)

proc guitarNoteOff*(g: ptr Guitar; note: int) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_guitar_note_off(cast[ptr EutGuitar](g.p), note.cint)

proc guitarAllOff*(g: ptr Guitar) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_guitar_all_off(cast[ptr EutGuitar](g.p))

proc guitarProcess*(g: ptr Guitar; outL, outR: ptr float32; stride, n: int;
                    bendSemitones: float32 = 0.0f; modCents: float32 = 0.0f) {.inline.} =
  if g.isNil or g.p.isNil or n <= 0: return
  c_guitar_process(cast[ptr EutGuitar](g.p), outL, outR, stride.cint, n.cint,
                   bendSemitones, modCents)

# --- ударные -----------------------------------------------------------------

proc drumsPieceForNote*(note: int): cint {.inline.} =
  ## Какая часть установки отвечает на ноту MIDI. `-1` — нота вне карты
  ## (GM-совместимой, но не полной): движок такую ноту честно игнорирует,
  ## а не подменяет случайным куском.
  c_drums_piece_for_note(note.cint)

proc newDrums*(voiceCount: int = 16; sampleRate: float32 = 48000.0f): Drums =
  let n = max(voiceCount, 1)
  let stateBytes = c_size_drums().int
  let voiceBytes = c_size_drum_voice().int
  result.p = allocState(stateBytes + voiceBytes * n)
  if result.p.isNil:
    return
  result.voiceCount = n
  c_drums_init(cast[ptr EutDrums](result.p),
               cast[ptr EutDrumVoice](instVoices(result.p, stateBytes)),
               n.cint, sampleRate)

proc freeDrums*(g: ptr Drums) {.inline.} =
  if g.isNil or g.p.isNil:
    return
  deallocShared(g.p)
  g.p = nil

proc drumsReset*(g: ptr Drums) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_drums_reset(cast[ptr EutDrums](g.p))

proc drumsSet*(g: ptr Drums; tune, decay, snappy, tone, drive, pan, level: float32) {.inline.} =
  ## `tune` — общий строй установки в полутонах (0 — «как записано»),
  ## `decay` — множитель длительности, `snappy` — доля пружины малого.
  if g.isNil or g.p.isNil: return
  c_drums_set(cast[ptr EutDrums](g.p), tune, decay, snappy, tone, drive, pan, level)

proc drumsNoteOn*(g: ptr Drums; note: int; velocity: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_drums_note_on(cast[ptr EutDrums](g.p), note.cint, velocity)

proc drumsNoteOff*(g: ptr Drums; note: int) {.inline.} =
  ## Отпускание ноты гасит тарелку и хэт: так закрывается открытый хэт,
  ## когда педаль опускают или рука возвращается на пэд.
  if g.isNil or g.p.isNil: return
  c_drums_note_off(cast[ptr EutDrums](g.p), note.cint)

proc drumsAllOff*(g: ptr Drums) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_drums_all_off(cast[ptr EutDrums](g.p))

proc drumsProcess*(g: ptr Drums; outL, outR: ptr float32; stride, n: int) {.inline.} =
  if g.isNil or g.p.isNil or n <= 0: return
  c_drums_process(cast[ptr EutDrums](g.p), outL, outR, stride.cint, n.cint)

# --- смена частоты дискретизации --------------------------------------------
#
# Все четыре движка фиксируют `sampleRate` в `*_init` (в `*_set` его нет:
# пересчёт коэффициентов на каждый блок — это лишняя работа, а параметры
# и без того приходят раз в блок). Нода узнаёт фактическую частоту только
# из контекста обработки, поэтому нужен путь «переинициализироваться на
# другой частоте».
#
# Переинициализация идёт по УЖЕ ВЫДЕЛЕННОЙ памяти и ничего не аллоцирует,
# а значит безопасна и в audio thread: голоса просто сбрасываются в тишину,
# что при смене частоты дискретизации и так неизбежно.

proc organInitAt*(g: ptr Organ; sampleRate: float32): bool =
  if g.isNil or g.p.isNil:
    return false
  let stateBytes = c_size_organ().int
  c_organ_init(cast[ptr EutOrgan](g.p),
               cast[ptr EutOrganVoice](instVoices(g.p, stateBytes)),
               g.voiceCount.cint, sampleRate)
  true

proc pianoInitAt*(g: ptr Piano; sampleRate: float32): bool =
  if g.isNil or g.p.isNil:
    return false
  let stateBytes = c_size_piano().int
  c_piano_init(cast[ptr EutPiano](g.p),
               cast[ptr EutPianoVoice](instVoices(g.p, stateBytes)),
               g.voiceCount.cint, sampleRate)
  true

proc drumsInitAt*(g: ptr Drums; sampleRate: float32): bool =
  if g.isNil or g.p.isNil:
    return false
  let stateBytes = c_size_drums().int
  c_drums_init(cast[ptr EutDrums](g.p),
               cast[ptr EutDrumVoice](instVoices(g.p, stateBytes)),
               g.voiceCount.cint, sampleRate)
  true

proc guitarInitAt*(g: ptr Guitar; sampleRate: float32): bool =
  ## `false` — частота выше той, под которую выделена память струн
  ## (`GuitarMaxSampleRate`). Лучше отказать и оставить прежнюю частоту,
  ## чем писать за границей блока.
  if g.isNil or g.p.isNil or g.memory.isNil:
    return false
  let needed = guitarMemoryFrames(sampleRate, GuitarLowestHz)
  if needed > g.lineCap:
    return false
  let stateBytes = c_size_guitar().int
  c_guitar_init(cast[ptr EutGuitar](g.p),
                cast[ptr EutGuitarVoice](instVoices(g.p, stateBytes)),
                g.voiceCount.cint, cast[ptr float32](g.memory),
                g.lineCap.cint, sampleRate)
  true

# --- флейта -----------------------------------------------------------------

proc newFlute*(voiceCount: int = 8; sampleRate: float32 = 48000.0f): Flute =
  let n = max(voiceCount, 1)
  let stateBytes = c_size_flute().int
  let voiceBytes = c_size_flute_voice().int
  result.p = allocState(stateBytes + voiceBytes * n)
  if result.p.isNil:
    return
  result.voiceCount = n
  c_flute_init(cast[ptr EutFlute](result.p),
               cast[ptr EutFluteVoice](instVoices(result.p, stateBytes)),
               n.cint, sampleRate)

proc freeFlute*(g: ptr Flute) {.inline.} =
  if g.isNil or g.p.isNil: return
  deallocShared(g.p)
  g.p = nil

proc fluteInitAt*(g: ptr Flute; sampleRate: float32): bool =
  if g.isNil or g.p.isNil:
    return false
  let stateBytes = c_size_flute().int
  c_flute_init(cast[ptr EutFlute](g.p),
               cast[ptr EutFluteVoice](instVoices(g.p, stateBytes)),
               g.voiceCount.cint, sampleRate)
  true

proc fluteSet*(g: ptr Flute; tone, breath, vibratoCents, pan, level: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_flute_set(cast[ptr EutFlute](g.p), tone, breath, vibratoCents, pan, level)

proc fluteNoteOn*(g: ptr Flute; note: int; velocity: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_flute_note_on(cast[ptr EutFlute](g.p), note.cint, velocity)

proc fluteNoteOff*(g: ptr Flute; note: int) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_flute_note_off(cast[ptr EutFlute](g.p), note.cint)

proc fluteReset*(g: ptr Flute) {.inline.} =
  ## Полный сброс состояния голосов: фазы, фильтры, линии задержки,
  ## счётчик голосов. `fluteAllOff` только снимает ноты — для паники и
  ## сброса транспорта этого мало: остаточное состояние даёт призвук на
  ## следующем старте. Параметры (tone, level, …) при этом сохраняются
  ## (issue #316).
  if g.isNil or g.p.isNil: return
  c_flute_reset(cast[ptr EutFlute](g.p))

proc fluteAllOff*(g: ptr Flute) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_flute_all_off(cast[ptr EutFlute](g.p))

proc fluteProcess*(g: ptr Flute; outL, outR: ptr float32; stride, n: int;
                   bendSemitones: float32 = 0.0f; modCents: float32 = 0.0f) {.inline.} =
  if g.isNil or g.p.isNil or n <= 0: return
  c_flute_process(cast[ptr EutFlute](g.p), outL, outR, stride.cint, n.cint,
                  bendSemitones, modCents)

# --- волынка ----------------------------------------------------------------

proc newBagpipe*(voiceCount: int = 4; sampleRate: float32 = 48000.0f): Bagpipe =
  let n = max(voiceCount, 1)
  let stateBytes = c_size_bagpipe().int
  let voiceBytes = c_size_bagpipe_voice().int
  result.p = allocState(stateBytes + voiceBytes * n)
  if result.p.isNil:
    return
  result.voiceCount = n
  c_bagpipe_init(cast[ptr EutBagpipe](result.p),
                 cast[ptr EutBagpipeVoice](instVoices(result.p, stateBytes)),
                 n.cint, sampleRate)

proc freeBagpipe*(g: ptr Bagpipe) {.inline.} =
  if g.isNil or g.p.isNil: return
  deallocShared(g.p)
  g.p = nil

proc bagpipeInitAt*(g: ptr Bagpipe; sampleRate: float32): bool =
  if g.isNil or g.p.isNil:
    return false
  let stateBytes = c_size_bagpipe().int
  c_bagpipe_init(cast[ptr EutBagpipe](g.p),
                 cast[ptr EutBagpipeVoice](instVoices(g.p, stateBytes)),
                 g.voiceCount.cint, sampleRate)
  true

proc bagpipeSet*(g: ptr Bagpipe; tone, droneLevel, droneFreq, pan,
                 level: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_bagpipe_set(cast[ptr EutBagpipe](g.p), tone, droneLevel, droneFreq, pan, level)

proc bagpipeNoteOn*(g: ptr Bagpipe; note: int; velocity: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_bagpipe_note_on(cast[ptr EutBagpipe](g.p), note.cint, velocity)

proc bagpipeNoteOff*(g: ptr Bagpipe; note: int) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_bagpipe_note_off(cast[ptr EutBagpipe](g.p), note.cint)

proc bagpipeReset*(g: ptr Bagpipe) {.inline.} =
  ## Полный сброс состояния голосов: фазы, фильтры, линии задержки,
  ## счётчик голосов. `bagpipeAllOff` только снимает ноты — для паники и
  ## сброса транспорта этого мало: остаточное состояние даёт призвук на
  ## следующем старте. Параметры (tone, level, …) при этом сохраняются
  ## (issue #316).
  if g.isNil or g.p.isNil: return
  c_bagpipe_reset(cast[ptr EutBagpipe](g.p))

proc bagpipeAllOff*(g: ptr Bagpipe) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_bagpipe_all_off(cast[ptr EutBagpipe](g.p))

proc bagpipeProcess*(g: ptr Bagpipe; outL, outR: ptr float32; stride,
                     n: int) {.inline.} =
  if g.isNil or g.p.isNil or n <= 0: return
  c_bagpipe_process(cast[ptr EutBagpipe](g.p), outL, outR, stride.cint, n.cint)

# --- смычковые ---------------------------------------------------------------

proc newStrings*(voiceCount: int = 8; sampleRate: float32 = 48000.0f): Strings =
  let n = max(voiceCount, 1)
  let stateBytes = c_size_strings().int
  let voiceBytes = c_size_strings_voice().int
  result.p = allocState(stateBytes + voiceBytes * n)
  if result.p.isNil:
    return
  result.voiceCount = n
  c_strings_init(cast[ptr EutStrings](result.p),
                 cast[ptr EutStringsVoice](instVoices(result.p, stateBytes)),
                 n.cint, sampleRate)

proc freeStrings*(g: ptr Strings) {.inline.} =
  if g.isNil or g.p.isNil:
    return
  deallocShared(g.p)
  g.p = nil

proc stringsInitAt*(g: ptr Strings; sampleRate: float32): bool =
  if g.isNil or g.p.isNil:
    return false
  let stateBytes = c_size_strings().int
  c_strings_init(cast[ptr EutStrings](g.p),
                 cast[ptr EutStringsVoice](instVoices(g.p, stateBytes)),
                 g.voiceCount.cint, sampleRate)
  true

proc stringsSet*(g: ptr Strings; tone, vibratoCents, ensembleCents, pan,
                 level: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_strings_set(cast[ptr EutStrings](g.p), tone, vibratoCents, ensembleCents, pan,
                level)

proc stringsNoteOn*(g: ptr Strings; note: int; velocity: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_strings_note_on(cast[ptr EutStrings](g.p), note.cint, velocity)

proc stringsNoteOff*(g: ptr Strings; note: int) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_strings_note_off(cast[ptr EutStrings](g.p), note.cint)

proc stringsReset*(g: ptr Strings) {.inline.} =
  ## Полный сброс состояния голосов: фазы, фильтры, линии задержки,
  ## счётчик голосов. `stringsAllOff` только снимает ноты — для паники и
  ## сброса транспорта этого мало: остаточное состояние даёт призвук на
  ## следующем старте. Параметры (tone, level, …) при этом сохраняются
  ## (issue #316).
  if g.isNil or g.p.isNil: return
  c_strings_reset(cast[ptr EutStrings](g.p))

proc stringsAllOff*(g: ptr Strings) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_strings_all_off(cast[ptr EutStrings](g.p))

proc stringsProcess*(g: ptr Strings; outL, outR: ptr float32; stride,
                     n: int; bendSemitones: float32 = 0.0f;
                     modCents: float32 = 0.0f) {.inline.} =
  if g.isNil or g.p.isNil or n <= 0: return
  c_strings_process(cast[ptr EutStrings](g.p), outL, outR, stride.cint, n.cint,
                    bendSemitones, modCents)

# --- колокол -----------------------------------------------------------------

proc newBell*(voiceCount: int = 12; sampleRate: float32 = 48000.0f): Bell =
  let n = max(voiceCount, 1)
  let stateBytes = c_size_bell().int
  let voiceBytes = c_size_bell_voice().int
  result.p = allocState(stateBytes + voiceBytes * n)
  if result.p.isNil:
    return
  result.voiceCount = n
  c_bell_init(cast[ptr EutBell](result.p),
              cast[ptr EutBellVoice](instVoices(result.p, stateBytes)),
              n.cint, sampleRate)

proc freeBell*(g: ptr Bell) {.inline.} =
  if g.isNil or g.p.isNil:
    return
  deallocShared(g.p)
  g.p = nil

proc bellInitAt*(g: ptr Bell; sampleRate: float32): bool =
  if g.isNil or g.p.isNil:
    return false
  let stateBytes = c_size_bell().int
  c_bell_init(cast[ptr EutBell](g.p),
              cast[ptr EutBellVoice](instVoices(g.p, stateBytes)),
              g.voiceCount.cint, sampleRate)
  true

proc bellSet*(g: ptr Bell; tune, decay, tone, pan, level: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_bell_set(cast[ptr EutBell](g.p), tune, decay, tone, pan, level)

proc bellNoteOn*(g: ptr Bell; note: int; velocity: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_bell_note_on(cast[ptr EutBell](g.p), note.cint, velocity)

proc bellNoteOff*(g: ptr Bell; note: int) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_bell_note_off(cast[ptr EutBell](g.p), note.cint)

proc bellReset*(g: ptr Bell) {.inline.} =
  ## Полный сброс состояния голосов: фазы, фильтры, линии задержки,
  ## счётчик голосов. `bellAllOff` только снимает ноты — для паники и
  ## сброса транспорта этого мало: остаточное состояние даёт призвук на
  ## следующем старте. Параметры (tone, level, …) при этом сохраняются
  ## (issue #316).
  if g.isNil or g.p.isNil: return
  c_bell_reset(cast[ptr EutBell](g.p))

proc bellAllOff*(g: ptr Bell) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_bell_all_off(cast[ptr EutBell](g.p))

proc bellProcess*(g: ptr Bell; outL, outR: ptr float32; stride,
                  n: int) {.inline.} =
  if g.isNil or g.p.isNil or n <= 0: return
  c_bell_process(cast[ptr EutBell](g.p), outL, outR, stride.cint, n.cint)

# --- щипковые (арфа, клавесин) ------------------------------------------------

const PluckLowestHz* = 20.0f
  ## Нижняя граница строя, под которую считается память струн. Литавры — не
  ## щипковые, а вот арфа в самой низкой октаве опускается ниже C2, поэтому
  ## запас нужен: 20 Гц ≈ MIDI 15.

proc pluckMemoryFrames*(sampleRate, lowestHz: float32): int =
  ## Кадров линии задержки на одну струну.
  max(int(sampleRate / max(lowestHz, 1.0f)) + 8, 2)

proc newPluck*(voiceCount: int = 12; sampleRate: float32 = 48000.0f): Pluck =
  let n = max(voiceCount, 1)
  let stateBytes = c_size_pluck().int
  let voiceBytes = c_size_pluck_voice().int
  let lineCap = pluckMemoryFrames(max(sampleRate, 96000.0f), PluckLowestHz)
  result.p = allocState(stateBytes + voiceBytes * n)
  if result.p.isNil:
    return
  result.voiceCount = n
  result.lineCap = lineCap
  result.memory = allocState(lineCap * n * sizeof(float32))
  if result.memory.isNil:
    deallocShared(result.p)
    result.p = nil
    return
  c_pluck_init(cast[ptr EutPluck](result.p),
               cast[ptr EutPluckVoice](instVoices(result.p, stateBytes)),
               n.cint, cast[ptr float32](result.memory), lineCap.cint, sampleRate)

proc freePluck*(g: ptr Pluck) {.inline.} =
  if g.isNil:
    return
  if not g.memory.isNil:
    deallocShared(g.memory)
    g.memory = nil
  if not g.p.isNil:
    deallocShared(g.p)
    g.p = nil

proc pluckInitAt*(g: ptr Pluck; sampleRate: float32): bool =
  ## Переинициализация на другой частоте. Отказывает, если линии струн не
  ## помещаются в уже выделенный блок: выходить за границу памяти нельзя.
  if g.isNil or g.p.isNil or g.memory.isNil:
    return false
  if pluckMemoryFrames(sampleRate, PluckLowestHz) > g.lineCap:
    return false
  let stateBytes = c_size_pluck().int
  c_pluck_init(cast[ptr EutPluck](g.p),
               cast[ptr EutPluckVoice](instVoices(g.p, stateBytes)),
               g.voiceCount.cint, cast[ptr float32](g.memory), g.lineCap.cint,
               sampleRate)
  true

proc pluckSet*(g: ptr Pluck; tone, damping, pluck, body, bodyHz, nylon, pan,
               level: float32) {.inline.} =
  ## `nylon` — доля нейлоновой струны: 0 — сталь (арфа, клавесин), 1 — нейлон
  ## (укулеле). При 0 путь обработки прежний, бит-в-бит.
  if g.isNil or g.p.isNil: return
  c_pluck_set(cast[ptr EutPluck](g.p), tone, damping, pluck, body, bodyHz, nylon,
              pan, level)

proc pluckNoteOn*(g: ptr Pluck; note: int; velocity: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_pluck_note_on(cast[ptr EutPluck](g.p), note.cint, velocity)

proc pluckNoteOff*(g: ptr Pluck; note: int) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_pluck_note_off(cast[ptr EutPluck](g.p), note.cint)

proc pluckReset*(g: ptr Pluck) {.inline.} =
  ## Полный сброс состояния голосов: фазы, фильтры, линии задержки,
  ## счётчик голосов. `pluckAllOff` только снимает ноты — для паники и
  ## сброса транспорта этого мало: остаточное состояние даёт призвук на
  ## следующем старте. Параметры (tone, level, …) при этом сохраняются
  ## (issue #316).
  if g.isNil or g.p.isNil: return
  c_pluck_reset(cast[ptr EutPluck](g.p))

proc pluckAllOff*(g: ptr Pluck) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_pluck_all_off(cast[ptr EutPluck](g.p))

proc pluckProcess*(g: ptr Pluck; outL, outR: ptr float32; stride,
                   n: int) {.inline.} =
  if g.isNil or g.p.isNil or n <= 0: return
  c_pluck_process(cast[ptr EutPluck](g.p), outL, outR, stride.cint, n.cint)

# --- свирель -----------------------------------------------------------------

proc newRecorder*(voiceCount: int = 8; sampleRate: float32 = 48000.0f): Recorder =
  let n = max(voiceCount, 1)
  let stateBytes = c_size_recorder().int
  let voiceBytes = c_size_recorder_voice().int
  result.p = allocState(stateBytes + voiceBytes * n)
  if result.p.isNil:
    return
  result.voiceCount = n
  c_recorder_init(cast[ptr EutRecorder](result.p),
                  cast[ptr EutRecorderVoice](instVoices(result.p, stateBytes)),
                  n.cint, sampleRate)

proc freeRecorder*(g: ptr Recorder) {.inline.} =
  if g.isNil or g.p.isNil:
    return
  deallocShared(g.p)
  g.p = nil

proc recorderInitAt*(g: ptr Recorder; sampleRate: float32): bool =
  if g.isNil or g.p.isNil:
    return false
  let stateBytes = c_size_recorder().int
  c_recorder_init(cast[ptr EutRecorder](g.p),
                  cast[ptr EutRecorderVoice](instVoices(g.p, stateBytes)),
                  g.voiceCount.cint, sampleRate)
  true

proc recorderSet*(g: ptr Recorder; tone, breath, vibratoCents, pan,
                  level: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_recorder_set(cast[ptr EutRecorder](g.p), tone, breath, vibratoCents, pan,
                 level)

proc recorderNoteOn*(g: ptr Recorder; note: int; velocity: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_recorder_note_on(cast[ptr EutRecorder](g.p), note.cint, velocity)

proc recorderNoteOff*(g: ptr Recorder; note: int) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_recorder_note_off(cast[ptr EutRecorder](g.p), note.cint)

proc recorderReset*(g: ptr Recorder) {.inline.} =
  ## Полный сброс состояния голосов: фазы, фильтры, линии задержки,
  ## счётчик голосов. `recorderAllOff` только снимает ноты — для паники и
  ## сброса транспорта этого мало: остаточное состояние даёт призвук на
  ## следующем старте. Параметры (tone, level, …) при этом сохраняются
  ## (issue #316).
  if g.isNil or g.p.isNil: return
  c_recorder_reset(cast[ptr EutRecorder](g.p))

proc recorderAllOff*(g: ptr Recorder) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_recorder_all_off(cast[ptr EutRecorder](g.p))

proc recorderProcess*(g: ptr Recorder; outL, outR: ptr float32; stride,
                      n: int; bendSemitones: float32 = 0.0f;
                      modCents: float32 = 0.0f) {.inline.} =
  if g.isNil or g.p.isNil or n <= 0: return
  c_recorder_process(cast[ptr EutRecorder](g.p), outL, outR, stride.cint, n.cint,
                     bendSemitones, modCents)

# --- медь --------------------------------------------------------------------

proc newBrass*(voiceCount: int = 8; sampleRate: float32 = 48000.0f): Brass =
  let n = max(voiceCount, 1)
  let stateBytes = c_size_brass().int
  let voiceBytes = c_size_brass_voice().int
  result.p = allocState(stateBytes + voiceBytes * n)
  if result.p.isNil:
    return
  result.voiceCount = n
  c_brass_init(cast[ptr EutBrass](result.p),
               cast[ptr EutBrassVoice](instVoices(result.p, stateBytes)),
               n.cint, sampleRate)

proc freeBrass*(g: ptr Brass) {.inline.} =
  if g.isNil or g.p.isNil:
    return
  deallocShared(g.p)
  g.p = nil

proc brassInitAt*(g: ptr Brass; sampleRate: float32): bool =
  if g.isNil or g.p.isNil:
    return false
  let stateBytes = c_size_brass().int
  c_brass_init(cast[ptr EutBrass](g.p),
               cast[ptr EutBrassVoice](instVoices(g.p, stateBytes)),
               g.voiceCount.cint, sampleRate)
  true

proc brassSet*(g: ptr Brass; tone, rasp, vibratoCents, pan, level: float32)
    {.inline.} =
  if g.isNil or g.p.isNil: return
  c_brass_set(cast[ptr EutBrass](g.p), tone, rasp, vibratoCents, pan, level)

proc brassNoteOn*(g: ptr Brass; note: int; velocity: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_brass_note_on(cast[ptr EutBrass](g.p), note.cint, velocity)

proc brassNoteOff*(g: ptr Brass; note: int) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_brass_note_off(cast[ptr EutBrass](g.p), note.cint)

proc brassReset*(g: ptr Brass) {.inline.} =
  ## Полный сброс состояния голосов: фазы, фильтры, линии задержки,
  ## счётчик голосов. `brassAllOff` только снимает ноты — для паники и
  ## сброса транспорта этого мало: остаточное состояние даёт призвук на
  ## следующем старте. Параметры (tone, level, …) при этом сохраняются
  ## (issue #316).
  if g.isNil or g.p.isNil: return
  c_brass_reset(cast[ptr EutBrass](g.p))

proc brassAllOff*(g: ptr Brass) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_brass_all_off(cast[ptr EutBrass](g.p))

proc brassProcess*(g: ptr Brass; outL, outR: ptr float32; stride, n: int;
                   bendSemitones: float32 = 0.0f; modCents: float32 = 0.0f)
    {.inline.} =
  if g.isNil or g.p.isNil or n <= 0: return
  c_brass_process(cast[ptr EutBrass](g.p), outL, outR, stride.cint, n.cint,
                  bendSemitones, modCents)

# --- литавры -----------------------------------------------------------------

proc newTimpani*(voiceCount: int = 6; sampleRate: float32 = 48000.0f): Timpani =
  let n = max(voiceCount, 1)
  let stateBytes = c_size_timpani().int
  let voiceBytes = c_size_timpani_voice().int
  result.p = allocState(stateBytes + voiceBytes * n)
  if result.p.isNil:
    return
  result.voiceCount = n
  c_timpani_init(cast[ptr EutTimpani](result.p),
                 cast[ptr EutTimpaniVoice](instVoices(result.p, stateBytes)),
                 n.cint, sampleRate)

proc freeTimpani*(g: ptr Timpani) {.inline.} =
  if g.isNil or g.p.isNil:
    return
  deallocShared(g.p)
  g.p = nil

proc timpaniInitAt*(g: ptr Timpani; sampleRate: float32): bool =
  if g.isNil or g.p.isNil:
    return false
  let stateBytes = c_size_timpani().int
  c_timpani_init(cast[ptr EutTimpani](g.p),
                 cast[ptr EutTimpaniVoice](instVoices(g.p, stateBytes)),
                 g.voiceCount.cint, sampleRate)
  true

proc timpaniSet*(g: ptr Timpani; tune, decay, tone, pan, level: float32)
    {.inline.} =
  if g.isNil or g.p.isNil: return
  c_timpani_set(cast[ptr EutTimpani](g.p), tune, decay, tone, pan, level)

proc timpaniNoteOn*(g: ptr Timpani; note: int; velocity: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_timpani_note_on(cast[ptr EutTimpani](g.p), note.cint, velocity)

proc timpaniNoteOff*(g: ptr Timpani; note: int) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_timpani_note_off(cast[ptr EutTimpani](g.p), note.cint)

proc timpaniReset*(g: ptr Timpani) {.inline.} =
  ## Полный сброс состояния голосов: фазы, фильтры, линии задержки,
  ## счётчик голосов. `timpaniAllOff` только снимает ноты — для паники и
  ## сброса транспорта этого мало: остаточное состояние даёт призвук на
  ## следующем старте. Параметры (tone, level, …) при этом сохраняются
  ## (issue #316).
  if g.isNil or g.p.isNil: return
  c_timpani_reset(cast[ptr EutTimpani](g.p))

proc timpaniAllOff*(g: ptr Timpani) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_timpani_all_off(cast[ptr EutTimpani](g.p))

proc timpaniProcess*(g: ptr Timpani; outL, outR: ptr float32; stride,
                     n: int) {.inline.} =
  if g.isNil or g.p.isNil or n <= 0: return
  c_timpani_process(cast[ptr EutTimpani](g.p), outL, outR, stride.cint, n.cint)

# --- хор ---------------------------------------------------------------------

proc newChoir*(voiceCount: int = 12; sampleRate: float32 = 48000.0f): Choir =
  let n = max(voiceCount, 1)
  let stateBytes = c_size_choir().int
  let voiceBytes = c_size_choir_voice().int
  result.p = allocState(stateBytes + voiceBytes * n)
  if result.p.isNil:
    return
  result.voiceCount = n
  c_choir_init(cast[ptr EutChoir](result.p),
               cast[ptr EutChoirVoice](instVoices(result.p, stateBytes)),
               n.cint, sampleRate)

proc freeChoir*(g: ptr Choir) {.inline.} =
  if g.isNil or g.p.isNil:
    return
  deallocShared(g.p)
  g.p = nil

proc choirInitAt*(g: ptr Choir; sampleRate: float32): bool =
  if g.isNil or g.p.isNil:
    return false
  let stateBytes = c_size_choir().int
  c_choir_init(cast[ptr EutChoir](g.p),
               cast[ptr EutChoirVoice](instVoices(g.p, stateBytes)),
               g.voiceCount.cint, sampleRate)
  true

proc choirSet*(g: ptr Choir; vowel, tone, vibratoCents, pan, level: float32)
    {.inline.} =
  if g.isNil or g.p.isNil: return
  c_choir_set(cast[ptr EutChoir](g.p), vowel, tone, vibratoCents, pan, level)

proc choirNoteOn*(g: ptr Choir; note: int; velocity: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_choir_note_on(cast[ptr EutChoir](g.p), note.cint, velocity)

proc choirNoteOff*(g: ptr Choir; note: int) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_choir_note_off(cast[ptr EutChoir](g.p), note.cint)

proc choirReset*(g: ptr Choir) {.inline.} =
  ## Полный сброс состояния голосов: фазы, фильтры, линии задержки,
  ## счётчик голосов. `choirAllOff` только снимает ноты — для паники и
  ## сброса транспорта этого мало: остаточное состояние даёт призвук на
  ## следующем старте. Параметры (tone, level, …) при этом сохраняются
  ## (issue #316).
  if g.isNil or g.p.isNil: return
  c_choir_reset(cast[ptr EutChoir](g.p))

proc choirAllOff*(g: ptr Choir) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_choir_all_off(cast[ptr EutChoir](g.p))

proc choirProcess*(g: ptr Choir; outL, outR: ptr float32; stride, n: int;
                   bendSemitones: float32 = 0.0f; modCents: float32 = 0.0f)
    {.inline.} =
  if g.isNil or g.p.isNil or n <= 0: return
  c_choir_process(cast[ptr EutChoir](g.p), outL, outR, stride.cint, n.cint,
                  bendSemitones, modCents)

# --- свободноязычковые (баян, губная гармошка) --------------------------------

proc newReed*(voiceCount: int = 12; sampleRate: float32 = 48000.0f): Reed =
  let n = max(voiceCount, 1)
  let stateBytes = c_size_reed().int
  let voiceBytes = c_size_reed_voice().int
  result.p = allocState(stateBytes + voiceBytes * n)
  if result.p.isNil:
    return
  result.voiceCount = n
  c_reed_init(cast[ptr EutReed](result.p),
              cast[ptr EutReedVoice](instVoices(result.p, stateBytes)),
              n.cint, sampleRate)

proc freeReed*(g: ptr Reed) {.inline.} =
  if g.isNil or g.p.isNil:
    return
  deallocShared(g.p)
  g.p = nil

proc reedInitAt*(g: ptr Reed; sampleRate: float32): bool =
  if g.isNil or g.p.isNil:
    return false
  let stateBytes = c_size_reed().int
  c_reed_init(cast[ptr EutReed](g.p),
              cast[ptr EutReedVoice](instVoices(g.p, stateBytes)),
              g.voiceCount.cint, sampleRate)
  true

proc reedSet*(g: ptr Reed; tone, detuneCents, noise, attackSeconds, formantHz,
              pan, level: float32) {.inline.} =
  ## `detuneCents` — разлив (0 — сухой строй, как у гармошки), `formantHz` —
  ## резонанс камеры (баян ниже, гармошка выше).
  if g.isNil or g.p.isNil: return
  c_reed_set(cast[ptr EutReed](g.p), tone, detuneCents, noise, attackSeconds,
             formantHz, pan, level)

proc reedNoteOn*(g: ptr Reed; note: int; velocity: float32) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_reed_note_on(cast[ptr EutReed](g.p), note.cint, velocity)

proc reedNoteOff*(g: ptr Reed; note: int) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_reed_note_off(cast[ptr EutReed](g.p), note.cint)

proc reedReset*(g: ptr Reed) {.inline.} =
  ## Полный сброс состояния голосов: фазы язычков, резонаторы камеры, шум
  ## воздуха, счётчик голосов. `reedAllOff` только снимает ноты — для паники
  ## и сброса транспорта этого мало: остаточное состояние даёт призвук на
  ## следующем старте. Параметры (tone, level, …) при этом сохраняются
  ## (issue #316).
  if g.isNil or g.p.isNil: return
  c_reed_reset(cast[ptr EutReed](g.p))

proc reedAllOff*(g: ptr Reed) {.inline.} =
  if g.isNil or g.p.isNil: return
  c_reed_all_off(cast[ptr EutReed](g.p))

proc reedProcess*(g: ptr Reed; outL, outR: ptr float32; stride, n: int;
                  bendSemitones: float32 = 0.0f; modCents: float32 = 0.0f)
    {.inline.} =
  if g.isNil or g.p.isNil or n <= 0: return
  c_reed_process(cast[ptr EutReed](g.p), outL, outR, stride.cint, n.cint,
                 bendSemitones, modCents)

# --- ABI --------------------------------------------------------------------

proc abiCheck*(): bool =
  ## Размеры C-состояний сверяются с задокументированными значениями.
  ##
  ## Нужен не для того, чтобы «что-то поймать при сборке» (это делает
  ## компилятор), а чтобы изменение структуры в C не осталось незамеченным:
  ## к примеру, добавление поля меняет размер, и это видно сразу.
  ##
  ## Для инструментов проверяются ещё две вещи, от которых зависит
  ## корректность блоков, выделяемых `newOrgan`/`newPiano`/`newGuitar`/
  ## `newDrums`:
  ##   1) размер СОСТОЯНИЯ кратен 8 — иначе массив голосов, который C ждёт
  ##      сразу за состоянием, встал бы на невыровненный адрес;
  ##   2) размеры голосов совпадают с шагом, которым C обходит массив
  ##      (`sizeof(voice)`), — Nim считает общий размер блока сам.
  c_size_biquad() == 28 and
  c_size_svf() == 28 and
  c_size_osc() == 16 and        # phase, inc, pulseWidth, phaseR
  c_size_noise() == 36 and
  c_size_comp() == 16440 and    # gainCurve обязан покрывать EUT_MAX_BLOCK (4096)
  c_size_delay() == 48 and
  c_size_inst_voice() == 72 and
  c_size_organ_voice() == 140 and
  c_size_organ() == 88 and
  c_size_organ() mod 8 == 0 and
  c_size_piano_voice() == 116 and
  c_size_piano() == 56 and
  c_size_piano() mod 8 == 0 and
  c_size_guitar_voice() == 116 and
  c_size_guitar() == 88 and
  c_size_guitar() mod 8 == 0 and
  c_size_drum_voice() == 328 and
  c_size_drums() == 72 and
  c_size_drums() mod 8 == 0 and
  c_size_flute_voice() == 96 and
  c_size_flute() == 56 and
  c_size_flute() mod 8 == 0 and
  c_size_bagpipe_voice() == 88 and
  c_size_bagpipe() == 64 and
  c_size_bagpipe() mod 8 == 0 and
  c_size_strings_voice() == 92 and
  c_size_strings() == 56 and
  c_size_strings() mod 8 == 0 and
  c_size_bell_voice() == 200 and
  c_size_bell() == 48 and
  c_size_bell() mod 8 == 0 and
  c_size_pluck_voice() == 112 and
  c_size_pluck() == 72 and
  c_size_pluck() mod 8 == 0 and
  c_size_recorder_voice() == 96 and
  c_size_recorder() == 56 and
  c_size_recorder() mod 8 == 0 and
  c_size_brass_voice() == 108 and
  c_size_brass() == 56 and
  c_size_brass() mod 8 == 0 and
  c_size_timpani_voice() == 140 and
  c_size_timpani() == 48 and
  c_size_timpani() mod 8 == 0 and
  c_size_choir_voice() == 140 and
  c_size_choir() == 56 and
  c_size_choir() mod 8 == 0 and
  c_size_reed_voice() == 180 and
  c_size_reed() == 64 and
  c_size_reed() mod 8 == 0

{.pop.}
