# adapters/clap/clap_plugin_extensions.nim
#
# Plugin-side расширения CLAP 1.2: то, что ХОСТ вызывает у ПЛАГИНА
# (issue #49).
#
#   clap.params      — count / get_info / get_value / value_to_text /
#                      text_to_value / flush
#   clap.state       — save / load (байтовые потоки)
#   clap.latency     — get
#   clap.audio-ports — count / get
#
# Заменяет собой `clap_plugin_host.nim`, где те же типы были объявлены с
# ДВУМЯ ошибками ABI, найденными при сверке с официальными заголовками:
#
#   1. `clap_istream_t` = {ctx, read} и `clap_ostream_t` = {ctx, write} —
#      РАЗНЫЕ структуры. Общий «ClapStream» со склейкой {ctx, write, read}
#      сдвигал `read` на 8 байт, то есть `state.load` работал бы по
#      случайному указателю;
#   2. `clap_audio_port_info_t` содержит 6 полей в порядке
#      id, name, flags, channel_count, port_type, in_place_pair —
#      в старом модуле `flags` и `channel_count` были переставлены, а
#      `port_type` отсутствовал.
#
# Layout сверен с include/clap/ext/{params,state,latency,audio-ports}.h,
# include/clap/stream.h и include/clap/string-sizes.h
# (CLAP_NAME_SIZE=256, CLAP_PATH_SIZE=1024).
#
# MANIFEST §8, §41, §42.

import clap_host
import clap_host_extensions

{.push raises: [].}

const
  ClapNameSize* = 256
  ClapPathSize* = 1024

  ## Идентификаторы plugin-side расширений. Для params/state/latency CLAP
  ## использует те же строки, что и у host-side, — они берутся из
  ## clap_host_extensions, чтобы не дублировать литералы.
  ClapExtAudioPorts* = cstring"clap.audio-ports"

  # clap_param_info_flags (include/clap/ext/params.h)
  ClapParamIsStepped* = 1'u32 shl 0
  ClapParamIsPeriodic* = 1'u32 shl 1
  ClapParamIsHidden* = 1'u32 shl 2
  ClapParamIsReadonly* = 1'u32 shl 3
  ClapParamIsBypass* = 1'u32 shl 4
  ClapParamIsAutomatable* = 1'u32 shl 5
  ClapParamIsModulatable* = 1'u32 shl 10
  ClapParamRequiresProcess* = 1'u32 shl 15
  ClapParamIsEnum* = 1'u32 shl 16

type
  ## --- clap.state: два РАЗНЫХ типа потоков (stream.h) ---
  ClapIStream* {.bycopy.} = object
    ctx*: pointer
    read*: proc(stream: ptr ClapIStream; buffer: pointer; size: uint64): int64
      {.cdecl, raises: [], gcsafe.}

  ClapOStream* {.bycopy.} = object
    ctx*: pointer
    write*: proc(stream: ptr ClapOStream; buffer: pointer; size: uint64): int64
      {.cdecl, raises: [], gcsafe.}

  ClapPluginState* {.bycopy.} = object
    save*: proc(plugin: ptr ClapPlugin; stream: ptr ClapOStream): bool
      {.cdecl, raises: [], gcsafe.}
    load*: proc(plugin: ptr ClapPlugin; stream: ptr ClapIStream): bool
      {.cdecl, raises: [], gcsafe.}

  ## --- clap.latency ---
  ClapPluginLatency* {.bycopy.} = object
    get*: proc(plugin: ptr ClapPlugin): uint32
      {.cdecl, raises: [], gcsafe.}

  ## --- clap.audio-ports ---
  ClapAudioPortInfo* {.bycopy.} = object
    id*: uint32
    name*: array[ClapNameSize, char]
    flags*: uint32
    channelCount*: uint32
    portType*: cstring
    inPlacePair*: uint32

  ClapPluginAudioPorts* {.bycopy.} = object
    count*: proc(plugin: ptr ClapPlugin; isInput: bool): uint32
      {.cdecl, raises: [], gcsafe.}
    get*: proc(plugin: ptr ClapPlugin; index: uint32; isInput: bool;
               info: ptr ClapAudioPortInfo): bool
      {.cdecl, raises: [], gcsafe.}

  ## --- clap.params ---
  ClapParamInfo* {.bycopy.} = object
    id*: uint32
    flags*: uint32
    cookie*: pointer
    name*: array[ClapNameSize, char]
    module*: array[ClapPathSize, char]
    minValue*: float64
    maxValue*: float64
    defaultValue*: float64

  ClapPluginParams* {.bycopy.} = object
    count*: proc(plugin: ptr ClapPlugin): uint32
      {.cdecl, raises: [], gcsafe.}
    getInfo*: proc(plugin: ptr ClapPlugin; paramIndex: uint32;
                   info: ptr ClapParamInfo): bool
      {.cdecl, raises: [], gcsafe.}
    getValue*: proc(plugin: ptr ClapPlugin; paramId: uint32;
                    value: ptr float64): bool
      {.cdecl, raises: [], gcsafe.}
    valueToText*: proc(plugin: ptr ClapPlugin; paramId: uint32;
                       value: float64; display: cstring; size: uint32): bool
      {.cdecl, raises: [], gcsafe.}
    textToValue*: proc(plugin: ptr ClapPlugin; paramId: uint32;
                       display: cstring; value: ptr float64): bool
      {.cdecl, raises: [], gcsafe.}
    flush*: proc(plugin: ptr ClapPlugin; input: ptr ClapInputEvents;
                 output: ptr ClapOutputEvents)
      {.cdecl, raises: [], gcsafe.}

  ClapPluginExtSet* = object
    ## Кэш указателей на расширения конкретного инстанса плагина.
    params*: ptr ClapPluginParams
    state*: ptr ClapPluginState
    latency*: ptr ClapPluginLatency
    audioPorts*: ptr ClapPluginAudioPorts

