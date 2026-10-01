# mixer_console.nim
#
# Полноценная микшерная модель:
#   Channel strip -> Fader -> Pan -> Sends -> Return buses -> Master
#
# Правила:
#   - редактирование состояния вне realtime;
#   - processMixer() только читает маршрутизацию и пишет метры;
#   - никаких аллокаций, locks, I/O и exceptions в process path;
#   - все буферы заранее выделены pipeline'ом;
#   - один send-слот = один return bus;
#   - ReturnBus.inputChannels / preInputChannels — каноническая матрица посылов.

import std/math
import ../core/signal_types
import ../core/node_interface

const
  MaxMixerChannels* = 64
  MaxReturnBuses* = 8
  MaxSends* = MaxReturnBuses

  MasterBus* = -1
  MasterBusSlot* = MaxReturnBuses
  MixerBufferCount* = MaxReturnBuses + 1

  Pi32 = 3.141592653589793'f32

type
  ChannelType* = enum
    ctTrack
    ctBus
    ctReturn
    ctMaster

  # SendState оставлен как редакторское/человеческое представление send'ов.
  # Реальный DSP routing берётся из матриц ReturnBus:
  #   inputChannels    -> post-fader send gains
  #   preInputChannels -> pre-fader send gains
  SendState* = object
    targetBus*: int32
    level*: float32
    preFader*: bool
    enabled*: bool

  MixerChannel* = object
    id*: int32
    channelType*: ChannelType

    volume*: float32
    pan*: float32        # -1..1
    mute*: bool
    solo*: bool
    armed*: bool

    # Прямой выход канала:
    #   MasterBus       -> в мастер
    #   0..<busCount    -> в return bus
    outputBus*: int32

    sends*: array[MaxSends, SendState]

    # Метры считаются после fader+pan+mute/solo gate.
    meterL*: float32
    meterR*: float32
    peakL*: float32
    peakR*: float32

  ReturnBus* = object
    id*: int32

    # Каноническая матрица посылов:
    #   inputChannels[ch]    = post-fader send level
    #   preInputChannels[ch] = pre-fader send level
    inputChannels*: array[MaxMixerChannels, float32]
    preInputChannels*: array[MaxMixerChannels, float32]

    volume*: float32
    pan*: float32
    mute*: bool
    effectNode*: int32

    meterL*: float32
    meterR*: float32
    peakL*: float32
    peakR*: float32

  MixerConsole* = object
    sampleRate*: float32
    channelCount*: int32
    busCount*: int32
    anySolo*: bool

    channels*: array[MaxMixerChannels, MixerChannel]
    returnBuses*: array[MaxReturnBuses, ReturnBus]
    master*: MixerChannel

{.push raises: [].}

# ==============================================================================
# State editing helpers (вызывать вне realtime)
# ==============================================================================

proc initSendSlots(arr: var array[MaxSends, SendState]) {.inline.} =
  for i in 0 ..< MaxSends:
    arr[i] = SendState(
      targetBus: -1,
      level: 0.0f,
      preFader: false,
      enabled: false
    )

proc initMixerConsole*(sampleRate: float32 = 48000.0f): MixerConsole =
  result.sampleRate = sampleRate
  result.channelCount = 0
  result.busCount = 0
  result.anySolo = false

  result.master.id = 0
  result.master.channelType = ctMaster
  result.master.volume = 1.0f
  result.master.pan = 0.0f
  result.master.mute = false
  result.master.solo = false
  result.master.armed = false
  result.master.outputBus = MasterBus
  initSendSlots(result.master.sends)

proc addChannel*(
    mixer: var MixerConsole,
    name: string = "",
    channelType: ChannelType = ctTrack
): int32 =
  # name намеренно не хранится в realtime-состоянии.
  # Для Editor/CLI держи отдельную таблицу имён.
  discard name

  if mixer.channelCount >= MaxMixerChannels:
    return -1

  let idx = mixer.channelCount

  var ch: MixerChannel
  ch.id = idx + 1
  ch.channelType = channelType
  ch.volume = 1.0f
  ch.pan = 0.0f
  ch.mute = false
  ch.solo = false
  ch.armed = false
  ch.outputBus = MasterBus

  ch.meterL = 0.0f
  ch.meterR = 0.0f
  ch.peakL = 0.0f
  ch.peakR = 0.0f

  initSendSlots(ch.sends)

  mixer.channels[idx] = ch
  inc mixer.channelCount
  return ch.id

