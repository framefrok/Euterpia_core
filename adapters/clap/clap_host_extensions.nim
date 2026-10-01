# adapters/clap/clap_host_extensions.nim
#
# Host-side расширения CLAP 1.2 для адаптера хостинга (issue #6).
#
# Здесь то, что ПЛАГИН вызывает у ХОСТА через clap_host.get_extension():
#
#   clap.params       — rescan / clear / request_flush
#   clap.state        — mark_dirty
#   clap.thread-check — is_main_thread / is_audio_thread
#   clap.latency      — changed
#   clap.gui          — resize_hints_changed / request_resize / request_show /
#                       request_hide / closed
#
# Плюс три request-колбэка хоста (request_restart / request_process /
# request_callback): они не делают работу в audio-потоке, а только
# выставляют флаги, которые main-loop забирает через `take*`.
#
# Layout структур сверен с официальными заголовками CLAP
# (include/clap/ext/*.h, include/clap/host.h) — порядок полей и ABI
# совпадают побайтово. Идентификаторы расширений — те же строки, что и
# у plugin-side: CLAP использует один id для обеих сторон.
#
# Потоки: `is_main_thread`/`is_audio_thread` сравнивают id текущего потока
# с записанными. Аудио-поток помечает адаптер при первом вызове process.
#
# MANIFEST §8, §41, §42.

import std/atomics
import clap_host

{.push raises: [].}

proc strcmp(a, b: cstring): cint
  {.importc: "strcmp", header: "<string.h>", raises: [], gcsafe.}

proc currentThreadId(): int {.inline.} =
  ## id текущего потока. Нужен только для thread-check.
  getThreadId()

const
  ## Те же id, что у plugin-side расширений, — так устроен CLAP.
  ClapExtParams* = cstring"clap.params"
  ClapExtState* = cstring"clap.state"
  ClapExtThreadCheck* = cstring"clap.thread-check"
  ClapExtLatency* = cstring"clap.latency"
  ClapExtGui* = cstring"clap.gui"

  ClapParamRescanValues* = 1'u32 shl 0
  ClapParamRescanText* = 1'u32 shl 1
  ClapParamRescanInfo* = 1'u32 shl 2
  ClapParamRescanAll* = 1'u32 shl 3

  ClapParamClearAll* = 1'u32 shl 0
  ClapParamClearAutomations* = 1'u32 shl 1
  ClapParamClearModulations* = 1'u32 shl 2

  NoThreadId = -1

type
  ClapHostParamsExt* {.bycopy.} = object
    rescan*: proc(host: ptr ClapHost; flags: uint32)
      {.cdecl, raises: [], gcsafe.}
    clear*: proc(host: ptr ClapHost; paramId: uint32; flags: uint32)
      {.cdecl, raises: [], gcsafe.}
    requestFlush*: proc(host: ptr ClapHost)
      {.cdecl, raises: [], gcsafe.}

  ClapHostStateExt* {.bycopy.} = object
    markDirty*: proc(host: ptr ClapHost)
      {.cdecl, raises: [], gcsafe.}

  ClapHostThreadCheckExt* {.bycopy.} = object
    isMainThread*: proc(host: ptr ClapHost): bool
      {.cdecl, raises: [], gcsafe.}
    isAudioThread*: proc(host: ptr ClapHost): bool
      {.cdecl, raises: [], gcsafe.}

  ClapHostLatencyExt* {.bycopy.} = object
    changed*: proc(host: ptr ClapHost)
      {.cdecl, raises: [], gcsafe.}

  ClapHostGuiExt* {.bycopy.} = object
    resizeHintsChanged*: proc(host: ptr ClapHost)
      {.cdecl, raises: [], gcsafe.}
    requestResize*: proc(host: ptr ClapHost; width: uint32; height: uint32): bool
      {.cdecl, raises: [], gcsafe.}
    requestShow*: proc(host: ptr ClapHost): bool
      {.cdecl, raises: [], gcsafe.}
    requestHide*: proc(host: ptr ClapHost): bool
      {.cdecl, raises: [], gcsafe.}
    closed*: proc(host: ptr ClapHost; wasDestroyed: bool)
      {.cdecl, raises: [], gcsafe.}

  ClapHostContext* = object
    ## Состояние host-side. Живёт в shared-куче; указатель лежит в
    ## `ClapHost.hostData`. Все счётчики пишутся из тех потоков, откуда
    ## плагин зовёт хост, и читаются main-loop'ом.
    mainThreadId: Atomic[int]
    audioThreadId: Atomic[int]

    restartRequested: Atomic[int]
    processRequested: Atomic[int]
    callbackRequests: Atomic[int]
    callbacksDrained: Atomic[int]

    flushRequested: Atomic[int]
    rescanFlags: Atomic[uint32]
    clearFlags: Atomic[uint32]
    clearedParam: Atomic[int]

    stateDirty: Atomic[int]
    latencyChanged: Atomic[int]

    guiResizeHintsChanged: Atomic[int]
    guiResizeW: Atomic[int]
    guiResizeH: Atomic[int]
    guiShow: Atomic[int]
    guiHide: Atomic[int]
    guiClosed: Atomic[int]
    guiClosedDestroyed: Atomic[int]

    paramsExt: ClapHostParamsExt
    stateExt: ClapHostStateExt
    threadCheckExt: ClapHostThreadCheckExt
    latencyExt: ClapHostLatencyExt
    guiExt: ClapHostGuiExt

