# cli/cmd_session.nim
#
# `euterpia session <start|stop|status>` — headless runtime-сессия (#407).
#
# Зачем: CLI — процесс на одну команду. Пока живёт только offline-сессия
# (файл), `transport play` не может оставить AudioEngine работать. Здесь
# появляется долгоживущий процесс-демон, который владеет движком, а
# `transport play/state/stop` разговаривают с ним по Unix-socket.
#
# Границы:
#   * демон — тот же бинарь CLI: `session start` делает fork, дочерний
#     процесс остаётся владельцем AudioEngine (exec не нужен);
#   * состояние сессии — `core/runtime_session` (движок, команды, время);
#   * IPC и пути — `cli/session_ipc` (сокет, файл состояния);
#   * `session` не трогает документ проекта: темп/размер читаются из него на
#     старте, а меняются командами `transport tempo/meter` (документ) и
#     `engine.tempo/meter` (живой движок).
#
# Коды возврата (#88): 0 — успех, 1 — использование, 2 — среда (сокет,
# права, нет процесса), 3 — внутренняя.

import std/[json, monotimes, os, posix, strutils]

import context
import cli_spec
import cmd_project
import control_bridge
import control/query
import session_ipc
import runtime_session
import project
import autosave

const
  SessionSubcommands* = @["start", "stop", "status"]

  SessionSpec* = CommandSpec(
    name: "session",
    summary: "headless runtime-сессия: запуск, остановка, состояние",
    synopsis: "session <подкоманда> [проект.eproj] [ключи]",
    subcommands: SessionSubcommands,
    args: @[
      arg("<подкоманда>", "start|stop|status"),
      arg("проект.eproj", "проект; без аргумента — `project.eproj`, если он есть"),
    ],
    options: @[
      opt("--file", "проект, если он не задан позиционно", value = "проект.eproj"),
      opt("--sample-rate", "частота сессии, если проекта нет", value = "Гц",
          default = "48000"),
      opt("--block-size", "размер блока движка", value = "кадры",
          default = "512"),
      opt("--timeout", "сколько ждать запуска демона", value = "мс",
          default = "3000"),
      opt("--autosave", "автосохранение проекта раз в N секунд (0 — выключено)",
          value = "секунды", default = "0"),
    ],
    example: "euterpia session start demo.eproj",
    fields: @[
      field("running", "сессия жива (`true`) или нет"),
      field("pid", "pid демона"),
      field("socket", "путь Unix-сокета сессии"),
      field("project", "проект, к которому привязана сессия"),
      field("sampleRate", "частота сессии"),
      field("blockSize", "размер блока"),
      field("state", "состояние транспорта: `stopped`|`playing`|`paused`|`recording`"),
      field("stale", "файл состояния есть, но процесс не отвечает"),
      field("autosaveMs", "период автосохранения демона (0 — выключено)"),
    ],
    notes: @[
      "сессия живёт между вызовами CLI: `transport play` в одном запуске виден `transport state` в другом (#407)",
      "демон владеет AudioEngine; `session stop` уничтожает движок и закрывает сокет",
      "адрес — Unix-socket 0600 в `/tmp`; файл `<проект>.session.json` только указывает на него",
      "без проекта сессия привязана к текущему каталогу и умолчаниям ядра (120 BPM, 4/4, 48 кГц)",
      "`session stop` записывает финальное состояние в offline-сессию транспорта: после остановки `transport state` не врёт",
    ])

type
  SessionScan = object
    ok: bool
    rep: Report
    subcommand: string
    projectPath: string
    sampleRate: float32
    sampleRateExplicit: bool
    blockSize: int32
    timeoutMs: int
    autosaveMs: int64

proc monoMs(): int64 {.inline.} =
  ## Монотонные миллисекунды: по ним считается время сессии, поэтому
  ## системные часы (NTP, ручная правка) не влияют на транспорт.
  getMonoTime().ticks div 1_000_000

