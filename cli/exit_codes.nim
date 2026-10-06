# cli/exit_codes.nim
#
# Таблица «причина → код возврата» — ДАННЫМИ (issue #332, MANIFEST §21/§44).
#
# Зачем отдельным модулем и почему данными:
#   - код возврата — часть контракта CLI: агент решает, повторять ли команду,
#     чинить ли данные или окружение, по одному числу. Пока это `case` внутри
#     функции, добавленная в ядро причина молча получает «код по умолчанию», и
#     никто об этом не узнаёт;
#   - таблица проверяема: `exitRulesProblems` находит причину без строки,
#     повтор строки, код возврата вне контракта. Тест (`nimble cliSmoke`,
#     suite «единые коды ошибок») прогоняет проверку по боевому списку
#     `ErrorCode` — искусственно добавленная причина роняет CI, а не проходит
#     молча;
#   - из неё же строится раздел `docs/cli.md` (см. `libs/cli_spec`): таблица в
#     документации не может разойтись с кодом, потому что генерируется.
#
# Что НЕ здесь: `errorKind` («usage»/«env»/«io»/…). Это класс ошибки для
# человека и партнёра по протоколу, он ставится командой; `errorCode` — точная
# причина, и именно её видит агент.

import control/error_frame

type
  ExitCode* = enum
    exOk = 0
      ## Успех.
    exUsage = 1
      ## Ошибка данных или использования: неизвестная команда/ключ,
      ## лишний аргумент, невалидное значение.
    exEnv = 2
      ## Ошибка среды: нет библиотеки/устройства/прав. Данные верны,
      ## окружение не позволяет выполнить команду.
    exPanic = 3
      ## Внутренняя ошибка CLI (баг). Пользователь в ней не виноват.

  ExitRule* = object
    ## Одна строка таблицы: причина → код возврата и её объяснение.
    code*: ErrorCode
    exit*: ExitCode
    meaning*: string
      ## Что причина значит для человека. Печатается в `docs/cli.md` и в
      ## `help --json`; текст правится свободно, числа — нет.

const
  ExitRules*: seq[ExitRule] = @[
    ExitRule(code: ecOk, exit: exOk,
             meaning: "успех — операция выполнена"),
    ExitRule(code: ecInvalidArgument, exit: exUsage,
             meaning: "аргумент неверен: пустое имя, отрицательный порт, " &
                      "неизвестная команда или ключ"),
    ExitRule(code: ecNotFound, exit: exUsage,
             meaning: "запрошенной сущности нет: нода, дорожка, клип, связь"),
    ExitRule(code: ecAlreadyExists, exit: exUsage,
             meaning: "сущность с таким идентификатором уже есть"),
    ExitRule(code: ecOutOfRange, exit: exUsage,
             meaning: "значение параметра вне диапазона типа"),
    ExitRule(code: ecUnknownNodeType, exit: exUsage,
             meaning: "тип ноды не зарегистрирован"),
    ExitRule(code: ecUnknownParameter, exit: exUsage,
             meaning: "у типа нет такого параметра"),
    ExitRule(code: ecDuplicateConnection, exit: exUsage,
             meaning: "такая связь уже есть"),
    ExitRule(code: ecConnectionNotFound, exit: exUsage,
             meaning: "связи для разрыва нет"),
    ExitRule(code: ecPortKindMismatch, exit: exUsage,
             meaning: "виды портов источника и приёмника не совпадают"),
    ExitRule(code: ecPortNotAvailable, exit: exUsage,
             meaning: "у ноды нет порта такого вида или номера"),
    ExitRule(code: ecUnsupportedCommand, exit: exUsage,
             meaning: "команда объявлена в контракте, но ещё не реализована"),
    ExitRule(code: ecNotInvertible, exit: exUsage,
             meaning: "операцию нельзя отменить: история её не примет"),
    ExitRule(code: ecStaleHandle, exit: exUsage,
             meaning: "адрес устарел: слот переиспользован или сущность удалена"),
    ExitRule(code: ecForeignDocument, exit: exUsage,
             meaning: "адрес принадлежит другому документу"),
    ExitRule(code: ecKindMismatch, exit: exUsage,
             meaning: "адрес указывает на другой вид сущности"),
    ExitRule(code: ecApiVersionMismatch, exit: exEnv,
             meaning: "клиент говорит на другой версии control-API"),
    ExitRule(code: ecNoDescriptor, exit: exEnv,
             meaning: "хост не дал описатель типа: проблема окружения, а не данных"),
    ExitRule(code: ecEnvironment, exit: exEnv,
             meaning: "окружение не позволяет выполнить операцию: нет файла, " &
                      "каталога, прав или устройства"),
    ExitRule(code: ecCheckFailed, exit: exUsage,
             meaning: "проверка не пройдена: невалидный проект, не компилирующийся " &
                      "граф, дефекты аудио выше порога — вердикт CI"),
    ExitRule(code: ecInternal, exit: exPanic,
             meaning: "внутренняя ошибка (баг) — пользователь в ней не виноват"),
  ]
    ## Полная таблица: одна строка на каждую причину `ErrorCode`.
    ## `exitRulesProblems` проверяет, что это так.

proc exitRule*(code: ErrorCode): ExitRule =
  ## Строка таблицы для причины. Отсутствие строки — баг сборки, поэтому
  ## возвращается безопасное значение (`exPanic`), а не «успех»: молча отдать
  ## 0 при отказе значило бы соврать клиенту.
  for rule in ExitRules:
    if rule.code == code:
      return rule
  ExitRule(code: code, exit: exPanic,
           meaning: "нет строки в таблице кодов возврата (issue #332)")

proc exitCodeFor*(code: ErrorCode): ExitCode =
  ## Код возврата процесса по причине отказа. Единственная точка перевода:
  ## и кадры ядра (`frameReport`), и ошибки самого CLI (`usageError`/`envError`)
  ## берут код отсюда.
  exitRule(code).exit

proc errorCodeMeaning*(code: ErrorCode): string =
  ## Объяснение причины: печатается в `docs/cli.md` и `help --json`.
  exitRule(code).meaning

proc exitRulesProblems*(): seq[string] =
  ## Проверка самой таблицы: она обязана покрывать ВСЕ причины, не повторять
  ## их и выдавать коды из контракта (0..3). Пустой список — таблица полна;
  ## непустой печатает CI (`help --json`, поле `exitCodeProblems`).
  var seen: seq[ErrorCode] = @[]
  for rule in ExitRules:
    if rule.code in seen:
      result.add "причина " & $rule.code & " описана дважды"
    seen.add rule.code
    if rule.meaning.len == 0:
      result.add "причина " & $rule.code & " без объяснения"
    if ord(rule.exit) < ord(ExitCode.low) or ord(rule.exit) > ord(ExitCode.high):
      result.add "причина " & $rule.code & " с кодом возврата вне контракта: " &
        $ord(rule.exit)
  for code in ErrorCode.low .. ErrorCode.high:
    if code notin seen:
      result.add "причина " & $code & " без кода возврата: добавьте строку в " &
        "ExitRules (cli/exit_codes.nim)"
