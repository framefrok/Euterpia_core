#eut_plugin.nim
import std/dynlib

when not declared(csize_t):
  type csize_t* = uint

# ---------------------------------------------------------------------------
# ABI version
# ---------------------------------------------------------------------------

const
  EUT_ABI_MAJOR* = 1'u32
  EUT_ABI_MINOR* = 0'u32
  EUT_ABI_VERSION* = (EUT_ABI_MAJOR shl 16) or EUT_ABI_MINOR

template eutAbiMajor*(v: uint32): uint32 =
  v shr 16

template eutAbiMinor*(v: uint32): uint32 =
  v and 0xffff'u32

# ---------------------------------------------------------------------------
# Feature flags
# ---------------------------------------------------------------------------

const
  EUT_FEAT_AUDIO_F32*    = 1'u32 shl 0
  EUT_FEAT_SYNTH*        = 1'u32 shl 1
  EUT_FEAT_EFFECT*       = 1'u32 shl 2
  EUT_FEAT_CONTROL*      = 1'u32 shl 3
  EUT_FEAT_NOTE_EVENTS*  = 1'u32 shl 4
  EUT_FEAT_PARAM_EVENTS* = 1'u32 shl 5
  EUT_FEAT_MIDI_EVENTS*  = 1'u32 shl 6
  EUT_FEAT_LATENCY*      = 1'u32 shl 7
  EUT_FEAT_TRANSPORT*    = 1'u32 shl 8

const
  EUT_HOST_DEFAULT_FEATURES* =
    EUT_FEAT_AUDIO_F32 or
    EUT_FEAT_NOTE_EVENTS or
    EUT_FEAT_PARAM_EVENTS or
    EUT_FEAT_MIDI_EVENTS or
    EUT_FEAT_LATENCY

# ---------------------------------------------------------------------------
# Port / param / event constants
# ---------------------------------------------------------------------------

const
  EUT_PORT_INPUT*  = 0'u32
  EUT_PORT_OUTPUT* = 1'u32

  EUT_MEDIA_AUDIO_F32* = 1'u32
  EUT_MEDIA_EVENT*     = 2'u32

  EUT_PORT_F_MAIN*     = 1'u32 shl 0
  EUT_PORT_F_OPTIONAL* = 1'u32 shl 1

const
  EUT_PARAM_F_AUTOMATABLE* = 1'u32 shl 0
  EUT_PARAM_F_MODULATABLE* = 1'u32 shl 1
  EUT_PARAM_F_HIDDEN*      = 1'u32 shl 2
  EUT_PARAM_F_INTEGER*     = 1'u32 shl 3

const
  EUT_EVENT_NONE*         = 0'u32
  EUT_EVENT_NOTE_ON*      = 1'u32
  EUT_EVENT_NOTE_OFF*     = 2'u32
  EUT_EVENT_NOTE_PRESSURE* = 3'u32
  EUT_EVENT_CONTROL*      = 4'u32
  EUT_EVENT_PARAM_SET*    = 5'u32
  EUT_EVENT_MIDI*         = 6'u32
  EUT_EVENT_TRANSPORT*    = 7'u32

template EUT_EVENT_MASK*(t: uint32): uint32 =
  1'u32 shl t

const
  EUT_PROCESS_OK*              = 0'u32
  EUT_PROCESS_ERROR*           = 1'u32
  EUT_PROCESS_LATENCY_CHANGED* = 1'u32 shl 1
  EUT_PROCESS_TAIL_CHANGED*    = 1'u32 shl 2
  EUT_PROCESS_REQUEST_RESET*   = 1'u32 shl 3

const
  EUT_MAX_ID_CHARS*         = 128
  EUT_MAX_NAME_CHARS*       = 128
  EUT_MAX_PORT_NAME_CHARS*  = 64
  EUT_MAX_PARAM_NAME_CHARS* = 64
  EUT_MAX_UNIT_CHARS*       = 16

# ---------------------------------------------------------------------------
# Host API
# ---------------------------------------------------------------------------

type
  EutLogFn* =
    proc(user: pointer; level: uint32; msg: cstring)
      {.cdecl, raises: [], gcsafe.}

  EutAllocFn* =
    proc(user: pointer; size: csize_t; align: uint32): pointer
      {.cdecl, raises: [], gcsafe.}

  EutFreeFn* =
    proc(user: pointer; p: pointer)
      {.cdecl, raises: [], gcsafe.}

  EutHostApi* {.bycopy.} = object
    structSize*: csize_t
    abiVersion*: uint32
    features*: uint32

    log*: EutLogFn
    logUser*: pointer

    alloc*: EutAllocFn
    free*: EutFreeFn
    allocUser*: pointer

    reserved*: array[4, pointer]

# ---------------------------------------------------------------------------
# Descriptors
# ---------------------------------------------------------------------------