proc scanArgs(args: seq[string]): SessionScan =
  result.sampleRate = DefaultSampleRate
  result.blockSize = 512
  result.timeoutMs = 3000
  result.autosaveMs = 0

  var positionals: seq[string] = @[]
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--file":
      inc i
      if i >= args.len:
        return SessionScan(ok: false,
          rep: usageError("--file: нужен путь к проекту"))
      result.projectPath = args[i]
    of "--sample-rate":
      inc i
      if i >= args.len:
        return SessionScan(ok: false,
          rep: usageError("--sample-rate: нужно значение в Гц"))
      try:
        let sr = parseFloat(args[i])
        if sr <= 0.0 or sr > MaxSampleRate:
          return SessionScan(ok: false,
            rep: usageError("--sample-rate: ожидается положительное число Гц"))
        result.sampleRate = float32(sr)
        result.sampleRateExplicit = true
      except ValueError:
        return SessionScan(ok: false,
          rep: usageError("--sample-rate: ожидается число, получено «" &
                          args[i] & "»"))
    of "--block-size":
      inc i
      if i >= args.len:
        return SessionScan(ok: false,
          rep: usageError("--block-size: нужно число кадров"))
      try:
        let bs = parseInt(args[i])
        if bs <= 0 or bs > 4096:
          return SessionScan(ok: false,
            rep: usageError("--block-size: диапазон 1..4096 кадров"))
        result.blockSize = int32(bs)
      except ValueError:
        return SessionScan(ok: false,
          rep: usageError("--block-size: ожидается целое, получено «" &
                          args[i] & "»"))
    of "--autosave":
      inc i
      if i >= args.len:
        return SessionScan(ok: false,
          rep: usageError("--autosave: нужно значение в секундах"))
      try:
        let seconds = parseInt(args[i])
        if seconds < 0 or seconds > 86_400:
          return SessionScan(ok: false,
            rep: usageError("--autosave: допустимо 0…86400 секунд"))
        result.autosaveMs = int64(seconds) * 1000
      except ValueError:
        return SessionScan(ok: false,
          rep: usageError("--autosave: ожидается целое число секунд"))
    of "--timeout":
      inc i
      if i >= args.len:
        return SessionScan(ok: false,
          rep: usageError("--timeout: нужно значение в мс"))
      try:
        result.timeoutMs = parseInt(args[i])
        if result.timeoutMs < 100:
          result.timeoutMs = 100
      except ValueError:
        return SessionScan(ok: false,
          rep: usageError("--timeout: ожидается целое, получено «" &
                          args[i] & "»"))
    else:
      if a.len > 1 and a[0] == '-':
        return SessionScan(ok: false, rep: usageError("неизвестный ключ: " & a))
      positionals.add a
    inc i

  if positionals.len == 0:
    return SessionScan(ok: false, rep: usageError(
      "session: нужна подкоманда",
      "подкоманды: " & SessionSubcommands.join(", ")))

  result.subcommand = positionals[0]
  var tail = positionals[1 .. ^1]
  if result.projectPath.len == 0 and tail.len > 0 and isProjectPath(tail[^1]):
    result.projectPath = tail[^1]
    tail = tail[0 .. ^2]
  if tail.len > 0:
    return SessionScan(ok: false, rep: usageError(
      "session " & result.subcommand & ": лишний аргумент: " & tail[0]))
  result.ok = true


proc sessionBody(info: SessionInfo): JsonNode =
  result = %*{
    "running": info.running,
    "pid": info.pid,
    "socket": info.socketPath,
    "project": info.projectPath,
    "sampleRate": info.sampleRate,
    "blockSize": info.blockSize,
  }
  if info.state != nil and info.state.kind == JObject:
    result["state"] = info.state{"state"}
    result["position"] = info.state{"position"}
    result["tempo"] = info.state{"tempo"}
    result["meter"] = info.state{"meter"}
    result["loop"] = info.state{"loop"}

proc sessionLines(info: SessionInfo): seq[string] =
  if not info.running:
    result.add "сессия не запущена"
    if info.found:
      result.add "найден устаревший файл состояния: " & info.statePath
    return
  result.add "сессия: pid " & $info.pid
  result.add "сокет: " & info.socketPath
  result.add "проект: " & (if info.projectPath.len > 0: info.projectPath
                            else: "(текущий каталог)")
  result.add "частота: " & $int(info.sampleRate) & " Гц, блок: " &
             $info.blockSize
  if info.state != nil:
    result.add "транспорт: " & info.state{"state"}.getStr("unknown")

proc resolveProjectParams(path: string; scan: SessionScan;
                          sampleRate: var float32; tempo: var float64;
                          meterNum, meterDen: var int32): Report =
  ## Параметры сессии: проект (если есть) — источник SR/темпа/размера.
  ## Явный `--sample-rate` сильнее метаданных: это осознанное переопределение.
  result = okReport()
  sampleRate = scan.sampleRate
  tempo = 120.0
  meterNum = 4
  meterDen = 4
  if path.len == 0:
    return
  let loaded = loadAt(path)
  if not loaded.ok:
    return loaded.rep
  let meta = queryMetadata(openDocument(path, loaded.proj))
  if not scan.sampleRateExplicit:
    sampleRate = meta.sampleRate
  tempo = float64(meta.tempo)
  meterNum = meta.tsNumerator
  meterDen = meta.tsDenominator

# =============================================================================
# Демон
# =============================================================================

var gSessionStop {.volatile.}: bool

proc handleSessionSignal(sig: cint) {.noconv.} =
  ## Async-signal-safe: только запись флага, без аллокаций и логов.
  gSessionStop = true

