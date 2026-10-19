# cli/session_ipc.nim
#
# IPC headless runtime-сессии (issue #407): Unix-domain socket + JSON-конверт.
#
# Разделение ответственности:
#   * `core/runtime_session` — ЧТО делает сессия (движок, транспорт, команды);
#   * этот модуль — КАК клиент и демон разговаривают (сокет, путь, состояние
#     на диске).
#
# Почему Unix-socket, а не TCP: сессия локальна для пользователя и машины,
# а файл сокета — естественный «адрес» с правами доступа 0600. Порт был бы
# доступен всей сети и требовал бы отдельной аутентификации.
#
# Файл состояния (`<проект>.session.json`) — небольшой JSON с pid, путём к
# сокету и параметрами сессии. Он нужен клиенту, чтобы НАЙТИ сокет, и
# `session status`, чтобы показать, что запущено. Источник истины о том,
# жива ли сессия, — `ping` по сокету, а не файл: процесс мог умереть, файл
# остался.

import std/[json, os, strutils]

when defined(posix):
  import std/posix
else:
  type SocketHandle* = distinct int

import runtime_session

const
  SessionSchema* = "euterpia.session.v1"
    ## Версия файла состояния сессии. Меняется только при несовместимом
    ## изменении полей.
  SessionStateSuffix = ".session.json"
  MaxRpcBytes* = 64 * 1024
  DefaultRpcTimeoutMs* = 2000

type
  SessionPaths* = object
    statePath*: string
    socketPath*: string
    projectPath*: string

  SessionInfo* = object
    found*: bool
      ## Файл состояния существует (даже если процесс уже умер).
    running*: bool
      ## Ping по сокету прошёл: демон жив.
    pid*: int
    statePath*: string
    socketPath*: string
    projectPath*: string
    sampleRate*: float32
    blockSize*: int32
    state*: JsonNode
      ## Последний ответ `transport.state` (если сессия жива).

  RpcResult* = object
    ok*: bool
    response*: JsonNode
    error*: string

proc fnv1a(s: string): uint32 =
  result = 2166136261'u32
  for c in s:
    result = (result xor uint32(ord(c))) * 16777619'u32

proc sessionBase(projectPath: string): string =
  ## Абсолютный путь проекта (или cwd), по которому считается адрес сессии.
  ## Один проект — одна сессия; разные проекты не мешают друг другу.
  if projectPath.len > 0: absolutePath(projectPath)
  else: getCurrentDir()

proc sessionPaths*(projectPath: string): SessionPaths =
  let base = sessionBase(projectPath)
  result.projectPath = base
  if projectPath.len > 0:
    result.statePath = base & SessionStateSuffix
  else:
    result.statePath = base / ".euterpia.session.json"
  # Путь сокета ограничен `sun_path` (108 байт). Длинный путь проекта в
  # `/tmp` не поместится, поэтому адрес — хэш, а не сам путь.
  when defined(posix):
    let uid = int(getuid())
    result.socketPath = "/tmp/euterpia-session-" & $uid & "-" &
                        toHex(fnv1a(base), 8).toLowerAscii & ".sock"
  else:
    result.socketPath = getTempDir() / ("euterpia-session-" &
                        toHex(fnv1a(base), 8).toLowerAscii & ".sock")