proc addReturnBus*(mixer: var MixerConsole, name: string = ""): int32 =
  discard name

  if mixer.busCount >= MaxReturnBuses:
    return -1

  let idx = mixer.busCount

  var b: ReturnBus
  b.id = idx
  b.volume = 1.0f
  b.pan = 0.0f
  b.mute = false
  b.effectNode = -1

  b.meterL = 0.0f
  b.meterR = 0.0f
  b.peakL = 0.0f
  b.peakR = 0.0f

  for i in 0 ..< MaxMixerChannels:
    b.inputChannels[i] = 0.0f
    b.preInputChannels[i] = 0.0f

  mixer.returnBuses[idx] = b
  inc mixer.busCount
  return idx

proc setSend*(
    mixer: var MixerConsole,
    channelId: int32,
    sendIdx: int32,
    targetBus: int32,
    level: float32,
    preFader: bool = false
) =
  if channelId < 1 or channelId > mixer.channelCount:
    return

  # Каноническая модель: один send на один bus.
  # Если targetBus валиден, используем его; иначе пытаемся использовать sendIdx.
  var bus = targetBus
  if bus < 0 or bus >= mixer.busCount:
    bus = sendIdx

  if bus < 0 or bus >= mixer.busCount or bus >= MaxSends:
    return

  let chIdx = channelId - 1
  let lvl = if level < 0.0f: 0.0f else: level

  mixer.channels[chIdx].sends[bus] = SendState(
    targetBus: bus,
    level: lvl,
    preFader: preFader,
    enabled: lvl > 0.0f
  )

  # Одна и та же пара (channel, bus) не может одновременно быть и pre, и post
  # в этой упрощённой матричной модели. Поэтому выбранный tap перезаписывает
  # противоположный.
  if preFader:
    mixer.returnBuses[bus].preInputChannels[chIdx] = lvl
    mixer.returnBuses[bus].inputChannels[chIdx] = 0.0f
  else:
    mixer.returnBuses[bus].inputChannels[chIdx] = lvl
    mixer.returnBuses[bus].preInputChannels[chIdx] = 0.0f

proc setSend*(
    mixer: var MixerConsole,
    channelId: int32,
    busIdx: int32,
    level: float32,
    preFader: bool = false
) {.inline.} =
  setSend(mixer, channelId, busIdx, busIdx, level, preFader)

proc setVolume*(mixer: var MixerConsole, channelId: int32, volume: float32) =
  if channelId == 0:
    mixer.master.volume = volume
  elif channelId >= 1 and channelId <= mixer.channelCount:
    mixer.channels[channelId - 1].volume = volume

proc setPan*(mixer: var MixerConsole, channelId: int32, pan: float32) =
  if channelId == 0:
    mixer.master.pan = pan
  elif channelId >= 1 and channelId <= mixer.channelCount:
    mixer.channels[channelId - 1].pan = pan

proc setMute*(mixer: var MixerConsole, channelId: int32, mute: bool) =
  if channelId == 0:
    mixer.master.mute = mute
  elif channelId >= 1 and channelId <= mixer.channelCount:
    mixer.channels[channelId - 1].mute = mute

proc setSolo*(mixer: var MixerConsole, channelId: int32, solo: bool) =
  if channelId == 0:
    mixer.master.solo = solo
  elif channelId >= 1 and channelId <= mixer.channelCount:
    mixer.channels[channelId - 1].solo = solo

  mixer.anySolo = false
  for i in 0 ..< mixer.channelCount:
    if mixer.channels[i].solo:
      mixer.anySolo = true
      break

proc setOutputBus*(mixer: var MixerConsole, channelId: int32, outputBus: int32) =
  if channelId < 1 or channelId > mixer.channelCount:
    return

  if outputBus == MasterBus or (outputBus >= 0 and outputBus < mixer.busCount):
    mixer.channels[channelId - 1].outputBus = outputBus
  else:
    mixer.channels[channelId - 1].outputBus = MasterBus

proc setReturnVolume*(mixer: var MixerConsole, busIdx: int32, volume: float32) =
  if busIdx >= 0 and busIdx < mixer.busCount:
    mixer.returnBuses[busIdx].volume = volume