proc ctxOf(host: ptr ClapHost): ptr ClapHostContext {.inline.} =
  if host.isNil or host.hostData.isNil:
    return nil
  cast[ptr ClapHostContext](host.hostData)

# ABI-guard: число полей каждого host-расширения обязано совпадать с
# официальным заголовком CLAP. Сравниваем через размер указателя
# (1 поле == sizeof(ClapHostStateExt)), чтобы проверка работала и на
# 32-битных платформах.
static:
  doAssert sizeof(ClapHostParamsExt) == 3 * sizeof(pointer)
  doAssert sizeof(ClapHostStateExt) == 1 * sizeof(pointer)
  doAssert sizeof(ClapHostThreadCheckExt) == 2 * sizeof(pointer)
  doAssert sizeof(ClapHostLatencyExt) == 1 * sizeof(pointer)
  doAssert sizeof(ClapHostGuiExt) == 5 * sizeof(pointer)

# ----------------------------------------------------------------------------
# clap.params
# ----------------------------------------------------------------------------

proc paramsRescan(host: ptr ClapHost; flags: uint32)
    {.cdecl, raises: [], gcsafe.} =
  let c = ctxOf(host)
  if not c.isNil:
    discard c.rescanFlags.fetchOr(flags, moRelaxed)

proc paramsClear(host: ptr ClapHost; paramId: uint32; flags: uint32)
    {.cdecl, raises: [], gcsafe.} =
  let c = ctxOf(host)
  if not c.isNil:
    discard c.clearFlags.fetchOr(flags, moRelaxed)
    c.clearedParam.store(int(paramId), moRelaxed)

proc paramsRequestFlush(host: ptr ClapHost) {.cdecl, raises: [], gcsafe.} =
  let c = ctxOf(host)
  if not c.isNil:
    discard c.flushRequested.fetchAdd(1, moRelaxed)

# ----------------------------------------------------------------------------
# clap.state
# ----------------------------------------------------------------------------

proc stateMarkDirty(host: ptr ClapHost) {.cdecl, raises: [], gcsafe.} =
  let c = ctxOf(host)
  if not c.isNil:
    discard c.stateDirty.fetchAdd(1, moRelaxed)

# ----------------------------------------------------------------------------
# clap.thread-check
# ----------------------------------------------------------------------------

proc threadCheckIsMain(host: ptr ClapHost): bool
    {.cdecl, raises: [], gcsafe.} =
  let c = ctxOf(host)
  if c.isNil:
    return false
  c.mainThreadId.load(moRelaxed) == currentThreadId()

proc threadCheckIsAudio(host: ptr ClapHost): bool
    {.cdecl, raises: [], gcsafe.} =
  let c = ctxOf(host)
  if c.isNil:
    return false
  let audio = c.audioThreadId.load(moRelaxed)
  if audio == NoThreadId:
    return false
  audio == currentThreadId()

# ----------------------------------------------------------------------------
# clap.latency
# ----------------------------------------------------------------------------

proc latencyChanged(host: ptr ClapHost) {.cdecl, raises: [], gcsafe.} =
  let c = ctxOf(host)
  if not c.isNil:
    discard c.latencyChanged.fetchAdd(1, moRelaxed)

# ----------------------------------------------------------------------------
# clap.gui
# ----------------------------------------------------------------------------

proc guiResizeHintsChanged(host: ptr ClapHost)
    {.cdecl, raises: [], gcsafe.} =
  let c = ctxOf(host)
  if not c.isNil:
    discard c.guiResizeHintsChanged.fetchAdd(1, moRelaxed)

