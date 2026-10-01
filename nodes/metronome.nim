# metronome.nim

import std/math

# ИСПРАВЛЕНИЕ 1: Явные относительные импорты. 
# Если структура проекта src/core/... и src/nodes/..., используйте ../core/...
# Если настроен nim.cfg (см. ниже), можно оставить просто имена модулей.
import ../core/signal_types
import ../core/node_interface
import ../core/transport

{.push raises: [].}

const
  MetronomeVoiceCount = 4

  # exp(-MetroLog1000 / length) даёт примерно -60 dB к концу хвоста
  MetroLog1000 = 6.907755278982137'f64

  # Небольшие эпсилоны для устойчивого попадания в целые сэмплы
  ClickFloorEpsilon = 1e-6'f64
  ClickTriggerEpsilon = 1e-6'f64

  TwoPi32 = 6.283185307179586'f32

type
  MetronomeSound* = enum
    msClick
    msBeep
    msWoodblock
    msCowbell

  ClickParams = object
    normalFreq0: float32
    accentFreq0: float32
    normalFreq1: float32
    accentFreq1: float32
    envCoeff: float32
    length: int32
    gain: float32

  ClickVoice = object
    active: bool
    sound: MetronomeSound
    accent: bool
    age: int32
    length: int32
    env: float32
    envCoeff: float32
    phase0: float32
    phase1: float32
    freq0: float32
    freq1: float32
    gain: float32

  MetronomeState* = object
    enabled*: bool
    soundType*: MetronomeSound
    accentLevel*: float32
    normalLevel*: float32

    cachedSampleRate: float32
    invSampleRate: float32

    params: array[MetronomeSound, ClickParams]
    voices: array[MetronomeVoiceCount, ClickVoice]

    # Детерминированный PRNG для woodblock/noise
    rngState: uint32


# ==============================================================================
# Basic helpers
# ==============================================================================

proc sin32(x: float32): float32 {.inline.} =
  float32(sin(float64(x)))


proc clickFrameFromOffset(offset: float64): int64 {.inline.} =
  int64(floor(offset + ClickFloorEpsilon))


proc makeParams(
    sampleRate: float32;
    duration: float32;
    nFreq0, aFreq0, nFreq1, aFreq1, gain: float32
): ClickParams =
  result.normalFreq0 = nFreq0
  result.accentFreq0 = aFreq0
  result.normalFreq1 = nFreq1
  result.accentFreq1 = aFreq1
  result.gain = gain

  let frames = int32(float64(sampleRate) * float64(duration))
  result.length = if frames < 1'i32: 1'i32 else: frames
  result.envCoeff = float32(exp(-MetroLog1000 / float64(result.length)))


