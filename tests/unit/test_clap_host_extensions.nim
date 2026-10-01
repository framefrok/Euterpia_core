# tests/unit/test_clap_host_extensions.nim
#
# Host-side расширения CLAP (issue #6).
#
# Тест НЕ требует реального плагина: проверяются сами расширения, которые
# плагин вызывает у хоста через clap_host.get_extension(). Это ровно то,
# что раньше было заглушками (`getExtension -> nil`,
# `requestCallback -> discard`), из-за чего список параметров в UI
# «замерзал», состояние плагина нельзя было пометить грязным, а GUI не
# перерисовывался.
#
# Что проверяется:
#   1. все host-расширения отдаются по своим id, чужие id — nil;
#   2. thread-check действительно различает потоки;
#   3. params/state/latency/gui выставляют наблюдаемые флаги;
#   4. request_restart/process/callback только ставят флаг (в audio-потоке
#      не должно быть работы), а main-loop их забирает;
#   5. nil-safe: без контекста вызовы не падают.

import std/[unittest, typedthreads]
import clap_host
import clap_host_extensions

type
  ThreadProbe = object
    host: ptr ClapHost
    tc: ptr ClapHostThreadCheckExt
    ctx: ptr ClapHostContext
    mainSeen: bool
    audioSeen: bool
    audioAfterMark: bool
    mainAfterMark: bool

proc threadProbeWorker(p: pointer) {.thread, gcsafe.} =
  let pr = cast[ptr ThreadProbe](p)
  pr.mainSeen = pr.tc.isMainThread(pr.host)
  pr.audioSeen = pr.tc.isAudioThread(pr.host)
  markAudioThread(pr.ctx)
  pr.audioAfterMark = pr.tc.isAudioThread(pr.host)
  pr.mainAfterMark = pr.tc.isMainThread(pr.host)