when defined(posix):
  proc sockAddr(path: string; sa: var Sockaddr_un): bool =
    if path.len == 0 or path.len >= Sockaddr_un_path_length:
      return false
    sa = Sockaddr_un()
    sa.sun_family = TSa_Family(AF_UNIX)
    for i in 0 ..< path.len:
      sa.sun_path[i] = path[i]
    sa.sun_path[path.len] = '\0'
    true

  proc connectUnix(path: string): tuple[fd: SocketHandle; error: string] =
    var sa: Sockaddr_un
    if not sockAddr(path, sa):
      return (SocketHandle(-1), "слишком длинный путь сокета сессии")
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd == SocketHandle(-1):
      return (SocketHandle(-1), "не удалось создать сокет")
    if connect(fd, cast[ptr SockAddr](addr sa), SockLen(sizeof(sa))) != 0:
      discard close(fd)
      return (SocketHandle(-1), "сессия не запущена")
    (fd, "")

  proc sendAll(fd: SocketHandle; data: string): bool =
    var sent = 0
    while sent < data.len:
      let n = send(fd, unsafeAddr data[sent], data.len - sent, 0)
      if n <= 0:
        return false
      sent += n
    true

  proc waitReadable(fd: SocketHandle; timeoutMs: int): bool =
    var pfd = TPollfd(fd: cint(fd), events: POLLIN, revents: 0)
    let r = poll(addr pfd, 1, timeoutMs.cint)
    r > 0 and (pfd.revents and POLLIN) != 0

  proc recvLine(fd: SocketHandle; timeoutMs: int): tuple[line: string; error: string] =
    var buffer: array[4096, char]
    var acc = ""
    while acc.len < MaxRpcBytes:
      if not waitReadable(fd, timeoutMs):
        return ("", "сессия не ответила за " & $timeoutMs & " мс")
      let n = recv(fd, addr buffer[0], buffer.len, 0)
      if n <= 0:
        break
      for i in 0 ..< n:
        if buffer[i] == '\n':
          return (acc, "")
        acc.add buffer[i]
    if acc.len == 0:
      return ("", "пустой ответ сессии")
    (acc, "")

  proc rpcCall*(socketPath: string; request: JsonNode;
                timeoutMs: int = DefaultRpcTimeoutMs): RpcResult =
    ## Один запрос/ответ к демону сессии.
    let (fd, connError) = connectUnix(socketPath)
    if fd == SocketHandle(-1):
      return RpcResult(ok: false, error: connError)
    defer: discard close(fd)

    if not sendAll(fd, $request & "\n"):
      return RpcResult(ok: false, error: "не удалось отправить запрос сессии")

    let (line, recvError) = recvLine(fd, timeoutMs)
    if recvError.len > 0:
      return RpcResult(ok: false, error: recvError)

    try:
      result.response = parseJson(line)
    except CatchableError:
      return RpcResult(ok: false, error: "ответ сессии — не JSON")
    result.ok = result.response{"ok"}.getBool(false)
    if not result.ok:
      result.error = result.response{"error"}.getStr("сессия отклонила команду")

  proc listenUnix*(path: string): tuple[fd: SocketHandle; error: string] =
    ## Создать слушающий сокет демона. Старый файл удаляется: после падения
    ## процесса он остаётся и без unlink `bind` вернул бы EADDRINUSE.
    discard unlink(path.cstring)
    var sa: Sockaddr_un
    if not sockAddr(path, sa):
      return (SocketHandle(-1), "слишком длинный путь сокета сессии")
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd == SocketHandle(-1):
      return (SocketHandle(-1), "не удалось создать сокет")
    if bindSocket(fd, cast[ptr SockAddr](addr sa), SockLen(sizeof(sa))) != 0:
      discard close(fd)
      return (SocketHandle(-1), "не удалось занять сокет сессии: " & path)
    discard chmod(path.cstring, Mode(0o600))
    if listen(fd, 8) != 0:
      discard close(fd)
      return (SocketHandle(-1), "не удалось слушать сокет сессии")
    (fd, "")

  proc acceptClient*(listenFd: SocketHandle; timeoutMs: int): SocketHandle =
    ## Принять соединение или вернуть -1 по таймауту. Таймаут нужен, чтобы
    ## демон успевал продвигать транспорт (`tickRuntimeSession`).
    var pfd = TPollfd(fd: cint(listenFd), events: POLLIN, revents: 0)
    let r = poll(addr pfd, 1, timeoutMs.cint)
    if r <= 0 or (pfd.revents and POLLIN) == 0:
      return SocketHandle(-1)
    accept(listenFd, nil, nil)

  proc readRequest*(fd: SocketHandle; timeoutMs: int): tuple[request: JsonNode;
                                                              error: string] =
    let (line, err) = recvLine(fd, timeoutMs)
    if err.len > 0:
      return (nil, err)
    try:
      result.request = parseJson(line)
    except CatchableError:
      return (nil, "запрос — не JSON")

  proc writeResponse*(fd: SocketHandle; response: JsonNode): bool =
    sendAll(fd, $response & "\n")

