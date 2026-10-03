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
  EutInstVoice {.importc: "EutInstVoice", bycopy.} = object
  EutOrganVoice {.importc: "EutOrganVoice", bycopy.} = object
  EutOrgan {.importc: "EutOrgan", bycopy.} = object
  EutPianoVoice {.importc: "EutPianoVoice", bycopy.} = object
  EutPiano {.importc: "EutPiano", bycopy.} = object
  EutGuitarVoice {.importc: "EutGuitarVoice", bycopy.} = object
  EutGuitar {.importc: "EutGuitar", bycopy.} = object
  EutDrumVoice {.importc: "EutDrumVoice", bycopy.} = object
  EutDrums {.importc: "EutDrums", bycopy.} = object

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

proc c_size_inst_voice(): cint {.importc: "eut_abi_sizeof_inst_voice", header: "eut_dsp.h".}
proc c_size_organ_voice(): cint {.importc: "eut_abi_sizeof_organ_voice", header: "eut_dsp.h".}
proc c_size_organ(): cint {.importc: "eut_abi_sizeof_organ", header: "eut_dsp.h".}
proc c_size_piano_voice(): cint {.importc: "eut_abi_sizeof_piano_voice", header: "eut_dsp.h".}
proc c_size_piano(): cint {.importc: "eut_abi_sizeof_piano", header: "eut_dsp.h".}
proc c_size_guitar_voice(): cint {.importc: "eut_abi_sizeof_guitar_voice", header: "eut_dsp.h".}
proc c_size_guitar(): cint {.importc: "eut_abi_sizeof_guitar", header: "eut_dsp.h".}
proc c_size_drum_voice(): cint {.importc: "eut_abi_sizeof_drum_voice", header: "eut_dsp.h".}
proc c_size_drums(): cint {.importc: "eut_abi_sizeof_drums", header: "eut_dsp.h".}

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
  c_size_guitar_voice() == 104 and
  c_size_guitar() == 80 and
  c_size_guitar() mod 8 == 0 and
  c_size_drum_voice() == 184 and
  c_size_drums() == 56 and
  c_size_drums() mod 8 == 0

{.pop.}
