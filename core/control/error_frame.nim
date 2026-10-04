# core/control/error_frame.nim
#
# Результат команды — не `bool`, а кадр ошибки (issue #139, MANIFEST §44, §65).
#
# Почему не `bool`:
#   - `false` не отвечает на вопрос «что делать пользователю»: «ноды нет»,
#     «порт занят» и «тип неизвестен» — три разных подсказки;
#   - `bool` нельзя показать агенту машинным кодом: строковый разбор сообщений
#     ломается при любой правке формулировки;
#   - у GUI и CLI должен быть ОДИН и тот же код ошибки, иначе клиенты
#     разойдутся (#148, #117).
#
# Числа кодов — контракт: `frameCodeValue` отдаёт их наружу, и порядок
# перечисления меняться не может. Тексты — человеческая часть и правятся.
# Имена кодов попадают в отчёт CLI (`errorKind`), поэтому они тоже стабильны.

type
  ErrorCode* = enum
    ## Коды отказа операции над документом. Числовое значение — контракт (§58:
    ## версии API не смешиваются), тексты объяснений — нет.
    ecOk = 0
      ## Успех: операция выполнена.
    ecNotFound
      ## Запрошенной сущности нет (нода, дорожка, клип, связь).
    ecAlreadyExists
      ## Сущность с таким идентификатором уже есть.
    ecInvalidArgument
      ## Аргумент команды неверен: пустое имя, отрицательный порт, пустая
      ## команда.
    ecOutOfRange
      ## Значение параметра вне диапазона типа.
    ecUnknownNodeType
      ## Тип ноды не зарегистрирован в узлах (Core о типах не знает, §54).
    ecUnknownParameter
      ## У типа нет такого параметра.
    ecDuplicateConnection
      ## Такая связь уже есть.
    ecConnectionNotFound
      ## Связи для разрыва нет.
    ecPortKindMismatch
      ## Виды портов источника и приёмника не совпадают.
    ecPortNotAvailable
      ## У ноды нет порта такого вида или номера.
    ecNoDescriptor
      ## Хост не дал описатель типа: это проблема окружения, а не данные.
    ecUnsupportedCommand
      ## Команда объявлена в контракте, но ещё не реализована.
    ecApiVersionMismatch
      ## Клиент говорит на другой версии control-API (§58: версии не смешиваются).
    ecInternal
      ## Внутренняя ошибка (баг). Пользователь в ней не виноват.

  ErrorFrame* = object
    ## Кадр результата операции. Значение, а не исключение: control-path
    ## возвращает его вызывающему, а не бросает (исключение в GUI-слое или в
    ## audio-потоке — это уже авария).
    code*: ErrorCode
    message*: string
      ## Что произошло, своими словами и с именем сущности.
    hint*: string
      ## Что сделать: посмотреть адреса, показать каталог, повторить команду.

proc okFrame*(): ErrorFrame {.inline.} =
  ErrorFrame(code: ecOk)

proc errFrame*(code: ErrorCode; message: string;
               hint: string = ""): ErrorFrame {.inline.} =
  ErrorFrame(code: code, message: message, hint: hint)

proc isOk*(frame: ErrorFrame): bool {.inline.} =
  frame.code == ecOk

proc frameCodeValue*(code: ErrorCode): int {.inline.} =
  ## Числовой код для машинных клиентов: он входит в отчёт `--json` и не
  ## зависит ни от текста, ни от языка интерфейса.
  int(ord(code))

proc `$`*(code: ErrorCode): string =
  ## Имя кода: попадает в `errorKind` отчёта и читается агентом как слово.
  ## Список задан явно, а не через `$code`: имя в отчёте — тоже контракт.
  case code
  of ecOk: "ok"
  of ecNotFound: "not_found"
  of ecAlreadyExists: "already_exists"
  of ecInvalidArgument: "invalid_argument"
  of ecOutOfRange: "out_of_range"
  of ecUnknownNodeType: "unknown_node_type"
  of ecUnknownParameter: "unknown_parameter"
  of ecDuplicateConnection: "duplicate_connection"
  of ecConnectionNotFound: "connection_not_found"
  of ecPortKindMismatch: "port_kind_mismatch"
  of ecPortNotAvailable: "port_not_available"
  of ecNoDescriptor: "no_descriptor"
  of ecUnsupportedCommand: "unsupported_command"
  of ecApiVersionMismatch: "api_version_mismatch"
  of ecInternal: "internal"