else:
  proc rpcCall*(socketPath: string; request: JsonNode;
                timeoutMs: int = DefaultRpcTimeoutMs): RpcResult =
    ## Windows: runtime-сессия требует Unix-domain socket (#407).
    discard socketPath
    discard request
    discard timeoutMs
    RpcResult(ok: false, error: "runtime-сессия поддерживается только на POSIX")

  proc listenUnix*(path: string): tuple[fd: SocketHandle; error: string] =
    (SocketHandle(-1), "runtime-сессия поддерживается только на POSIX")

  proc acceptClient*(listenFd: SocketHandle; timeoutMs: int): SocketHandle =
    discard listenFd
    discard timeoutMs
    SocketHandle(-1)

  proc readRequest*(fd: SocketHandle; timeoutMs: int): tuple[request: JsonNode;
                                                              error: string] =
    discard fd
    discard timeoutMs
    (nil, "runtime-сессия поддерживается только на POSIX")

  proc writeResponse*(fd: SocketHandle; response: JsonNode): bool =
    discard fd
    discard response
    false

# =============================================================================
# Файл состояния: адрес сокета и параметры сессии
# =============================================================================

proc offlineTransportPath*(projectPath: string): string =
  ## Путь offline-сессии транспорта (`<проект>.transport.json`). Один и тот
  ## же для `transport` и для `session stop`: остановка сессии записывает
  ## финальное состояние, чтобы следующий `transport state` не показывал
  ## устаревшее «играет».
  if projectPath.len > 0:
    absolutePath(projectPath) & ".transport.json"
  else:
    getCurrentDir() / ".euterpia.transport.json"

proc saveOfflineSnapshot*(projectPath: string; snapshot: JsonNode): bool =
  ## Записать рантайм-срез в offline-сессию. `false` — I/O-ошибка; live-
  ## команда от этого не отменяется (сессия уже применила её).
  if snapshot == nil or snapshot.kind != JObject:
    return false
  try:
    writeFile(offlineTransportPath(projectPath), pretty(snapshot))
    true
  except CatchableError:
    false

proc saveSessionInfo*(paths: SessionPaths; pid: int; sampleRate: float32;
                      blockSize: int32) =
  ## Записать файл состояния. Только cold path (start/status).
  let node = %*{
    "schema": SessionSchema,
    "pid": pid,
    "socket": paths.socketPath,
    "project": paths.projectPath,
    "sampleRate": sampleRate,
    "blockSize": blockSize,
  }
  writeFile(paths.statePath, pretty(node))

proc removeSessionInfo*(paths: SessionPaths) =
  ## Убрать файл состояния и сокет. Идемпотентно.
  try:
    if fileExists(paths.statePath):
      removeFile(paths.statePath)
  except CatchableError:
    discard
  when defined(posix):
    discard unlink(paths.socketPath.cstring)
  else:
    if fileExists(paths.socketPath):
      removeFile(paths.socketPath)

proc loadSessionInfo*(projectPath: string;
                      timeoutMs: int = 300): SessionInfo =
  ## Прочитать файл состояния и проверить, жив ли демон (`ping`).
  ##
  ## `found == true, running == false` — «файл есть, процесса нет»: это
  ## нормальное состояние после падения, а не ошибка чтения. Клиент может
  ## удалить файл и запустить сессию заново.
  let paths = sessionPaths(projectPath)
  result.socketPath = paths.socketPath
  result.projectPath = paths.projectPath
  result.statePath = paths.statePath

  if not fileExists(paths.statePath):
    return

  try:
    let node = parseJson(readFile(paths.statePath))
    if node{"schema"}.getStr("") != SessionSchema:
      return
    result.found = true
    result.pid = node{"pid"}.getInt(0)
    result.socketPath = node{"socket"}.getStr(paths.socketPath)
    result.projectPath = node{"project"}.getStr(paths.projectPath)
    result.sampleRate = float32(node{"sampleRate"}.getFloat(48000.0))
    result.blockSize = int32(node{"blockSize"}.getInt(512))
  except CatchableError:
    result.found = false
    return

  let ping = rpcCall(result.socketPath,
                     %*{"api": RuntimeSessionApiVersion, "command": "ping"},
                     timeoutMs)
  if ping.ok:
    result.running = true
    result.state = ping.response{"state"}