proc updateParams(metro: var MetronomeState; sampleRate: float32) =
  if not (sampleRate > 0.0f):
    return

  if metro.rngState == 0'u32:
    metro.rngState = 0x9E3779B9'u32

  metro.cachedSampleRate = sampleRate
  metro.invSampleRate = 1.0f / sampleRate

  metro.params[msClick] =
    makeParams(sampleRate, 0.030'f32, 1000.0f, 1500.0f, 0.0f, 0.0f, 1.0f)

  metro.params[msBeep] =
    makeParams(sampleRate, 0.090'f32, 440.0f, 880.0f, 0.0f, 0.0f, 0.85f)

  metro.params[msWoodblock] =
    makeParams(sampleRate, 0.070'f32, 1900.0f, 2300.0f, 0.0f, 0.0f, 0.9f)

  metro.params[msCowbell] =
    makeParams(sampleRate, 0.160'f32, 540.0f, 540.0f, 800.0f, 800.0f, 0.65f)


proc initMetronome*(sampleRate: float32 = 48000.0f): MetronomeState =
  result.enabled = false
  result.soundType = msClick
  result.accentLevel = 0.8f
  result.normalLevel = 0.5f
  result.rngState = 0x9E3779B9'u32

  if sampleRate > 0.0f:
    result.updateParams(sampleRate)


proc setSampleRate*(metro: var MetronomeState; sampleRate: float32) =
  if sampleRate > 0.0f and sampleRate != metro.cachedSampleRate:
    metro.updateParams(sampleRate)


proc prepare*(metro: var MetronomeState; sampleRate: float32) {.inline.} =
  metro.setSampleRate(sampleRate)


proc setSound*(metro: var MetronomeState; sound: MetronomeSound) {.inline.} =
  metro.soundType = sound


proc setLevels*(metro: var MetronomeState; accent, normal: float32) {.inline.} =
  metro.accentLevel = accent
  metro.normalLevel = normal


proc silenceVoices*(metro: var MetronomeState) =
  for i in 0 ..< MetronomeVoiceCount:
    metro.voices[i].active = false


# ==============================================================================
# Deterministic noise
# ==============================================================================

proc nextNoise(metro: var MetronomeState): float32 {.inline.} =
  var x = metro.rngState
  if x == 0'u32:
    x = 0x9E3779B9'u32

  x = x xor (x shl 13)
  x = x xor (x shr 17)
  x = x xor (x shl 5)

  metro.rngState = x

  let mask = 0x00FFFFFF'u32
  result = (float32(x and mask) / float32(mask)) * 2.0f - 1.0f


# ==============================================================================
# Voice trigger/render
# ==============================================================================

proc triggerVoice(metro: var MetronomeState; sound: MetronomeSound; accent: bool) =
  # ИСПРАВЛЕНИЕ 2: Индексы массивов в Nim требуют тип `int`
  var idx = -1
  var oldest = 0
  var oldestAge: int32 = -1'i32

  for i in 0 ..< MetronomeVoiceCount:
    if not metro.voices[i].active:
      idx = i
      break

    if metro.voices[i].age > oldestAge:
      oldestAge = metro.voices[i].age
      oldest = i

  if idx < 0:
    idx = oldest

  let p = metro.params[sound]

  var level = if accent: metro.accentLevel else: metro.normalLevel
  if level < 0.0f: level = 0.0f
  elif level > 1.0f: level = 1.0f

  var v = addr metro.voices[idx]

  v.active = true
  v.sound = sound
  v.accent = accent
  v.age = 0'i32
  v.length = p.length
  v.env = 1.0f
  v.envCoeff = p.envCoeff
  v.phase0 = 0.0f
  v.phase1 = 0.0f
  v.freq0 = if accent: p.accentFreq0 else: p.normalFreq0
  v.freq1 = if accent: p.accentFreq1 else: p.normalFreq1
  v.gain = level * p.gain


proc renderVoice(metro: var MetronomeState; v: var ClickVoice): float32 =
  if not v.active:
    return 0.0f

  if v.age >= v.length:
    v.active = false
    return 0.0f

  let env = v.env

  v.env *= v.envCoeff
  inc v.age

  var s = 0.0f

  case v.sound
  of msClick, msBeep:
    v.phase0 += v.freq0 * metro.invSampleRate
    if v.phase0 >= 1.0f:
      v.phase0 -= 1.0f
    s = sin32(TwoPi32 * v.phase0) * env

  of msWoodblock:
    v.phase0 += v.freq0 * metro.invSampleRate
    if v.phase0 >= 1.0f:
      v.phase0 -= 1.0f
    let noise = metro.nextNoise()
    let tone = sin32(TwoPi32 * v.phase0)
    s = (noise * 0.62f + tone * 0.38f) * env

  of msCowbell:
    v.phase0 += v.freq0 * metro.invSampleRate
    if v.phase0 >= 1.0f:
      v.phase0 -= 1.0f
    v.phase1 += v.freq1 * metro.invSampleRate
    if v.phase1 >= 1.0f:
      v.phase1 -= 1.0f
    let a = sin32(TwoPi32 * v.phase0)
    let b = sin32(TwoPi32 * v.phase1)
    let mixed = a + b
    s = (mixed / (1.0f + abs(mixed))) * env

  result = s * v.gain


# ==============================================================================
# Event output
# ==============================================================================

proc pushTrigger(
    q: ptr EventQueue;
    frame: uint32;
    subFrame: float32;
    accent: bool;
    beatIndex: int64;
    beatInBar: int32
) {.inline.} =
  if q == nil:
    return

  var ev: RealtimeEvent

  ev.frameOffset = frame
  ev.subFrame = subFrame
  ev.kind = evTrigger
  ev.port = 0
  ev.channel = 0

  # ИСПРАВЛЕНИЕ 3: Строгая типизация Nim (int32 + int требует явного 'i32)
  ev.data[0] = if accent: 1.0f else: 0.0f
  ev.data[1] = float32(beatInBar + 1'i32)
  ev.data[2] = float32(beatIndex mod 1_000_000'i64)
  ev.data[3] = 0.0f

  discard q.pushEvent(ev)


# ==============================================================================
# AudioBuffer output helpers
# ==============================================================================

proc frameStride(buf: PAudioBuffer): int32 {.inline.} =
  if buf.stride > 0: buf.stride
  elif buf.channels > 0: buf.channels
  else: 1


proc writeFrame(buf: PAudioBuffer; frame: int32; sample: float32) {.inline.} =
  if buf == nil or buf.data == nil:
    return

  if frame < 0 or frame >= buf.frames:
    return

  let ch = if buf.channels > 0: buf.channels else: 1
  let stride = frameStride(buf)

  let base =
    if stride >= ch:
      int(frame) * int(stride)
    else:
      int(frame) * int(ch)

  for c in 0 ..< ch:
    buf.data[base + int(c)] = sample


proc clearBuffer(buf: PAudioBuffer; frames: int32) =
  if buf == nil or buf.data == nil:
    return

  for i in 0 ..< frames:
    writeFrame(buf, i, 0.0f)


# ==============================================================================
# Main DSP process
# ==============================================================================

proc processMetronome*(
    metro: var MetronomeState;
    ctx: ptr NodeProcessContext;
    outBuf: PAudioBuffer;
    outEvents: ptr EventQueue
) =
  if ctx == nil:
    return

  let frames =
    if outBuf != nil and outBuf.frames > 0:
      min(ctx.blockSize, outBuf.frames)
    else:
      ctx.blockSize

  if frames <= 0:
    return

  if not (ctx.sampleRate > 0.0f):
    metro.silenceVoices()
    clearBuffer(outBuf, frames)
    return

  if metro.cachedSampleRate != ctx.sampleRate:
    metro.updateParams(ctx.sampleRate)
    metro.silenceVoices()

  if not metro.enabled:
    metro.silenceVoices()
    clearBuffer(outBuf, frames)
    return

  let active =
    (pfTransportPlaying in ctx.flags) or
    (pfTransportPlaying in ctx.transport.flags) or
    (pfOffline in ctx.flags) or
    (pfOffline in ctx.transport.flags)

  if not active:
    metro.silenceVoices()
    clearBuffer(outBuf, frames)
    return

  let tempo = ctx.transport.tempo
  let num = ctx.transport.timeSigNum
  let den = ctx.transport.timeSigDen

  if not (tempo > 0.0) or num <= 0 or den <= 0:
    metro.silenceVoices()
    clearBuffer(outBuf, frames)
    return

  let samplesPerQuarter = (float64(ctx.sampleRate) * 60.0) / tempo
  let samplesPerClick = samplesPerQuarter * (4.0 / float64(den))

  if not (samplesPerClick >= 1.0):
    metro.silenceVoices()
    clearBuffer(outBuf, frames)
    return

  let start = ctx.samplePosition

  let barPos = ctx.transport.barPosition
  let validBarPos = barPos >= 0.0
  let useTransportBars = validBarPos and ((barPos > 0.0) or (start == 0))

  let startClickPos =
    if useTransportBars:
      barPos * float64(num)
    else:
      float64(start) / samplesPerClick

  var beatIndex = int64(ceil(startClickPos - ClickTriggerEpsilon))
  if beatIndex < 0:
    beatIndex = 0

  var clickOffset = (float64(beatIndex) - startClickPos) * samplesPerClick
  if clickOffset < 0.0:
    clickOffset = 0.0

  var nextClickSample = start + clickFrameFromOffset(clickOffset)

  for i in 0 ..< frames:
    let global = start + int64(i)

    while nextClickSample < global:
      inc beatIndex
      clickOffset = (float64(beatIndex) - startClickPos) * samplesPerClick
      nextClickSample = start + clickFrameFromOffset(clickOffset)

    while nextClickSample == global:
      let floorOffset = float64(nextClickSample - start)

      var sub = float32(clickOffset - floorOffset)
      if sub < 0.0f: sub = 0.0f
      elif sub >= 1.0f: sub = 0.0f

      let beatInBar = int32(beatIndex mod int64(num))
      let accent = beatInBar == 0

      metro.triggerVoice(metro.soundType, accent)
      pushTrigger(outEvents, uint32(i), sub, accent, beatIndex, beatInBar)

      inc beatIndex
      clickOffset = (float64(beatIndex) - startClickPos) * samplesPerClick
      nextClickSample = start + clickFrameFromOffset(clickOffset)

    var sample = 0.0f

    for vi in 0 ..< MetronomeVoiceCount:
      sample += metro.renderVoice(metro.voices[vi])

    if sample > 1.0f: sample = 1.0f
    elif sample < -1.0f: sample = -1.0f

    writeFrame(outBuf, i, sample)


# ==============================================================================
# NodeProcessProc adapter
# ==============================================================================

proc processMetronomeNode*(
    ctx: ptr NodeProcessContext;
    audio: ptr NodeAudioPorts;
    ctrl: ptr NodeControlPorts;
    events: ptr NodeEventPorts;
    userData: pointer
) {.cdecl, raises: [].} =
  if ctx == nil or audio == nil or userData == nil:
    return

  let metro = cast[ptr MetronomeState](userData)

  var outBuf: PAudioBuffer = nil
  if audio.outputCount > 0:
    outBuf = audio.outputs[0]

  var outEvents: ptr EventQueue = nil
  if events != nil and events.outputCount > 0:
    outEvents = events.outputs[0]

  processMetronome(metro[], ctx, outBuf, outEvents)


# ==============================================================================
# Offline/test helper
# ==============================================================================

proc renderMetronomeBlock*(
    metro: var MetronomeState;
    output: ptr UncheckedArray[float32];
    blockSize: int32;
    currentSample: int64;
    sampleRate: float32;
    tempo: float32;
    timeSigNum: int32 = 4;
    timeSigDen: int32 = 4;
    playing: bool = true
) =
  if output == nil or blockSize <= 0:
    return

  var ctx: NodeProcessContext

  ctx.sampleRate = sampleRate
  ctx.blockSize = blockSize
  ctx.samplePosition = currentSample
  ctx.timeInSeconds =
    if sampleRate > 0.0f:
      float64(currentSample) / float64(sampleRate)
    else:
      0.0

  if playing:
    ctx.flags = {pfTransportPlaying}

  ctx.transport.tempo = float64(tempo)
  ctx.transport.timeSigNum = timeSigNum
  ctx.transport.timeSigDen = timeSigDen
  ctx.transport.flags = ctx.flags

  var buf: AudioBuffer
  buf.data = output
  buf.channels = 2
  buf.frames = blockSize
  buf.stride = 2

  processMetronome(metro, addr ctx, addr buf, nil)

{.pop.}