type
  EutPortDescriptor* {.bycopy.} = object
    structSize*: csize_t
    id*: uint32
    direction*: uint32       # EUT_PORT_INPUT / EUT_PORT_OUTPUT
    mediaType*: uint32       # EUT_MEDIA_AUDIO_F32 / EUT_MEDIA_EVENT
    channelCount*: uint32    # only for audio ports
    supportedEvents*: uint32 # bitmask of EUT_EVENT_MASK(...)
    flags*: uint32
    name*: array[EUT_MAX_PORT_NAME_CHARS, char]
    reserved*: array[2, pointer]

  EutParamDescriptor* {.bycopy.} = object
    structSize*: csize_t
    id*: uint32
    flags*: uint32
    minValue*: cdouble
    maxValue*: cdouble
    defaultValue*: cdouble
    unit*: array[EUT_MAX_UNIT_CHARS, char]
    name*: array[EUT_MAX_PARAM_NAME_CHARS, char]
    reserved*: array[2, pointer]

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

type
  EutNotePayload* {.bycopy.} = object
    channel*: uint16
    key*: int16
    noteId*: uint32
    velocity*: cdouble
    pressure*: cdouble

  EutControlPayload* {.bycopy.} = object
    channel*: uint16
    controlId*: uint16
    reserved*: uint32
    value*: cdouble

  EutParamPayload* {.bycopy.} = object
    paramId*: uint32
    flags*: uint32
    value*: cdouble

  EutMidiPayload* {.bycopy.} = object
    size*: uint32
    reserved*: uint32
    data*: array[4, uint8]

  EutEventPayload* {.bycopy, union.} = object
    note*: EutNotePayload
    control*: EutControlPayload
    param*: EutParamPayload
    midi*: EutMidiPayload
    raw*: array[4, uint64]

  EutEvent* {.bycopy.} = object
    eventType*: uint32
    flags*: uint32
    timeFrames*: uint32
    reserved*: uint32
    payload*: EutEventPayload

  EutEventQueue* {.bycopy.} = object
    structSize*: csize_t
    capacity*: uint32
    count*: uint32
    events*: ptr UncheckedArray[EutEvent]
    reserved*: array[2, pointer]

static:
  # Это жёсткая часть контракта. Если здесь падает размер —
  # нужно фиксить layout, а не "подстраивать" код под компилятор.
  doAssert sizeof(EutEventPayload) == 32
  doAssert sizeof(EutEvent) == 48

# ---------------------------------------------------------------------------
# Process structures
# ---------------------------------------------------------------------------

type
  EutAudioBuffer* {.bycopy.} = object
    structSize*: csize_t
    portIndex*: uint32
    channelCount*: uint32
    data*: ptr UncheckedArray[ptr cfloat] # float**
    reserved*: array[2, pointer]

  EutEventPortBuffers* {.bycopy.} = object
    structSize*: csize_t
    portIndex*: uint32
    reserved0*: uint32
    queue*: ptr EutEventQueue
    reserved*: array[2, pointer]

  EutProcessContext* {.bycopy.} = object
    structSize*: csize_t

    frames*: uint32
    audioInputCount*: uint32
    audioOutputCount*: uint32
    eventInputCount*: uint32
    eventOutputCount*: uint32
    paramCount*: uint32

    sampleRate*: cdouble

    audioInputs*: ptr UncheckedArray[EutAudioBuffer]
    audioOutputs*: ptr UncheckedArray[EutAudioBuffer]

    eventInputs*: ptr UncheckedArray[EutEventPortBuffers]
    eventOutputs*: ptr UncheckedArray[EutEventPortBuffers]

    paramValues*: ptr UncheckedArray[cdouble]

    reserved*: array[4, pointer]

# ---------------------------------------------------------------------------
# Plugin callback signatures
# ---------------------------------------------------------------------------

type
  EutCreateInstanceFn* =
    proc(host: ptr EutHostApi; plugin: pointer): pointer
      {.cdecl, raises: [], gcsafe.}

  EutDestroyInstanceFn* =
    proc(host: ptr EutHostApi; plugin: pointer; instance: pointer)
      {.cdecl, raises: [], gcsafe.}

  EutActivateFn* =
    proc(
      host: ptr EutHostApi;
      plugin: pointer;
      instance: pointer;
      sampleRate: cdouble;
      maxFrames: uint32
    ): uint32
      {.cdecl, raises: [], gcsafe.}

  EutDeactivateFn* =
    proc(host: ptr EutHostApi; plugin: pointer; instance: pointer)
      {.cdecl, raises: [], gcsafe.}

  EutProcessFn* =
    proc(
      host: ptr EutHostApi;
      plugin: pointer;
      instance: pointer;
      ctx: ptr EutProcessContext
    ): uint32
      {.cdecl, raises: [], gcsafe.}

  EutGetLatencyFn* =
    proc(host: ptr EutHostApi; plugin: pointer; instance: pointer): int32
      {.cdecl, raises: [], gcsafe.}

  EutResetFn* =
    proc(host: ptr EutHostApi; plugin: pointer; instance: pointer)
      {.cdecl, raises: [], gcsafe.}

