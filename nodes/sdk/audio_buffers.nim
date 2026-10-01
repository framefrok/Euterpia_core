# nodes/sdk/audio_buffers.nim
#
# Доступ к аудиобуферам портов для авторов нод.
#
# Формат буферов в EUTERPIA (задаётся компилятором графа, см.
# graph_compiler.compileGraph и CompiledPipeline.audioArena):
#
#   ВНУТРИ графа  — planar stereo: channels = 2, stride = arenaFrames.
#                   Каналы лежат подряд, поэтому на канал можно
#                   передать непрерывный указатель в C-ядро.
#
#   ВЫХОД в драйвер — interleaved stereo (таков формат PortAudio и
#                   renderOffline). Указатель на канал здесь непрерывным
#                   быть не может.
#
# Отсюда правило, которое экономит кучу кода в нодах:
#   - DSP-ядра (осциллятор, фильтры, задержка, шум) работают ТОЛЬКО
#     с planar-буферами и зовут C напрямую по указателю на канал;
#   - ноды, которые могут стоять последними в цепочке (gain, pan,
#     компрессор), дополнительно умеют interleaved через scalar-путь.
#
# Модуль ничего не аллоцирует: только арифметика индексов.

import signal_types
import node_interface

{.push raises: [].}

proc isPlanar*(buf: PAudioBuffer): bool {.inline.} =
  ## true — каналы лежат подряд (planar), false — interleaved.
  if buf.isNil or buf.channels <= 1:
    return true
  let stride = if buf.stride > 0: buf.stride else: buf.frames
  stride >= buf.frames

proc channelCount*(buf: PAudioBuffer): int32 {.inline.} =
  if buf.isNil: return 0
  buf.channels

proc processFrames*(ctx: ptr NodeProcessContext; buf: PAudioBuffer): int32 {.inline.} =
  ## Сколько сэмплов реально можно обработать: блок не длиннее буфера.
  if buf.isNil or buf.data.isNil or ctx.isNil:
    return 0
  let byBuffer = if buf.frames > 0: buf.frames else: signal_types.MaxBlockSize.int32
  min(ctx.blockSize, byBuffer)

proc channelPtr*(buf: PAudioBuffer; ch: int32; frames: int32): ptr float32 {.inline.} =
  ## Непрерывный указатель на начало канала.
  ## nil, если буфер interleaved: тогда нужен scalar-путь (см. sampleAt).
  if buf.isNil or buf.data.isNil:
    return nil
  if not buf.isPlanar:
    return nil
  if ch < 0 or ch >= buf.channels:
    return nil

  let stride = if buf.stride > 0: buf.stride else: buf.frames
  cast[ptr float32](addr buf.data[ch * stride])

proc sampleAt*(buf: PAudioBuffer; ch, frame: int32): float32 {.inline.} =
  ## Чтение сэмпла с учётом раскладки. Безопасно для любого формата.
  if buf.isNil or buf.data.isNil or frame < 0 or frame >= buf.frames:
    return 0.0f
  let chs = if buf.channels > 0: buf.channels else: 1
  if ch < 0 or ch >= chs:
    return 0.0f
  if buf.isPlanar:
    let stride = if buf.stride > 0: buf.stride else: buf.frames
    buf.data[ch * stride + frame]
  else:
    buf.data[frame * chs + ch]

proc setSampleAt*(buf: PAudioBuffer; ch, frame: int32; value: float32) {.inline.} =
  if buf.isNil or buf.data.isNil or frame < 0 or frame >= buf.frames:
    return
  let chs = if buf.channels > 0: buf.channels else: 1
  if ch < 0 or ch >= chs:
    return
  if buf.isPlanar:
    let stride = if buf.stride > 0: buf.stride else: buf.frames
    buf.data[ch * stride + frame] = value
  else:
    buf.data[frame * chs + ch] = value

proc fillZero*(buf: PAudioBuffer; frames: int32) {.inline.} =
  ## Очистка буфера. Вызывать перед записью, если нода может ничего
  ## не вывести (например, когда вход не подключён) — иначе в буфере
  ## останется мусор от предыдущего блока.
  if buf.isNil or buf.data.isNil or frames <= 0:
    return
  let n = min(frames, if buf.frames > 0: buf.frames else: signal_types.MaxBlockSize.int32)
  let chs = if buf.channels > 0: buf.channels else: 1
  let stride = if buf.stride > 0: buf.stride else: buf.frames

  if buf.isPlanar:
    for ch in 0 ..< chs:
      let p = cast[ptr UncheckedArray[float32]](addr buf.data[ch * stride])
      var i = 0
      while i < n:
        p[i] = 0.0f
        inc i
  else:
    var i = 0
    while i < n * chs:
      buf.data[i] = 0.0f
      inc i

proc inlineZero*(buf: PAudioBuffer; frames: int32) {.inline.} =
  ## Заглушка выхода: буфер очищается целиком.
  ## Используется, когда порт не planar — писать в него по каналам
  ## через C-ядро нельзя.
  buf.fillZero(frames)

template forEachFrame*(buf: PAudioBuffer; frames: int32; body: untyped) =
  ## Обход кадров буфера в interleaved-раскладке.
  ## Переменная кадра внутри body называется `i`.
  var i {.inject.} = 0'i32
  while i < frames:
    body
    inc i

{.pop.}