proc daemonMain(paths: SessionPaths; projectPath: string;
                sampleRate: float32; blockSize: int32;
                tempo: float64; meterNum, meterDen: int32;
                autosaveMs: int64): int =
  ## Цикл демона: тик транспорта + обработка одного запроса за итерацию.
  ##
  ## `accept` с таймаутом (20 мс), а не блокирующий: иначе позиция «играет»
  ## стояла бы до прихода клиента.
  var session = initRuntimeSession(sampleRate, blockSize, tempo,
                                  meterNum, meterDen)
  if not session.isActive:
    return 2
  defer: session.closeRuntimeSession()

  # --- автосохранение (issue #110) -----------------------------------------
  # Демон — единственный долгоживущий процесс CLI, поэтому автосохранение
  # имеет смысл именно здесь. Каждый тик перечитываем проект: правки идут
  # другими вызовами CLI (`project set`, `param set`), и снимок должен
  # содержать ИХ, а не состояние на старте. Маркер пишется сразу; штатный
  # `session stop` его снимает, SIGKILL — оставляет для `project recover`.
  var auto: AutoSave
  var autoVersion = 0'u64
  var nextAuto = 0'i64
  if autosaveMs > 0 and projectPath.len > 0 and fileExists(projectPath):
    var policy = defaultAutosavePolicy()
    policy.intervalMs = autosaveMs
    policy.minChanges = 1
    auto = initAutoSave(projectPath, policy)
    nextAuto = monoMs() + autosaveMs
  defer:
    if auto.isActive:
      auto.closeAutoSave(graceful = true)

  let (listenFd, listenError) = listenUnix(paths.socketPath)
  if listenFd == SocketHandle(-1):
    return 2
  defer:
    discard close(listenFd)
    removeSessionInfo(paths)

  saveSessionInfo(paths, int(getpid()), sampleRate, blockSize)
  session.startTimeMs(monoMs())

  gSessionStop = false
  discard signal(SIGTERM, handleSessionSignal)
  discard signal(SIGINT, handleSessionSignal)

  var running = true
  while running and not gSessionStop:
    session.tickRuntimeSession(monoMs())

    if auto.isActive and monoMs() >= nextAuto:
      let loaded = loadProject(projectPath)
      if loaded.success:
        inc autoVersion
        discard auto.submitSnapshot(autoVersion, $loaded.value.toJson,
                                    monoMs())
      nextAuto = monoMs() + autosaveMs

    let client = acceptClient(listenFd, 20)
    if client == SocketHandle(-1):
      continue
    defer: discard close(client)

    let (request, reqError) = readRequest(client, 1000)
    if reqError.len > 0:
      discard writeResponse(client, %*{"ok": false,
        "error": reqError})
      continue

    var stopRequested = false
    var response = session.applyRuntimeCommand(request, stopRequested)
    if response.kind == JObject:
      response["pid"] = %int(getpid())
    discard writeResponse(client, response)
    if stopRequested:
      running = false

  0


# =============================================================================
# Подкоманды
# =============================================================================

proc resolvePath(sc: SessionScan): string =
  result = sc.projectPath
  if result.len == 0 and fileExists(DefaultProjectFile):
    result = DefaultProjectFile