proc setReturnPan*(mixer: var MixerConsole, busIdx: int32, pan: float32) =
  if busIdx >= 0 and busIdx < mixer.busCount:
    mixer.returnBuses[busIdx].pan = pan

proc setReturnMute*(mixer: var MixerConsole, busIdx: int32, mute: bool) =
  if busIdx >= 0 and busIdx < mixer.busCount:
    mixer.returnBuses[busIdx].mute = mute

# ==============================================================================
# Realtime buffer helpers
# ==============================================================================
#
# Поддерживаются два layout'а AudioBuffer:
#   1) planar:     stride >= frames, index = ch * stride + frame
#   2) interleaved: stride < frames, index = frame * channels + ch
#
# Для внутренних шин микшера лучше всегда использовать planar stereo:
#   channels = 2
#   frames   = blockSize
#   stride   = frames

proc clampFrames(n: int32): int32 {.inline.} =
  if n <= 0: 0
  elif n > MaxBlockSize: MaxBlockSize
  else: n

proc sampleIndex(buf: PAudioBuffer, ch: int32, frame: int32): int32 {.inline.} =
  if buf.channels <= 1:
    return frame

  let stride = if buf.stride > 0: buf.stride else: buf.frames
  if stride >= buf.frames:
    result = ch * stride + frame
  else:
    result = frame * buf.channels + ch

proc readStereo(
    buf: PAudioBuffer,
    frame: int32,
    l: var float32,
    r: var float32
) {.inline.} =
  if buf == nil or buf.data == nil or buf.channels <= 0 or
     frame < 0 or frame >= buf.frames:
    l = 0.0f
    r = 0.0f
    return

  if buf.channels == 1:
    let s = buf.data[sampleIndex(buf, 0, frame)]
    l = s
    r = s
  else:
    l = buf.data[sampleIndex(buf, 0, frame)]
    r = buf.data[sampleIndex(buf, 1, frame)]

proc writeStereo(
    buf: PAudioBuffer,
    frame: int32,
    l: float32,
    r: float32
) {.inline.} =
  if buf == nil or buf.data == nil or buf.channels <= 0 or
     frame < 0 or frame >= buf.frames:
    return

  if buf.channels == 1:
    buf.data[sampleIndex(buf, 0, frame)] = (l + r) * 0.5f
  else:
    buf.data[sampleIndex(buf, 0, frame)] = l
    buf.data[sampleIndex(buf, 1, frame)] = r

proc addStereo(
    buf: PAudioBuffer,
    frame: int32,
    l: float32,
    r: float32
) {.inline.} =
  if buf == nil or buf.data == nil or buf.channels <= 0 or
     frame < 0 or frame >= buf.frames:
    return

  if buf.channels == 1:
    buf.data[sampleIndex(buf, 0, frame)] += (l + r) * 0.5f
  else:
    buf.data[sampleIndex(buf, 0, frame)] += l
    buf.data[sampleIndex(buf, 1, frame)] += r

proc clearStereo(buf: PAudioBuffer, frames: int32) =
  if buf == nil or buf.data == nil or buf.channels <= 0 or frames <= 0:
    return

  let n = if frames > buf.frames: buf.frames else: frames
  if n <= 0:
    return

  if buf.channels == 1:
    for i in 0 ..< n:
      buf.data[sampleIndex(buf, 0, i)] = 0.0f
  else:
    for i in 0 ..< n:
      buf.data[sampleIndex(buf, 0, i)] = 0.0f
      buf.data[sampleIndex(buf, 1, i)] = 0.0f

# ==============================================================================
# Pan law
# ==============================================================================

proc clampPan(p: float32): float32 {.inline.} =
  if p < -1.0f: -1.0f
  elif p > 1.0f: 1.0f
  else: p

proc monoPanGains(pan: float32): tuple[l: float32, r: float32] {.inline.} =
  let p = clampPan(pan)
  let angle = (p + 1.0f) * Pi32 / 4.0f
  result.l = float32(cos(angle))
  result.r = float32(sin(angle))

