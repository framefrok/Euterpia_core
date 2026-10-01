# logger.nim
#
# Минимальная абстракция логирования для Core.
#
# Правила (MANIFEST §6, §43):
# - Core не пишет в stdout сам: куда выводить — решает CLI / Editor,
#   который подключает свой sink снаружи;
# - вызов логгера — ВСЕГДА control-path;
# - в audio callback логирование запрещено. Там допустима только
#   realtime-safe диагностика: счётчики и EngineMetric.

{.push raises: [].}

type
  LogLevel* = enum
    llDebug = 0,
    llInfo,
    llWarn,
    llError

  LogSink* = proc(user: pointer; level: LogLevel; msg: cstring)
    {.cdecl, raises: [], gcsafe.}

  Logger* = object
    ## Подписчик логов.
    ##
    ## Нулевой `sink` означает silent logger: сообщения просто
    ## отбрасываются. Именно это состояние является дефолтным, поэтому
    ## Core не может «случайно» начать писать в stdout.
    user*: pointer
    sink*: LogSink
    threshold*: LogLevel

proc silentLogger*(): Logger {.inline.} =
  ## Ничего не выводит. Дефолт для ядра и тестов.
  Logger(user: nil, sink: nil, threshold: llError)

proc logger*(
  user: pointer;
  sink: LogSink;
  threshold: LogLevel = llDebug
): Logger {.inline.} =
  ## Собирает логгер для верхнего слоя (CLI/Editor).
  Logger(user: user, sink: sink, threshold: threshold)

proc isSilent*(l: Logger): bool {.inline.} =
  l.sink.isNil

proc levelName*(level: LogLevel): cstring {.inline.} =
  case level
  of llDebug: cstring"DEBUG"
  of llInfo:  cstring"INFO"
  of llWarn:  cstring"WARN"
  of llError: cstring"ERROR"

proc logMsg*(
  logger: ptr Logger;
  level: LogLevel;
  msg: string
) =
  ## Единственная точка вывода в Core.
  ##
  ## Сознательно принимает `string`: это control-path. В realtime-пути
  ## функция не вызывается вовсе, поэтому конверсия строки здесь
  ## безопасна.
  if logger.isNil or logger.sink.isNil:
    return

  if level < logger.threshold:
    return

  logger.sink(logger.user, level, cstring(msg))

proc logDebug*(logger: ptr Logger; msg: string) {.inline.} =
  logMsg(logger, llDebug, msg)

proc logInfo*(logger: ptr Logger; msg: string) {.inline.} =
  logMsg(logger, llInfo, msg)

proc logWarn*(logger: ptr Logger; msg: string) {.inline.} =
  logMsg(logger, llWarn, msg)

proc logError*(logger: ptr Logger; msg: string) {.inline.} =
  logMsg(logger, llError, msg)

{.pop.}
