# core/live_resampler.nim
#
# Мост «частота устройства ≠ частота проекта» (issue #8).
#
# Зачем отдельный модуль: расхождение частот — это не свойство движка,
# а свойство СЕАНСА. Движок обязан считать в частоте проекта (иначе темп,
# автоматизация и PDC «поедут»), драйвер — в частоте устройства. Между ними
# два потоковых ресемплера и две очереди предвыделенного размера.
#
# Схема callback'а:
#
#   driver in ──▶ [SRC dev→proj] ──▶ projQueue ──▶ engine (частota проекта)
#                                                     │
#   driver out ◀── [SRC proj→dev] ◀── devQueue ◀───────┘
#
# Почему очереди, а не «один вход — один выход»: ресемплер на границе блока
# отдаёт на 1–15 кадров меньше/больше отношения из-за дробной фазы. Очередь
# поглощает эту разницу, поэтому транспорт идёт с ТОЧНОЙ скоростью проекта,
# а не «примерно». Задержка моста (полокна на каждой стороне) входит в
# `latencyFrames` и компенсируется PDC.
#
# Realtime-дисциплина (§9): вся память выделяется в `initLiveSrcBridge`;
# `bridgeProcess` не аллоцирует, не блокируется и не бросает исключений.
# Переполнение очереди считается (`droppedFrames`), а не теряется молча.

import std/math

import signal_types
import src_api
import audio_engine

{.push raises: [].}

const
  LiveBridgeMaxChannels* = signal_types.MaxAudioChannels
  LiveBridgeQueueBlocks = 2
    ## Ёмкость каждой очереди в блоках проекта/устройства. Двух хватает:
    ## расхождение за блок не превышает одного кадра.

type
  LiveSrcBridge* = object
    ## Состояние моста. POD; живёт в `LiveSession` (стабильный адрес).
    active*: bool
    api: ptr SrcApi
      ## Владелец — вызывающий (CLI/тест): Core не знает, какой адаптер
      ## ресемплинга выбран (§8, §27).
    toProject: SrcHandle
    toDevice: SrcHandle
    base: ptr UncheckedArray[float32]
      ## Одна арена под все промежуточные буферы.
    devIn: ptr UncheckedArray[float32]
    projIn: ptr UncheckedArray[float32]
    projInIL: ptr UncheckedArray[float32]
    projOutIL: ptr UncheckedArray[float32]
    projOut: ptr UncheckedArray[float32]
    devOut: ptr UncheckedArray[float32]
    projQueue: ptr UncheckedArray[float32]
    devQueue: ptr UncheckedArray[float32]
    devFrames*: int32
    projFrames*: int32
      ## Сколько кадров проекта мост отдаёт движку за один callback (верхняя
      ## граница: фактически может быть меньше на прайминге).
    projCap: int32
    devCap: int32
    projHead: int32
    projCount: int32
    devHead: int32
    devCount: int32
    deviceRate*: float64
    projectRate*: float64
    latencyFrames*: int32
      ## Суммарная задержка моста в кадрах УСТРОЙСТВА (для отчёта).
    droppedFrames*: uint32

proc projectBlockFor*(deviceFrames: int32; deviceRate, projectRate: float64): int32 =
  ## Рекомендуемый размер блока ДВИЖКА при мосте: столько кадров проекта
  ## приходится на один callback устройства (+2 на дробную фазу).
  if deviceFrames <= 0 or deviceRate <= 0.0 or projectRate <= 0.0:
    return 0
  int32(ceil(float64(deviceFrames) * projectRate / deviceRate)) + 2

proc bridgeRateOk*(deviceRate, projectRate: float64): bool =
  ## Допустимое отношение частот. Вне диапазона — ошибка вызывающего,
  ## а не музыкальный сценарий (см. `src_api`).
  if not (deviceRate > 0.0 and projectRate > 0.0):
    return false
  let ratio = deviceRate / projectRate
  ratio >= 1.0 / 16.0 and ratio <= 16.0


# ==============================================================================
# Владение и инициализация (control-path)
# ==============================================================================

proc closeLiveSrcBridge*(bridge: var LiveSrcBridge)