proc stereoPanGains(pan: float32): tuple[l: float32, r: float32] {.inline.} =
  # Для стереоисточника используется balance-подход:
  #   центр = unity;
  #   панорама ослабляет противоположную сторону.
  let p = clampPan(pan)

  if p <= 0.0f:
    result.l = 1.0f
    result.r = float32(sin((p + 1.0f) * Pi32 / 2.0f))
  else:
    result.l = float32(sin((1.0f - p) * Pi32 / 2.0f))
    result.r = 1.0f

# ==============================================================================
# Channel strip processing
# ==============================================================================

proc processChannel*(
    mixer: var MixerConsole,
    channelId: int32,
    input: PAudioBuffer,
    output: PAudioBuffer,
    frames: int32
) =
  ## Локальная обработка канала без посылов и без маршрутизации в шины.
  ## Полезно для тестов и отдельных channel-strip узлов.
  ##
  ## Сигнал:
  ##   input -> mute/solo gate -> fader -> pan -> output
  ##
  ## Метры считаются по выходному сигналу.

  if channelId < 1 or channelId > mixer.channelCount:
    return

  if input == nil or output == nil:
    return

  let n = clampFrames(frames)
  if n <= 0:
    return

  let ch = addr mixer.channels[channelId - 1]
  let audible = if mixer.anySolo: ch.solo else: not ch.mute

  if not audible:
    clearStereo(output, n)
    ch.meterL = 0.0f
    ch.meterR = 0.0f
    ch.peakL = 0.0f
    ch.peakR = 0.0f
    return

  let monoIn = input.channels <= 1

  let gains =
    if monoIn: monoPanGains(ch.pan)
    else: stereoPanGains(ch.pan)

  let gainL = gains.l * ch.volume
  let gainR = gains.r * ch.volume

  var sumL = 0.0f
  var sumR = 0.0f
  var peakL = 0.0f
  var peakR = 0.0f

  for i in 0 ..< n:
    var inL, inR: float32
    readStereo(input, i, inL, inR)

    var outL, outR: float32
    if monoIn:
      outL = inL * gainL
      outR = inL * gainR
    else:
      outL = inL * gainL
      outR = inR * gainR

    writeStereo(output, i, outL, outR)

    let aL = abs(outL)
    let aR = abs(outR)

    if aL > peakL: peakL = aL
    if aR > peakR: peakR = aR

    sumL += outL * outL
    sumR += outR * outR

  ch.peakL = peakL
  ch.peakR = peakR
  ch.meterL = sqrt(sumL / float32(n))
  ch.meterR = sqrt(sumR / float32(n))

