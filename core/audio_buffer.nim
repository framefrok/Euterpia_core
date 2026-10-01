# core/audio_buffer.nim
#
# Lock-free SPSC (Single Producer Single Consumer) ring buffer для обмена
# аудиоданными между Background Thread (файловый I/O) и Audio Thread (DSP).
#
# Гарантии:
# - Zero allocation в hot path
# - No locks, no exceptions
# - Safe для realtime use
# - Cache-line isolated (без false sharing)

import std/atomics

{.push raises: [].}

type
  StreamingAudioBuffer* = object
    data*: ptr UncheckedArray[float32]
    capacityFrames*: int64
    channels*: int32
    # Паддинг для изоляции writePos на отдельной 64-байтной кэш-линии
    pad0: array[44, byte]
    writePos*: Atomic[int64]
    # Паддинг для изоляции readPos на отдельной 64-байтной кэш-линии
    pad1: array[56, byte]
    readPos*: Atomic[int64]
    pad2: array[56, byte]

proc init*(T: type StreamingAudioBuffer, capacityFrames: int64, channels: int32): T =
  result.capacityFrames = capacityFrames
  result.channels = channels
  if capacityFrames > 0 and channels > 0:
    result.data = cast[ptr UncheckedArray[float32]](
      allocShared0(sizeof(float32) * int(capacityFrames * channels))
    )
  else:
    result.data = nil
  result.writePos.store(0, moRelaxed)
  result.readPos.store(0, moRelaxed)

proc destroy*(buf: var StreamingAudioBuffer) =
  if buf.data != nil:
    deallocShared(buf.data)
    buf.data = nil