proc guiRequestResize(host: ptr ClapHost; width: uint32; height: uint32): bool
    {.cdecl, raises: [], gcsafe.} =
  let c = ctxOf(host)
  if c.isNil:
    return false
  c.guiResizeW.store(int(width), moRelaxed)
  c.guiResizeH.store(int(height), moRelaxed)
  true

proc guiRequestShow(host: ptr ClapHost): bool
    {.cdecl, raises: [], gcsafe.} =
  let c = ctxOf(host)
  if c.isNil:
    return false
  discard c.guiShow.fetchAdd(1, moRelaxed)
  true

proc guiRequestHide(host: ptr ClapHost): bool
    {.cdecl, raises: [], gcsafe.} =
  let c = ctxOf(host)
  if c.isNil:
    return false
  discard c.guiHide.fetchAdd(1, moRelaxed)
  true

proc guiClosed(host: ptr ClapHost; wasDestroyed: bool)
    {.cdecl, raises: [], gcsafe.} =
  let c = ctxOf(host)
  if not c.isNil:
    discard c.guiClosed.fetchAdd(1, moRelaxed)
    if wasDestroyed:
      discard c.guiClosedDestroyed.fetchAdd(1, moRelaxed)

# ----------------------------------------------------------------------------
# clap_host.get_extension + request-колбэки
# ----------------------------------------------------------------------------

proc clapHostGetExtension(host: ptr ClapHost; extensionId: cstring): pointer
    {.cdecl, raises: [], gcsafe.} =
  ## Без аллокаций: id приходят как cstring и сравниваются strcmp.
  let c = ctxOf(host)
  if c.isNil or extensionId.isNil:
    return nil
  if strcmp(extensionId, ClapExtParams) == 0:
    return cast[pointer](addr c.paramsExt)
  if strcmp(extensionId, ClapExtState) == 0:
    return cast[pointer](addr c.stateExt)
  if strcmp(extensionId, ClapExtThreadCheck) == 0:
    return cast[pointer](addr c.threadCheckExt)
  if strcmp(extensionId, ClapExtLatency) == 0:
    return cast[pointer](addr c.latencyExt)
  if strcmp(extensionId, ClapExtGui) == 0:
    return cast[pointer](addr c.guiExt)
  nil

proc clapHostRequestRestart(host: ptr ClapHost) {.cdecl, raises: [], gcsafe.} =
  let c = ctxOf(host)
  if not c.isNil:
    discard c.restartRequested.fetchAdd(1, moRelaxed)

proc clapHostRequestProcess(host: ptr ClapHost) {.cdecl, raises: [], gcsafe.} =
  let c = ctxOf(host)
  if not c.isNil:
    discard c.processRequested.fetchAdd(1, moRelaxed)

proc clapHostRequestCallback(host: ptr ClapHost) {.cdecl, raises: [], gcsafe.} =
  let c = ctxOf(host)
  if not c.isNil:
    discard c.callbackRequests.fetchAdd(1, moRelaxed)

# ----------------------------------------------------------------------------
# Жизненный цикл контекста (control-path)
# ----------------------------------------------------------------------------

proc newClapHostContext*(): ptr ClapHostContext =
  ## Создаёт host-side состояние и заполняет таблицы расширений.
  ## Текущий поток считается main-потоком (thread-check).
  result = createShared(ClapHostContext)
  if result.isNil:
    return nil

  result.mainThreadId.store(currentThreadId(), moRelaxed)
  result.audioThreadId.store(NoThreadId, moRelaxed)

  result.paramsExt.rescan = paramsRescan
  result.paramsExt.clear = paramsClear
  result.paramsExt.requestFlush = paramsRequestFlush

  result.stateExt.markDirty = stateMarkDirty

  result.threadCheckExt.isMainThread = threadCheckIsMain
  result.threadCheckExt.isAudioThread = threadCheckIsAudio

  result.latencyExt.changed = latencyChanged

  result.guiExt.resizeHintsChanged = guiResizeHintsChanged
  result.guiExt.requestResize = guiRequestResize
  result.guiExt.requestShow = guiRequestShow
  result.guiExt.requestHide = guiRequestHide
  result.guiExt.closed = guiClosed

proc freeClapHostContext*(c: ptr ClapHostContext) =
  if not c.isNil:
    deallocShared(c)