proc initLiveSrcBridge*(
  bridge: var LiveSrcBridge;
  api: ptr SrcApi;
  deviceFrames: int32;
  deviceRate, projectRate: float64
): bool =
  ## Создать мост. Вызывается ДО открытия устройства: арена и ресемплеры
  ## выделяются здесь, в callback аллокаций нет.
  if api.isNil or deviceFrames <= 0:
    return false
  if not bridgeRateOk(deviceRate, projectRate):
    return false
  let projFrames = projectBlockFor(deviceFrames, deviceRate, projectRate)
  if projFrames <= 0 or projFrames > int32(signal_types.MaxBlockSize):
    return false

  bridge.devFrames = deviceFrames
  bridge.projFrames = projFrames
  bridge.deviceRate = deviceRate
  bridge.projectRate = projectRate
  bridge.projCap = projFrames * LiveBridgeQueueBlocks
  bridge.devCap = deviceFrames * LiveBridgeQueueBlocks

  # Раскладка арены (в float32):
  #   devIn, projIn, projInIL, projOutIL, projOut : 2 * frames
  #   devOut                                      : 2 * devFrames
  #   projQueue, devQueue                         : 2 * cap
  let perProj = int(LiveBridgeMaxChannels) * int(projFrames)
  let perDev = int(LiveBridgeMaxChannels) * int(deviceFrames)
  let perProjQueue = int(LiveBridgeMaxChannels) * int(bridge.projCap)
  let perDevQueue = int(LiveBridgeMaxChannels) * int(bridge.devCap)
  let total = 5 * perProj + perDev + perProjQueue + perDevQueue
  let raw = allocShared0(sizeof(float32) * total)
  if raw.isNil:
    return false
  bridge.base = cast[ptr UncheckedArray[float32]](raw)

  var off = 0
  template carve(n: int): ptr UncheckedArray[float32] =
    let p = cast[ptr UncheckedArray[float32]](addr bridge.base[off])
    off += n
    p
  bridge.devIn = carve(perDev)
  bridge.projIn = carve(perProj)
  bridge.projInIL = carve(perProj)
  bridge.projOutIL = carve(perProj)
  bridge.projOut = carve(perProj)
  bridge.devOut = carve(perDev)
  bridge.projQueue = carve(perProjQueue)
  bridge.devQueue = carve(perDevQueue)

  bridge.api = api
  bridge.toProject = srcCreateConverter(
    api, deviceRate, projectRate, int32(LiveBridgeMaxChannels), deviceFrames)
  bridge.toDevice = srcCreateConverter(
    api, projectRate, deviceRate, int32(LiveBridgeMaxChannels), projFrames)
  if bridge.toProject.isNil or bridge.toDevice.isNil:
    closeLiveSrcBridge(bridge)
    return false

  bridge.projHead = 0
  bridge.projCount = 0
  bridge.devHead = 0
  bridge.devCount = 0
  bridge.droppedFrames = 0
  bridge.latencyFrames = srcLatencyFrames(api, bridge.toProject) +
                         srcLatencyFrames(api, bridge.toDevice)
  bridge.active = true
  true

proc closeLiveSrcBridge*(bridge: var LiveSrcBridge) =
  ## Освободить мост. Конвертеры — первыми: они ссылаются на адаптер,
  ## который освобождает вызывающий, но не раньше этого вызова.
  if not bridge.api.isNil:
    if not bridge.toProject.isNil:
      srcDestroyConverter(bridge.api, bridge.toProject)
    if not bridge.toDevice.isNil:
      srcDestroyConverter(bridge.api, bridge.toDevice)
  bridge.toProject = nil
  bridge.toDevice = nil
  if not bridge.base.isNil:
    deallocShared(cast[pointer](bridge.base))
  bridge.base = nil
  bridge.devIn = nil
  bridge.projIn = nil
  bridge.projInIL = nil
  bridge.projOutIL = nil
  bridge.projOut = nil
  bridge.devOut = nil
  bridge.projQueue = nil
  bridge.devQueue = nil
  bridge.api = nil
  bridge.active = false
  bridge.projCount = 0
  bridge.devCount = 0

# ==============================================================================
# Очереди (только audio thread: один производитель, один потребитель)
# ==============================================================================

proc queuePush(dst: ptr UncheckedArray[float32]; cap: int32;
               head, count: var int32;
               src: ptr UncheckedArray[float32]; stride, frames: int32;
               dropped: var uint32) =
  ## Положить `frames` planar-кадров в кольцо. Переполнение — потеря
  ## САМЫХ НОВЫХ кадров (старые уже в потоке) + счётчик.
  var i = 0'i32
  while i < frames:
    if count >= cap:
      dropped += uint32(frames - i)
      return
    let idx = (head + count) mod cap
    for ch in 0 ..< int(LiveBridgeMaxChannels):
      dst[ch * int(cap) + int(idx)] = src[ch * int(stride) + int(i)]
    inc count
    inc i