# ABI-guard: число полей каждой структуры обязано совпадать с заголовком.
static:
  doAssert sizeof(ClapIStream) == 2 * sizeof(pointer)
  doAssert sizeof(ClapOStream) == 2 * sizeof(pointer)
  doAssert sizeof(ClapPluginState) == 2 * sizeof(pointer)
  doAssert sizeof(ClapPluginLatency) == 1 * sizeof(pointer)
  doAssert sizeof(ClapPluginAudioPorts) == 2 * sizeof(pointer)
  doAssert sizeof(ClapPluginParams) == 6 * sizeof(pointer)

# ----------------------------------------------------------------------------
# Байтовые потоки clap.state
# ----------------------------------------------------------------------------

type
  BufferCursor* = object
    ## Курсор поверх буфера вызывающего: и для сохранения, и для чтения.
    ## Живёт на стеке вызывающего и обязан пережить вызов плагина.
    data*: pointer
    capacity*: uint64
    used*: uint64

proc bufferWrite(stream: ptr ClapOStream; buffer: pointer; size: uint64): int64
    {.cdecl, raises: [], gcsafe.} =
  ## Контракт CLAP: -1 при ошибке/переполнении, иначе число записанных байт.
  let cur = cast[ptr BufferCursor](stream.ctx)
  if cur.isNil or buffer.isNil:
    return -1
  if cur.used + size > cur.capacity:
    return -1
  copyMem(cast[pointer](cast[uint](cur.data) + cur.used), buffer, int(size))
  cur.used += size
  int64(size)

proc bufferRead(stream: ptr ClapIStream; buffer: pointer; size: uint64): int64
    {.cdecl, raises: [], gcsafe.} =
  let cur = cast[ptr BufferCursor](stream.ctx)
  if cur.isNil or buffer.isNil:
    return -1
  if cur.used + size > cur.capacity:
    return -1
  copyMem(buffer, cast[pointer](cast[uint](cur.data) + cur.used), int(size))
  cur.used += size
  int64(size)

proc initWriteStream*(cur: var BufferCursor; data: pointer;
                      capacity: int): ClapOStream =
  ## Пишущий поток поверх `data[0..<capacity]`.
  cur = BufferCursor(data: data, capacity: uint64(max(0, capacity)), used: 0'u64)
  result.ctx = cast[pointer](addr cur)
  result.write = bufferWrite

proc initReadStream*(cur: var BufferCursor; data: pointer;
                     size: int): ClapIStream =
  ## Читающий поток поверх `data[0..<size]`.
  cur = BufferCursor(data: data, capacity: uint64(max(0, size)), used: 0'u64)
  result.ctx = cast[pointer](addr cur)
  result.read = bufferRead

proc bytesUsed*(cur: BufferCursor): int {.inline.} =
  ## Сколько байт записано (или прочитано) к моменту вызова.
  int(cur.used)

# ----------------------------------------------------------------------------
# Получение расширений у инстанса
# ----------------------------------------------------------------------------

proc fetchClapPluginExts*(plugin: ptr ClapPlugin): ClapPluginExtSet =
  ## Кэширует указатели расширений. Вызывать один раз после createPlugin +
  ## init: плагин отдаёт стабильные указатели на время жизни инстанса.
  if plugin.isNil or plugin.getExtension.isNil:
    return

  result.params = cast[ptr ClapPluginParams](
    plugin.getExtension(plugin, ClapExtParams))
  result.state = cast[ptr ClapPluginState](
    plugin.getExtension(plugin, ClapExtState))
  result.latency = cast[ptr ClapPluginLatency](
    plugin.getExtension(plugin, ClapExtLatency))
  result.audioPorts = cast[ptr ClapPluginAudioPorts](
    plugin.getExtension(plugin, ClapExtAudioPorts))

proc readFixedString*(s: openArray[char]): string =
  ## C-строка из фиксированного буфера (control-path).
  var n = 0
  while n < s.len and s[n] != '\0':
    inc n
  result = newString(n)
  if n > 0:
    copyMem(addr result[0], unsafeAddr s[0], n)

{.pop.}