proc installClapHostExtensions*(host: var ClapHost; c: ptr ClapHostContext) =
  ## Вешает расширения на clap_host. Заменяет заглушки из `initHost`.
  host.hostData = cast[pointer](c)
  host.getExtension = clapHostGetExtension
  host.requestRestart = clapHostRequestRestart
  host.requestProcess = clapHostRequestProcess
  host.requestCallback = clapHostRequestCallback

proc markMainThread*(c: ptr ClapHostContext) =
  if not c.isNil:
    c.mainThreadId.store(currentThreadId(), moRelaxed)

proc markAudioThread*(c: ptr ClapHostContext) =
  ## Адаптер зовёт это из первого вызова process: только там известно,
  ## какой поток является аудио-потоком.
  if not c.isNil:
    c.audioThreadId.store(currentThreadId(), moRelaxed)

proc isMainThreadNow*(c: ptr ClapHostContext): bool =
  if c.isNil: false else: c.mainThreadId.load(moRelaxed) == currentThreadId()

proc isAudioThreadNow*(c: ptr ClapHostContext): bool =
  if c.isNil:
    return false
  let audio = c.audioThreadId.load(moRelaxed)
  audio != NoThreadId and audio == currentThreadId()

# ----------------------------------------------------------------------------
# Забор запросов main-loop'ом (control-path)
# ----------------------------------------------------------------------------

proc takeCallbackRequests*(c: ptr ClapHostContext): int =
  ## Сколько раз плагин просил callback; сбрасывает счётчик. Адаптер
  ## вызывает `plugin.onMainThread()` ровно столько раз.
  if c.isNil:
    return 0
  let n = c.callbackRequests.exchange(0, moAcquireRelease)
  if n > 0:
    discard c.callbacksDrained.fetchAdd(n, moRelaxed)
  n

proc drainedCallbacksOf*(c: ptr ClapHostContext): int =
  if c.isNil: 0 else: c.callbacksDrained.load(moRelaxed)

proc takeRestartRequest*(c: ptr ClapHostContext): bool =
  if c.isNil: false else: c.restartRequested.exchange(0, moAcquireRelease) > 0

proc takeProcessRequest*(c: ptr ClapHostContext): bool =
  if c.isNil: false else: c.processRequested.exchange(0, moAcquireRelease) > 0

proc takeFlushRequest*(c: ptr ClapHostContext): bool =
  if c.isNil: false else: c.flushRequested.exchange(0, moAcquireRelease) > 0

proc takeRescanFlags*(c: ptr ClapHostContext): uint32 =
  if c.isNil: 0'u32 else: c.rescanFlags.exchange(0'u32, moAcquireRelease)

proc rescanFlagsOf*(c: ptr ClapHostContext): uint32 =
  if c.isNil: 0'u32 else: c.rescanFlags.load(moRelaxed)

proc clearFlagsOf*(c: ptr ClapHostContext): uint32 =
  if c.isNil: 0'u32 else: c.clearFlags.load(moRelaxed)

proc clearedParamOf*(c: ptr ClapHostContext): int32 =
  if c.isNil: 0'i32 else: int32(c.clearedParam.load(moRelaxed))

proc takeStateDirty*(c: ptr ClapHostContext): bool =
  if c.isNil: false else: c.stateDirty.exchange(0, moAcquireRelease) > 0

proc takeLatencyChanged*(c: ptr ClapHostContext): bool =
  if c.isNil: false else: c.latencyChanged.exchange(0, moAcquireRelease) > 0

proc takeGuiResizeHintsChanged*(c: ptr ClapHostContext): bool =
  if c.isNil: false else: c.guiResizeHintsChanged.exchange(0, moAcquireRelease) > 0

proc guiResizeOf*(c: ptr ClapHostContext): tuple[w, h: uint32] =
  if c.isNil: (0'u32, 0'u32)
  else: (uint32(c.guiResizeW.load(moRelaxed)),
         uint32(c.guiResizeH.load(moRelaxed)))

proc takeGuiShow*(c: ptr ClapHostContext): bool =
  if c.isNil: false else: c.guiShow.exchange(0, moAcquireRelease) > 0

proc takeGuiHide*(c: ptr ClapHostContext): bool =
  if c.isNil: false else: c.guiHide.exchange(0, moAcquireRelease) > 0

proc guiClosedOf*(c: ptr ClapHostContext): tuple[closed, destroyed: int] =
  if c.isNil: (0, 0)
  else: (c.guiClosed.load(moRelaxed), c.guiClosedDestroyed.load(moRelaxed))

{.pop.}

