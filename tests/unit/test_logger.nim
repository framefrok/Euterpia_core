# tests/unit/test_logger.nim
#
# Logger — единственная точка вывода в Core (issue #14, MANIFEST §6, §43).
#
# Что проверяется:
#   - silent-логгер (sink == nil) реально ничего не пишет — именно это
#     дефолтное состояние не даёт Core «случайно» писать в stdout;
#   - threshold отбрасывает сообщения ниже уровня;
#   - sink получает user-pointer, уровень и текст сообщения;
#   - nil-логгер и nil-sink безопасны (Core зовёт логгер через указатель).
#
# Sink намеренно `{.cdecl, raises: [], gcsafe.}` — как LogSink в Core.
# Чтобы не трогать глобальные переменные из gcsafe-процедуры, счётчики
# живут в shared-памяти, переданной через user-pointer.

import std/[unittest]
import logger

type
  Capture = object
    count: int32
    lastLevel: int32
    bufLen: int32
    buf: array[128, char]

proc sinkProc(user: pointer; level: LogLevel; msg: cstring) {.cdecl, raises: [], gcsafe.} =
  let cap = cast[ptr Capture](user)
  inc cap.count
  cap.lastLevel = int32(ord(level))
  var i = 0
  if not msg.isNil:
    while i < 127 and msg[i] != '\0':
      cap.buf[i] = msg[i]
      inc i
  cap.buf[i] = '\0'
  cap.bufLen = int32(i)

proc captured(cap: Capture): string =
  result = ""
  var i = 0
  while i < 128 and cap.buf[i] != '\0':
    result.add cap.buf[i]
    inc i

suite "logger":
  test "silentLogger ничего не пишет и не требует sink":
    var l = silentLogger()
    check l.isSilent()
    check l.sink.isNil
    # Даже llError не должен приводить к обращению к nil-sink.
    logError(addr l, "нет вывода")

  test "sink получает уровень и текст":
    var cap: Capture
    var l = logger(addr cap, sinkProc, llDebug)
    check not l.isSilent()
    logInfo(addr l, "hello")
    check cap.count == 1
    check cap.lastLevel == int32(ord(llInfo))
    check cap.captured() == "hello"

  test "threshold отбрасывает сообщения ниже уровня":
    var cap: Capture
    var l = logger(addr cap, sinkProc, llWarn)
    logDebug(addr l, "debug-скрыт")
    logInfo(addr l, "info-скрыт")
    check cap.count == 0
    logWarn(addr l, "warn-виден")
    logError(addr l, "error-виден")
    check cap.count == 2
    check cap.lastLevel == int32(ord(llError))
    check cap.captured() == "error-виден"

  test "nil-логгер безопасен":
    # Core передаёт логгер указателем; nil — легальное «нет логгера».
    logMsg(nil, llError, "в никуда")
    logDebug(nil, "тоже в никуда")

  test "levelName даёт машинные имена уровней":
    check $levelName(llDebug) == "DEBUG"
    check $levelName(llInfo) == "INFO"
    check $levelName(llWarn) == "WARN"
    check $levelName(llError) == "ERROR"