proc queuePop(src: ptr UncheckedArray[float32]; cap: int32;
              head, count: var int32;
              dst: ptr UncheckedArray[float32]; stride, frames: int32) =
  ## Забрать до `frames` кадров (меньше — если очередь опустела).
  var i = 0'i32
  while i < frames and count > 0:
    let idx = head
    for ch in 0 ..< int(LiveBridgeMaxChannels):
      dst[ch * int(stride) + int(i)] = src[ch * int(cap) + int(idx)]
    head = (head + 1) mod cap
    dec count
    inc i

proc interleave2(planar: ptr UncheckedArray[float32]; stride: int32;
                 frames: int32; dst: ptr UncheckedArray[float32]) =
  var i = 0
  while i < int(frames):
    dst[i * 2] = planar[i]
    dst[i * 2 + 1] = planar[int(stride) + i]
    inc i

proc deinterleave2(src: ptr UncheckedArray[float32]; frames: int32;
                   dst: ptr UncheckedArray[float32]; stride: int32) =
  var i = 0
  while i < int(frames):
    dst[i] = src[i * 2]
    dst[int(stride) + i] = src[i * 2 + 1]
    inc i

proc clearPlanar(dst: ptr UncheckedArray[float32]; stride, frames: int32) =
  var i = 0
  while i < int(frames):
    dst[i] = 0.0f
    dst[int(stride) + i] = 0.0f
    inc i


# ==============================================================================
# Realtime: один callback устройства
# ==============================================================================

proc bridgeProcess*(
  bridge: var LiveSrcBridge;
  engine: ptr AudioEngine;
  driverIn: ptr UncheckedArray[float32];
  driverOut: ptr UncheckedArray[float32];
  inputChannels, deviceFrames: int32
): bool =
  ## Обработать один callback устройства. `false` — мост не активен или
  ## размер блока не тот, что заявлен при инициализации: вызывающий обязан
  ## отрендерить блок напрямую.
  if not bridge.active or engine.isNil or driverOut.isNil:
    return false
  if deviceFrames != bridge.devFrames:
    return false

  # --- вход устройства: interleaved -> planar ----------------------------
  if not driverIn.isNil and inputChannels > 0:
    deinterleave2(driverIn, deviceFrames, bridge.devIn, bridge.devFrames)
  else:
    clearPlanar(bridge.devIn, bridge.devFrames, deviceFrames)

  # --- SRC: устройство -> проект ----------------------------------------
  let convertedIn = srcProcess(
    bridge.api, bridge.toProject,
    bridge.devIn, bridge.devFrames, deviceFrames,
    bridge.projIn, bridge.projFrames, bridge.projFrames + 16)
  queuePush(bridge.projQueue, bridge.projCap, bridge.projHead,
            bridge.projCount, bridge.projIn, bridge.projFrames,
            convertedIn, bridge.droppedFrames)

  # --- движок: сколько кадров проекта готово ------------------------------
  # Частичный блок законен (#395): на прайминге кадров меньше, и движок
  # продвигает транспорт ровно на них.
  if bridge.projCount > 0:
    let rendered = min(bridge.projCount, bridge.projFrames)
    queuePop(bridge.projQueue, bridge.projCap, bridge.projHead,
             bridge.projCount, bridge.projIn, bridge.projFrames, rendered)
    interleave2(bridge.projIn, bridge.projFrames, rendered, bridge.projInIL)
    var zero = 0
    while zero < int(rendered) * 2:
      bridge.projOutIL[zero] = 0.0f
      inc zero
    renderBlockFrames(
      engine,
      (if inputChannels > 0: bridge.projInIL else: nil),
      inputChannels,
      bridge.projOutIL,
      rendered)
    deinterleave2(bridge.projOutIL, rendered, bridge.projOut,
                  bridge.projFrames)

    # --- SRC: проект -> устройство --------------------------------------
    let convertedOut = srcProcess(
      bridge.api, bridge.toDevice,
      bridge.projOut, bridge.projFrames, rendered,
      bridge.devOut, bridge.devFrames, bridge.devFrames + 16)
    queuePush(bridge.devQueue, bridge.devCap, bridge.devHead,
              bridge.devCount, bridge.devOut, bridge.devFrames,
              convertedOut, bridge.droppedFrames)

  # --- выход устройства: planar -> interleaved ---------------------------
  let have = min(bridge.devCount, deviceFrames)
  if have > 0:
    queuePop(bridge.devQueue, bridge.devCap, bridge.devHead,
             bridge.devCount, bridge.devOut, bridge.devFrames, have)
    interleave2(bridge.devOut, bridge.devFrames, have, driverOut)
  var i = int(have) * 2
  while i < int(deviceFrames) * 2:
    driverOut[i] = 0.0f
    inc i
  true

{.pop.}