proc runSessionStart(ctx: var Ctx; sc: SessionScan): Report =
  let path = resolvePath(sc)
  var sampleRate: float32
  var tempo: float64
  var meterNum, meterDen: int32
  let params = resolveProjectParams(path, sc, sampleRate, tempo,
                                    meterNum, meterDen)
  if not params.ok:
    return params

  let paths = sessionPaths(path)
  let existing = loadSessionInfo(path)
  if existing.running:
    return okReport(body = sessionBody(existing),
      lines = @["сессия уже запущена", "pid: " & $existing.pid,
                "сокет: " & existing.socketPath])

  # Файл есть, процесса нет — убираем, чтобы не путать `status`.
  if existing.found:
    removeSessionInfo(paths)

  if ctx.dryRun:
    return okReport(body = %*{
        "running": false, "dryRun": true,
        "socket": paths.socketPath, "project": paths.projectPath,
        "sampleRate": sampleRate, "blockSize": sc.blockSize,
        "state": "stopped",
      },
      lines = @["была бы запущена сессия: " & paths.socketPath,
                "проект: " & (if path.len > 0: path else: "(текущий каталог)")])

  when not defined(posix):
    return envError("runtime-сессия поддерживается только на POSIX",
      "Windows/Mac-порт требует отдельного IPC-слоя (issue #407)")
  else:
    # Дочерний процесс не должен унаследовать буферы stdout родителя:
    # иначе его вывод попадёт в захваченный поток теста после выхода CLI.
    flushFile(stdout)
    flushFile(stderr)

    let pid = fork()
    if pid < 0:
      return envError("не удалось запустить демон сессии",
        "fork вернул ошибку: проверьте лимит процессов")

    if pid == 0:
      # --- дочерний процесс: демон -------------------------------------
      discard setsid()
      let devnull = open("/dev/null".cstring, O_RDWR)
      if devnull >= 0:
        discard dup2(devnull, 0)
        discard dup2(devnull, 1)
        discard dup2(devnull, 2)
        if devnull > 2:
          discard close(devnull)
      # Закрыть ВСЕ унаследованные дескрипторы (issue #407). Иначе демон
      # держит открытыми pipe'ы родителя (`startProcess` создаёт их больше,
      # чем 0/1/2), и клиент, читающий вывод `session start`, не получает EOF
      # до остановки демона — тест/скрипт «висит».
      for fd in 3 .. 255:
        discard close(cint(fd))
      let code = daemonMain(paths, path, sampleRate, sc.blockSize,
                            tempo, meterNum, meterDen, sc.autosaveMs)
      quit(code)

    # --- родитель: ждём, пока демон начнёт отвечать --------------------
    let deadline = monoMs() + int64(sc.timeoutMs)
    var started = false
    var childExited = false
    while monoMs() < deadline:
      let ping = rpcCall(paths.socketPath,
                         %*{"api": RuntimeSessionApiVersion,
                            "command": "ping"}, 200)
      if ping.ok:
        started = true
        break
      var status: cint
      if waitpid(Pid(pid), status, WNOHANG) == Pid(pid):
        childExited = true
        break
      sleep(20)

    if not started:
      if not childExited:
        discard kill(Pid(pid), SIGTERM)
      return envError("runtime-сессия не запустилась за " & $sc.timeoutMs & " мс",
        "проверьте права на /tmp и каталог проекта; сокет: " & paths.socketPath)

    let info = loadSessionInfo(path)
    return okReport(body = sessionBody(info),
      lines = @["сессия запущена", "pid: " & $info.pid,
                "сокет: " & info.socketPath,
                "проект: " & (if info.projectPath.len > 0:
                               info.projectPath else: "(текущий каталог)")])

proc runSessionStop(ctx: var Ctx; sc: SessionScan): Report =
  let path = resolvePath(sc)
  let paths = sessionPaths(path)
  let info = loadSessionInfo(path)

  if not info.running:
    if info.found:
      removeSessionInfo(paths)
    return okReport(body = %*{"running": false, "pid": 0,
                              "socket": paths.socketPath,
                              "project": paths.projectPath},
      lines = @["сессия не запущена"])

  if ctx.dryRun:
    return okReport(body = %*{"running": true, "dryRun": true,
                              "pid": info.pid, "socket": info.socketPath},
      lines = @["была бы остановлена сессия: pid " & $info.pid])

  let stopped = rpcCall(info.socketPath,
                        %*{"api": RuntimeSessionApiVersion,
                           "command": "session.stop"}, 2000)
  if not stopped.ok:
    # Демон мог умереть между ping и stop: файл состояния устарел.
    removeSessionInfo(paths)
    return envError("сессия не остановилась: " & stopped.error,
      "устаревшее состояние удалено; запустите `session start` заново")

  # Финальное состояние — в offline-сессию: после остановки `transport state`
  # должен показывать stopped/0, а не последнее «играет».
  discard saveOfflineSnapshot(path, stopped.response{"snapshot"})
  # Даем демону закрыть сокет/файл; повторный remove идемпотентен.
  removeSessionInfo(paths)

  var body = stopped.response{"state"}
  if body == nil or body.kind != JObject:
    body = %*{"state": "stopped"}
  body["running"] = %false
  body["pid"] = %info.pid
  body["socket"] = %info.socketPath
  return okReport(body = body,
    lines = @["сессия остановлена", "pid: " & $info.pid,
              "движок закрыт, offline-сессия обновлена"])

proc runSessionStatus(ctx: var Ctx; sc: SessionScan): Report =
  discard ctx
  let path = resolvePath(sc)
  let info = loadSessionInfo(path)
  var body = sessionBody(info)
  body["stale"] = %(info.found and not info.running)
  return okReport(body = body, lines = sessionLines(info))

proc runSession*(ctx: var Ctx; args: seq[string]): Report =
  let sc = scanArgs(args)
  if not sc.ok:
    return sc.rep
  case sc.subcommand
  of "start": runSessionStart(ctx, sc)
  of "stop": runSessionStop(ctx, sc)
  of "status": runSessionStatus(ctx, sc)
  else:
    usageError("session: неизвестная подкоманда «" & sc.subcommand & "»",
      "подкоманды: " & SessionSubcommands.join(", "))