# ---------------------------------------------------------------------------
# Plugin descriptor
# ---------------------------------------------------------------------------

type
  EutPluginDescriptor* {.bycopy.} = object
    structSize*: csize_t
    abiVersion*: uint32
    features*: uint32

    id*: array[EUT_MAX_ID_CHARS, char]
    name*: array[EUT_MAX_NAME_CHARS, char]
    vendor*: array[EUT_MAX_NAME_CHARS, char]
    version*: array[EUT_MAX_NAME_CHARS, char]

    portCount*: uint32
    ports*: ptr UncheckedArray[EutPortDescriptor]

    paramCount*: uint32
    params*: ptr UncheckedArray[EutParamDescriptor]

    createInstance*: EutCreateInstanceFn
    destroyInstance*: EutDestroyInstanceFn

    activate*: EutActivateFn
    deactivate*: EutDeactivateFn
    process*: EutProcessFn

    getLatency*: EutGetLatencyFn
    reset*: EutResetFn

    reserved*: array[8, pointer]

# ---------------------------------------------------------------------------
# Default host allocator / logger
# ---------------------------------------------------------------------------

proc eut_calloc(nmemb, size: csize_t): pointer
  {.importc: "calloc", header: "<stdlib.h>", noconv, raises: [], gcsafe.}

proc eut_free(p: pointer)
  {.importc: "free", header: "<stdlib.h>", noconv, raises: [], gcsafe.}

proc eutDefaultLog(user: pointer; level: uint32; msg: cstring)
  {.cdecl, raises: [], gcsafe.} =
  # Намеренно пустой по умолчанию.
  # Хост может подключить настоящий логгер.
  discard

proc eutDefaultAlloc(user: pointer; size: csize_t; align: uint32): pointer
  {.cdecl, raises: [], gcsafe.} =
  if size == 0:
    return nil
  # Контракт: хост гарантирует выравнивание не хуже 16 байт.
  # Если плагину нужно больше — пусть использует собственный внутренний
  # aligned allocator, но не требует этого от хоста.
  if align > 16:
    return nil
  result = eut_calloc(1.csize_t, size)

proc eutDefaultFree(user: pointer; p: pointer)
  {.cdecl, raises: [], gcsafe.} =
  if p != nil:
    eut_free(p)

# ---------------------------------------------------------------------------
# Module handle / loader
# ---------------------------------------------------------------------------

type
  EutPluginModule* = object
    handle: LibHandle
    host: ptr EutHostApi
    descriptor*: ptr EutPluginDescriptor

proc unload*(m: var EutPluginModule) =
  ## Перед вызовом нужно уничтожить все живые инстансы.
  if m.handle != nil:
    unloadLib(m.handle)
    m.handle = nil

  if m.host != nil:
    eut_free(cast[pointer](m.host))
    m.host = nil

  m.descriptor = nil

proc loadEutPlugin*(
  soPath: string;
  requiredFeatures: uint32 = 0
): EutPluginModule =
  let lib = loadLib(soPath)
  if lib == nil:
    raise newException(IOError, "Не удалось загрузить .eut модуль: " & soPath)

  let host = cast[ptr EutHostApi](
    eut_calloc(csize_t(1), csize_t(sizeof(EutHostApi)))
  )

  if host == nil:
    unloadLib(lib)
    raise newException(IOError, "Не удалось выделить память под EutHostApi")

  host.structSize = csize_t(sizeof(EutHostApi))
  host.abiVersion = EUT_ABI_VERSION
  host.features = EUT_HOST_DEFAULT_FEATURES
  host.log = eutDefaultLog
  host.logUser = nil
  host.alloc = eutDefaultAlloc
  host.free = eutDefaultFree
  host.allocUser = nil

  template fail(msg: string; E: untyped) =
    unloadLib(lib)
    eut_free(cast[pointer](host))
    raise newException(E, msg)

  # Опциональная быстрая проверка версии до входа в плагин.
  let versionSym = cast[proc(): uint32 {.cdecl, raises: [], gcsafe.}](
    lib.symAddr("eut_abi_version")
  )

  if versionSym != nil:
    let v = versionSym()
    if eutAbiMajor(v) != EUT_ABI_MAJOR:
      fail(
        "Несовместимая мажорная версия ABI в " & soPath,
        ValueError
      )

  let initSym = cast[
    proc(h: ptr EutHostApi): ptr EutPluginDescriptor
      {.cdecl, raises: [], gcsafe.}
  ](lib.symAddr("eut_init"))

  if initSym == nil:
    fail("Символ eut_init не найден в " & soPath, KeyError)

  let desc = initSym(host)

  if desc == nil:
    fail("Плагин вернул нулевой дескриптор", ValueError)

  if desc.structSize < csize_t(sizeof(EutPluginDescriptor)):
    fail(
      "EutPluginDescriptor слишком мал: несовместимый layout",
      ValueError
    )

  if eutAbiMajor(desc.abiVersion) != EUT_ABI_MAJOR:
    fail(
      "Несовместимая мажорная версия дескриптора плагина",
      ValueError
    )

  if requiredFeatures != 0:
    if (desc.features and requiredFeatures) != requiredFeatures:
      fail(
        "Плагин не поддерживает требуемые возможности",
        ValueError
      )

  if desc.createInstance == nil or
     desc.destroyInstance == nil or
     desc.process == nil:
    fail(
      "Плагин не предоставляет обязательные функции " &
      "createInstance/destroyInstance/process",
      ValueError
    )

  result = EutPluginModule(
    handle: lib,
    host: host,
    descriptor: desc
  )