suite "clap host extensions (#6)":

  test "get_extension: все host-расширения по своим id, чужие — nil":
    let ctx = newClapHostContext()
    check ctx != nil

    var host: ClapHost
    initHost(host)
    installClapHostExtensions(host, ctx)

    check host.getExtension(addr host, ClapExtParams) != nil
    check host.getExtension(addr host, ClapExtState) != nil
    check host.getExtension(addr host, ClapExtThreadCheck) != nil
    check host.getExtension(addr host, ClapExtLatency) != nil
    check host.getExtension(addr host, ClapExtGui) != nil

    check host.getExtension(addr host, cstring"clap.unknown") == nil

    freeClapHostContext(ctx)

  test "thread-check различает main- и audio-поток":
    let ctx = newClapHostContext()
    var host: ClapHost
    initHost(host)
    installClapHostExtensions(host, ctx)

    let tc = cast[ptr ClapHostThreadCheckExt](
      host.getExtension(addr host, ClapExtThreadCheck))
    check tc != nil

    # Контекст создан в этом потоке => он main.
    check tc.isMainThread(addr host)
    check tc.isAudioThread(addr host) == false

    var probe = ThreadProbe(host: addr host, tc: tc, ctx: ctx)
    var th: Thread[pointer]
    createThread(th, threadProbeWorker, addr probe)
    joinThread(th)

    check probe.mainSeen == false        # рабочий поток — не main
    check probe.audioSeen == false       # до markAudioThread — не audio
    check probe.audioAfterMark == true   # после mark — он audio
    check probe.mainAfterMark == false
    # В main-потоке по-прежнему истинно только is_main_thread.
    check tc.isMainThread(addr host)
    check tc.isAudioThread(addr host) == false

    freeClapHostContext(ctx)

  test "clap.params: rescan / clear / request_flush":
    let ctx = newClapHostContext()
    var host: ClapHost
    initHost(host)
    installClapHostExtensions(host, ctx)

    let pe = cast[ptr ClapHostParamsExt](
      host.getExtension(addr host, ClapExtParams))
    check pe != nil

    pe.rescan(addr host, ClapParamRescanValues or ClapParamRescanInfo)
    check rescanFlagsOf(ctx) == (ClapParamRescanValues or ClapParamRescanInfo)
    # Повторный rescan накапливает флаги (то, что ждёт main-loop как одну
    # перестройку списка параметров).
    pe.rescan(addr host, ClapParamRescanText)
    check takeRescanFlags(ctx) ==
      (ClapParamRescanValues or ClapParamRescanInfo or ClapParamRescanText)
    check takeRescanFlags(ctx) == 0'u32

    pe.clear(addr host, 42'u32, ClapParamClearAll)
    check clearedParamOf(ctx) == 42'i32
    check clearFlagsOf(ctx) == ClapParamClearAll

    check takeFlushRequest(ctx) == false
    pe.requestFlush(addr host)
    check takeFlushRequest(ctx) == true
    check takeFlushRequest(ctx) == false

    freeClapHostContext(ctx)

  test "clap.state / clap.latency / clap.gui":
    let ctx = newClapHostContext()
    var host: ClapHost
    initHost(host)
    installClapHostExtensions(host, ctx)

    let se = cast[ptr ClapHostStateExt](
      host.getExtension(addr host, ClapExtState))
    check se != nil
    check takeStateDirty(ctx) == false
    se.markDirty(addr host)
    check takeStateDirty(ctx) == true
    check takeStateDirty(ctx) == false

    let le = cast[ptr ClapHostLatencyExt](
      host.getExtension(addr host, ClapExtLatency))
    check le != nil
    le.changed(addr host)
    check takeLatencyChanged(ctx) == true

    let ge = cast[ptr ClapHostGuiExt](
      host.getExtension(addr host, ClapExtGui))
    check ge != nil

    ge.resizeHintsChanged(addr host)
    check takeGuiResizeHintsChanged(ctx) == true

    check ge.requestResize(addr host, 800'u32, 600'u32) == true
    let (w, h) = guiResizeOf(ctx)
    check w == 800'u32
    check h == 600'u32

    check ge.requestShow(addr host) == true
    check takeGuiShow(ctx) == true
    check ge.requestHide(addr host) == true
    check takeGuiHide(ctx) == true

    ge.closed(addr host, true)
    let closedState = guiClosedOf(ctx)
    check closedState.closed == 1
    check closedState.destroyed == 1

    freeClapHostContext(ctx)

  test "request_restart / request_process / request_callback — только флаги":
    let ctx = newClapHostContext()
    var host: ClapHost
    initHost(host)
    installClapHostExtensions(host, ctx)

    host.requestCallback(addr host)
    host.requestCallback(addr host)
    host.requestCallback(addr host)
    # main-loop забирает пачку одним вызовом
    check takeCallbackRequests(ctx) == 3
    check takeCallbackRequests(ctx) == 0
    check drainedCallbacksOf(ctx) == 3

    host.requestRestart(addr host)
    check takeRestartRequest(ctx) == true
    check takeRestartRequest(ctx) == false

    host.requestProcess(addr host)
    check takeProcessRequest(ctx) == true
    check takeProcessRequest(ctx) == false

    freeClapHostContext(ctx)

  test "nil-safe: без контекста вызовы не падают":
    # Заглушки из initHost (hostData == nil).
    var bare: ClapHost
    initHost(bare)
    check bare.getExtension(addr bare, ClapExtParams) == nil
    bare.requestCallback(addr bare)
    bare.requestRestart(addr bare)
    bare.requestProcess(addr bare)

    # Наши callback'и, но контекста нет.
    var host: ClapHost
    initHost(host)
    installClapHostExtensions(host, nil)
    check host.getExtension(addr host, ClapExtParams) == nil
    host.requestCallback(addr host)
    host.requestRestart(addr host)

    # Accessors на nil-контексте.
    check takeCallbackRequests(nil) == 0
    check takeRestartRequest(nil) == false
    check takeProcessRequest(nil) == false
    check takeFlushRequest(nil) == false
    check takeRescanFlags(nil) == 0'u32
    check takeStateDirty(nil) == false
    check takeLatencyChanged(nil) == false
    check takeGuiShow(nil) == false
    check guiResizeOf(nil) == (0'u32, 0'u32)
    check isMainThreadNow(nil) == false
    check isAudioThreadNow(nil) == false
    freeClapHostContext(nil)