# ВАЖНО: buf должен быть var, так как load() требует var Atomic[T]
proc availableForWrite*(buf: var StreamingAudioBuffer): int64 =
  if buf.capacityFrames <= 0 or buf.data == nil:
    return 0
  let wPos = buf.writePos.load(moRelaxed)
  let rPos = buf.readPos.load(moAcquire)
  let occupied = wPos - rPos
  return max(0'i64, buf.capacityFrames - occupied)

proc availableForRead*(buf: var StreamingAudioBuffer): int64 =
  if buf.capacityFrames <= 0 or buf.data == nil:
    return 0
  let wPos = buf.writePos.load(moAcquire)
  let rPos = buf.readPos.load(moRelaxed)
  let occupied = wPos - rPos
  return max(0'i64, occupied)

proc commitWrite*(buf: var StreamingAudioBuffer, frames: int32) =
  ## Фиксирует запись заданного количества фреймов и публикует изменения
  ## для Audio Thread с барьером moRelease.
  if frames <= 0 or buf.capacityFrames <= 0:
    return
  let wPos = buf.writePos.load(moRelaxed)
  let rPos = buf.readPos.load(moAcquire)
  let available = max(0'i64, buf.capacityFrames - (wPos - rPos))
  let toCommit = min(int64(frames), available)
  if toCommit > 0:
    buf.writePos.store(wPos + toCommit, moRelease)

proc advanceWritePtr*(buf: var StreamingAudioBuffer, frames: int32) =
  ## Безопасный псевдоним commitWrite для сохранения обратной совместимости.
  buf.commitWrite(frames)

proc getWritePtr*(buf: var StreamingAudioBuffer, framesRequested: int32):
    tuple[ptr1: ptr UncheckedArray[float32], ptr2: ptr UncheckedArray[float32], n1, n2: int32] =
  ## Zero-copy паттерн: возвращает до двух непрерывных сегментов памяти для записи.
  ## Если кольцевой переход не требуется, ptr2 == nil, n2 == 0.
  ## После записи данных обязательно вызвать commitWrite(n1 + n2).
  if framesRequested <= 0 or buf.data == nil or buf.capacityFrames <= 0:
    return (nil, nil, 0'i32, 0'i32)

  let wPos = buf.writePos.load(moRelaxed)
  let rPos = buf.readPos.load(moAcquire)
  let available = max(0'i64, buf.capacityFrames - (wPos - rPos))
  let toWrite = min(int64(framesRequested), available)

  if toWrite <= 0:
    return (nil, nil, 0'i32, 0'i32)

  let startIdx = wPos mod buf.capacityFrames
  let part1 = min(toWrite, buf.capacityFrames - startIdx)
  let part2 = toWrite - part1

  let p1 = cast[ptr UncheckedArray[float32]](addr buf.data[startIdx * buf.channels])
  let p2 = if part2 > 0: buf.data else: nil

  return (p1, p2, int32(part1), int32(part2))

proc getWritePtr*(buf: var StreamingAudioBuffer): ptr UncheckedArray[float32] =
  ## Сохранено для обратной совместимости.
  ## Возвращает указатель на начало текущей позиции записи.
  ## ВНИМАНИЕ: Для безопасной записи на границе буфера используйте getWritePtr(framesRequested).
  if buf.data == nil or buf.capacityFrames <= 0:
    return nil
  let wPos = buf.writePos.load(moRelaxed)
  let startIdx = wPos mod buf.capacityFrames
  return cast[ptr UncheckedArray[float32]](addr buf.data[startIdx * buf.channels])

proc write*(buf: var StreamingAudioBuffer, src: ptr UncheckedArray[float32], frames: int32): int32 {.discardable.} =
  ## Записывает аудиоданные из src в буфер.
  ## Помечен {.discardable.}, поэтому совместим со старым кодом без discard.
  if src == nil or frames <= 0:
    return 0

  let (p1, p2, n1, n2) = buf.getWritePtr(frames)
  let total = n1 + n2
  if total <= 0:
    return 0

  copyMem(p1, src, int(n1 * buf.channels) * sizeof(float32))
  if n2 > 0:
    let src2 = cast[ptr UncheckedArray[float32]](addr src[n1 * buf.channels])
    copyMem(p2, src2, int(n2 * buf.channels) * sizeof(float32))

  buf.commitWrite(total)
  return total

proc commitRead*(buf: var StreamingAudioBuffer, frames: int32) =
  ## Освобождает прочитанные фреймы для записи и публикует изменения
  ## для Background Thread с барьером moRelease.
  if frames <= 0 or buf.capacityFrames <= 0:
    return
  let wPos = buf.writePos.load(moAcquire)
  let rPos = buf.readPos.load(moRelaxed)
  let available = max(0'i64, wPos - rPos)
  let toCommit = min(int64(frames), available)
  if toCommit > 0:
    buf.readPos.store(rPos + toCommit, moRelease)

proc advanceReadPtr*(buf: var StreamingAudioBuffer, frames: int32) =
  ## Безопасный псевдоним commitRead.
  buf.commitRead(frames)

proc getReadPtr*(buf: var StreamingAudioBuffer, framesRequested: int32):
    tuple[ptr1: ptr UncheckedArray[float32], ptr2: ptr UncheckedArray[float32], n1, n2: int32] =
  ## Zero-copy паттерн для DSP: возвращает до двух непрерывных сегментов памяти для чтения.
  ## После обработки данных обязательно вызвать commitRead(n1 + n2).
  if framesRequested <= 0 or buf.data == nil or buf.capacityFrames <= 0:
    return (nil, nil, 0'i32, 0'i32)

  let wPos = buf.writePos.load(moAcquire)
  let rPos = buf.readPos.load(moRelaxed)
  let available = max(0'i64, wPos - rPos)
  let toRead = min(int64(framesRequested), available)

  if toRead <= 0:
    return (nil, nil, 0'i32, 0'i32)

  let startIdx = rPos mod buf.capacityFrames
  let part1 = min(toRead, buf.capacityFrames - startIdx)
  let part2 = toRead - part1

  let p1 = cast[ptr UncheckedArray[float32]](addr buf.data[startIdx * buf.channels])
  let p2 = if part2 > 0: buf.data else: nil

  return (p1, p2, int32(part1), int32(part2))

proc getReadPtr*(buf: var StreamingAudioBuffer): ptr UncheckedArray[float32] =
  ## Возвращает указатель на текущую позицию чтения.
  if buf.data == nil or buf.capacityFrames <= 0:
    return nil
  let rPos = buf.readPos.load(moRelaxed)
  let startIdx = rPos mod buf.capacityFrames
  return cast[ptr UncheckedArray[float32]](addr buf.data[startIdx * buf.channels])

proc read*(buf: var StreamingAudioBuffer, dst: ptr UncheckedArray[float32], frames: int32): int32 =
  ## Читает аудиоданные из буфера в dst.
  ## Возвращает фактически прочитанное количество фреймов.
  if dst == nil or frames <= 0:
    return 0

  let (p1, p2, n1, n2) = buf.getReadPtr(frames)
  let total = n1 + n2
  if total <= 0:
    return 0

  copyMem(dst, p1, int(n1 * buf.channels) * sizeof(float32))
  if n2 > 0:
    let dst2 = cast[ptr UncheckedArray[float32]](addr dst[n1 * buf.channels])
    copyMem(dst2, p2, int(n2 * buf.channels) * sizeof(float32))

  buf.commitRead(total)
  return total

{.pop.}