proc processChannelStrip(
    mixer: var MixerConsole,
    chIdx: int32,
    input: PAudioBuffer,
    busBuffers: ptr UncheckedArray[PAudioBuffer],
    frames: int32
) =
  # Внутренняя полная обработка канала:
  #
  #   input
  #     |
  #     +--> pre-fader sends
  #     |
  #   fader + pan
  #     |
  #     +--> direct output bus
  #     +--> post-fader sends
  #
  # Метр считается после fader+pan.

  if input == nil or busBuffers == nil or frames <= 0:
    return

  let ch = addr mixer.channels[chIdx]

  let audible = if mixer.anySolo: ch.solo else: not ch.mute
  if not audible:
    # Сами шины уже очищены в начале блока.
    # Здесь достаточно сбросить метры канала.
    ch.meterL = 0.0f
    ch.meterR = 0.0f
    ch.peakL = 0.0f
    ch.peakR = 0.0f
    return

  # ------------------------------------------------------------------
  # Pre-fader sends
  # ------------------------------------------------------------------
  for busIdx in 0 ..< mixer.busCount:
    let gain = mixer.returnBuses[busIdx].preInputChannels[chIdx]
    if gain == 0.0f:
      continue

    let dst = busBuffers[busIdx]
    if dst == nil:
      continue

    for i in 0 ..< frames:
      var l, r: float32
      readStereo(input, i, l, r)
      addStereo(dst, i, l * gain, r * gain)

  # ------------------------------------------------------------------
  # Fader + pan
  # ------------------------------------------------------------------
  let monoIn = input.channels <= 1

  let gains =
    if monoIn: monoPanGains(ch.pan)
    else: stereoPanGains(ch.pan)

  let gainL = gains.l * ch.volume
  let gainR = gains.r * ch.volume

  # ------------------------------------------------------------------
  # Post-fader sends: собираем активные маршруты один раз на блок
  # ------------------------------------------------------------------
  var postCount = 0
  var postBus: array[MaxSends, int32]
  var postGain: array[MaxSends, float32]

  for busIdx in 0 ..< mixer.busCount:
    let gain = mixer.returnBuses[busIdx].inputChannels[chIdx]
    if gain == 0.0f:
      continue

    if busBuffers[busIdx] == nil:
      continue

    if postCount < MaxSends:
      postBus[postCount] = busIdx
      postGain[postCount] = gain
      inc postCount

  # ------------------------------------------------------------------
  # Direct output routing
  # ------------------------------------------------------------------
  let outSlot: int32 =
    if ch.outputBus == MasterBus: int32(MasterBusSlot)
    elif ch.outputBus >= 0 and ch.outputBus < mixer.busCount: ch.outputBus
    else: -1

  let directBuf =
    if outSlot >= 0 and outSlot < MixerBufferCount: busBuffers[outSlot]
    else: nil

  # ------------------------------------------------------------------
  # Main sample loop
  # ------------------------------------------------------------------
  var sumL = 0.0f
  var sumR = 0.0f
  var peakL = 0.0f
  var peakR = 0.0f

  for i in 0 ..< frames:
    var inL, inR: float32
    readStereo(input, i, inL, inR)

    var outL, outR: float32
    if monoIn:
      outL = inL * gainL
      outR = inL * gainR
    else:
      outL = inL * gainL
      outR = inR * gainR

    # Метр канала считается именно по этому сигналу.
    let aL = abs(outL)
    let aR = abs(outR)

    if aL > peakL: peakL = aL
    if aR > peakR: peakR = aR

    sumL += outL * outL
    sumR += outR * outR

    if directBuf != nil:
      addStereo(directBuf, i, outL, outR)

    for j in 0 ..< postCount:
      let dst = busBuffers[postBus[j]]
      let g = postGain[j]
      addStereo(dst, i, outL * g, outR * g)

  ch.peakL = peakL
  ch.peakR = peakR
  ch.meterL = sqrt(sumL / float32(frames))
  ch.meterR = sqrt(sumR / float32(frames))

# ==============================================================================
# Bus / master processing
# ==============================================================================

proc processReturnBus(
    mixer: var MixerConsole,
    busIdx: int32,
    busBuf: PAudioBuffer,
    masterBuf: PAudioBuffer,
    frames: int32
) =
  if busIdx < 0 or busIdx >= mixer.busCount:
    return

  if busBuf == nil or frames <= 0:
    return

  let bus = addr mixer.returnBuses[busIdx]

  if bus.mute:
    clearStereo(busBuf, frames)
    bus.meterL = 0.0f
    bus.meterR = 0.0f
    bus.peakL = 0.0f
    bus.peakR = 0.0f
    return

  let monoIn = busBuf.channels <= 1

  let gains =
    if monoIn: monoPanGains(bus.pan)
    else: stereoPanGains(bus.pan)

  let gainL = bus.volume * gains.l
  let gainR = bus.volume * gains.r

  var sumL = 0.0f
  var sumR = 0.0f
  var peakL = 0.0f
  var peakR = 0.0f

  for i in 0 ..< frames:
    var l, r: float32
    readStereo(busBuf, i, l, r)

    let outL = l * gainL
    let outR = r * gainR

    # Шина сразу заменяет своё содержимое на обработанный сигнал.
    writeStereo(busBuf, i, outL, outR)

    if masterBuf != nil:
      addStereo(masterBuf, i, outL, outR)

    let aL = abs(outL)
    let aR = abs(outR)

    if aL > peakL: peakL = aL
    if aR > peakR: peakR = aR

    sumL += outL * outL
    sumR += outR * outR

  bus.peakL = peakL
  bus.peakR = peakR
  bus.meterL = sqrt(sumL / float32(frames))
  bus.meterR = sqrt(sumR / float32(frames))