# ---------------------------------------------------------------------------
# Safe wrappers для хоста
# ---------------------------------------------------------------------------

proc isValid*(m: EutPluginModule): bool {.inline.} =
  m.handle != nil and m.host != nil and m.descriptor != nil

proc hasFeature*(m: EutPluginModule; feature: uint32): bool {.inline.} =
  if not m.isValid():
    return false
  (m.descriptor.features and feature) == feature

proc createInstance*(m: EutPluginModule): pointer
  {.inline, raises: [], gcsafe.} =
  if not m.isValid():
    return nil
  if m.descriptor.createInstance == nil:
    return nil
  result = m.descriptor.createInstance(m.host, cast[pointer](m.descriptor))

proc destroyInstance*(m: EutPluginModule; instance: pointer)
  {.inline, raises: [], gcsafe.} =
  if instance == nil:
    return
  if not m.isValid():
    return
  if m.descriptor.destroyInstance == nil:
    return
  m.descriptor.destroyInstance(m.host, cast[pointer](m.descriptor), instance)

proc activate*(
  m: EutPluginModule;
  instance: pointer;
  sampleRate: cdouble;
  maxFrames: uint32
): uint32 {.inline, raises: [], gcsafe.} =
  if not m.isValid() or instance == nil:
    return EUT_PROCESS_ERROR
  if m.descriptor.activate == nil:
    return EUT_PROCESS_OK
  result = m.descriptor.activate(
    m.host,
    cast[pointer](m.descriptor),
    instance,
    sampleRate,
    maxFrames
  )

proc deactivate*(m: EutPluginModule; instance: pointer)
  {.inline, raises: [], gcsafe.} =
  if not m.isValid() or instance == nil:
    return
  if m.descriptor.deactivate != nil:
    m.descriptor.deactivate(
      m.host,
      cast[pointer](m.descriptor),
      instance
    )

proc process*(
  m: EutPluginModule;
  instance: pointer;
  ctx: ptr EutProcessContext
): uint32 {.inline, raises: [], gcsafe.} =
  if not m.isValid() or instance == nil or ctx == nil:
    return EUT_PROCESS_ERROR
  if m.descriptor.process == nil:
    return EUT_PROCESS_ERROR
  result = m.descriptor.process(
    m.host,
    cast[pointer](m.descriptor),
    instance,
    ctx
  )

proc latency*(m: EutPluginModule; instance: pointer): int32
  {.inline, raises: [], gcsafe.} =
  if not m.isValid() or instance == nil:
    return 0
  if m.descriptor.getLatency == nil:
    return 0
  result = m.descriptor.getLatency(
    m.host,
    cast[pointer](m.descriptor),
    instance
  )

proc reset*(m: EutPluginModule; instance: pointer)
  {.inline, raises: [], gcsafe.} =
  if not m.isValid() or instance == nil:
    return
  if m.descriptor.reset != nil:
    m.descriptor.reset(
      m.host,
      cast[pointer](m.descriptor),
      instance
    )

# ---------------------------------------------------------------------------
# Некоторые удобные утилиты host-side
# ---------------------------------------------------------------------------

proc toString*(a: openArray[char]): string =
  result = ""
  for ch in a:
    if ch == '\0':
      break
    result.add ch

proc clear*(q: ptr EutEventQueue) {.inline, raises: [], gcsafe.} =
  if q != nil:
    q.count = 0

proc push*(q: ptr EutEventQueue; e: EutEvent): bool
  {.inline, raises: [], gcsafe.} =
  if q == nil or q.events == nil:
    return false
  if q.count >= q.capacity:
    return false
  q.events[q.count] = e
  inc q.count
  return true