proc processMasterStrip(
    mixer: var MixerConsole,
    masterSum: PAudioBuffer,
    masterOut: PAudioBuffer,
    frames: int32
) =
  if masterSum == nil or masterOut == nil or frames <= 0:
    return

  let m = addr mixer.master

  if m.mute:
    clearStereo(masterOut, frames)
    m.meterL = 0.0f
    m.meterR = 0.0f
    m.peakL = 0.0f
    m.peakR = 0.0f
    return

  let monoIn = masterSum.channels <= 1

  let gains =
    if monoIn: monoPanGains(m.pan)
    else: stereoPanGains(m.pan)

  let gainL = m.volume * gains.l
  let gainR = m.volume * gains.r

  var sumL = 0.0f
  var sumR = 0.0f
  var peakL = 0.0f
  var peakR = 0.0f

  for i in 0 ..< frames:
    var l, r: float32
    readStereo(masterSum, i, l, r)

    let outL = l * gainL
    let outR = r * gainR

    writeStereo(masterOut, i, outL, outR)

    let aL = abs(outL)
    let aR = abs(outR)

    if aL > peakL: peakL = aL
    if aR > peakR: peakR = aR

    sumL += outL * outL
    sumR += outR * outR

  m.peakL = peakL
  m.peakR = peakR
  m.meterL = sqrt(sumL / float32(frames))
  m.meterR = sqrt(sumR / float32(frames))

# ==============================================================================
# Full mixer process
# ==============================================================================

proc clearMixerBuses*(
    mixer: MixerConsole,
    busBuffers: ptr UncheckedArray[PAudioBuffer],
    frames: int32
) =
  if busBuffers == nil:
    return

  for i in 0 ..< mixer.busCount:
    clearStereo(busBuffers[i], frames)

  clearStereo(busBuffers[MasterBusSlot], frames)

proc processMixer*(
    mixer: var MixerConsole,
    ctx: ptr NodeProcessContext,
    trackInputs: ptr UncheckedArray[PAudioBuffer],
    busBuffers: ptr UncheckedArray[PAudioBuffer],
    masterOut: PAudioBuffer
) =
  ## Полный процесс микшера за один блок.
  ##
  ## Контракт по буферам:
  ##   trackInputs[0..channelCount-1]
  ##   busBuffers[0..busCount-1]  -- return buses
  ##   busBuffers[MasterBusSlot]  -- master sum bus
  ##   masterOut                  -- финальный стерео-выход
  ##
  ## Все буферы должны быть заранее выделены вне realtime.

  if busBuffers == nil or masterOut == nil:
    return

  let frames =
    if ctx == nil: 0
    else: clampFrames(ctx.blockSize)

  if frames <= 0:
    return

  clearMixerBuses(mixer, busBuffers, frames)

  let masterSum = busBuffers[MasterBusSlot]
  if masterSum == nil:
    clearStereo(masterOut, frames)
    return

  # ------------------------------------------------------------------
  # Channels
  # ------------------------------------------------------------------
  if trackInputs != nil:
    for chIdx in 0 ..< mixer.channelCount:
      let input = trackInputs[chIdx]
      if input != nil:
        processChannelStrip(mixer, chIdx, input, busBuffers, frames)

  # ------------------------------------------------------------------
  # Return buses -> master
  # ------------------------------------------------------------------
  for b in 0 ..< mixer.busCount:
    processReturnBus(mixer, b, busBuffers[b], masterSum, frames)

  # ------------------------------------------------------------------
  # Master
  # ------------------------------------------------------------------
  processMasterStrip(mixer, masterSum, masterOut, frames)

# ==============================================================================
# Node adapter example
# ==============================================================================

type
  MixerMainNodeState* = object
    mixer*: ptr MixerConsole
    trackInputs*: ptr UncheckedArray[PAudioBuffer]
    busBuffers*: ptr UncheckedArray[PAudioBuffer]

proc processMixerMainNode*(
    ctx: ptr NodeProcessContext,
    audio: ptr NodeAudioPorts,
    ctrl: ptr NodeControlPorts,
    events: ptr NodeEventPorts,
    userData: pointer
) {.cdecl, raises: [].} =
  let state = cast[ptr MixerMainNodeState](userData)

  if state == nil or state.mixer == nil or state.busBuffers == nil:
    return

  if audio == nil or audio.outputCount <= 0:
    return

  let outBuf = audio.outputs[0]
  if outBuf == nil:
    return

  processMixer(
    state.mixer[],
    ctx,
    state.trackInputs,
    state.busBuffers,
    outBuf
  )

{.pop.}