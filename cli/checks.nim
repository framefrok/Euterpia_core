# cli/checks.nim
#
# Общая модель отчёта-проверок для диагностических команд CLI: `doctor`
# (#105) и `project validate` (#89).
#
# Модель вынесена из cmd_doctor по двум причинам:
# - `project validate` не должен зависеть от аудио-модуля: ему нужен только
#   тип проверки, а не адаптер miniaudio;
# - обе команды печатают одно и то же («список проверок со статусами»),
#   поэтому у них один сериализатор `sectionJson` и один рендер
#   `renderHuman`. Схема `--json` не может разойтись между командами (#96).
#
# Заголовок вывода (имя команды, версия) остаётся в самой команде: он у
# `doctor` и `validate` разный, а вид секции — общий.

import std/json

type
  CheckStatus* = enum
    csOk, csNote, csWarn, csFail
      ## Порядок значений — порядок серьёзности: `worst` берёт максимум, а
      ## код возврата команды смотрит только на `csFail`. «На заметку» —
      ## находка, которая не является ни дефектом, ни поводом для тревоги:
      ## без неё строгий отчёт либо молчит о подозрительном, либо пугает
      ## пользователя предупреждением (issue #339).

  Check* = object
    id*: string
    title*: string
    status*: CheckStatus
    lines*: seq[string]
    advice*: string
    body*: JsonNode
      ## Машинные факты проверки (числа, флаги) — то, что агент читает
      ## вместо разбора текста.

  Section* = object
    id*: string
    title*: string
    checks*: seq[Check]

proc statusName*(s: CheckStatus): string =
  case s
  of csOk: "ok"
  of csNote: "note"
  of csWarn: "warn"
  of csFail: "fail"

proc worst*(a, b: CheckStatus): CheckStatus =
  ## Худший из статусов: статус секции — это максимум по проверкам.
  if ord(a) >= ord(b): a else: b

proc sectionStatus*(s: Section): CheckStatus =
  result = csOk
  for c in s.checks:
    result = worst(result, c.status)

proc mkCheck*(
  id, title: string;
  status: CheckStatus;
  lines: seq[string] = @[];
  advice: string = "";
  body: JsonNode = nil
): Check =
  Check(id: id, title: title, status: status, lines: lines,
        advice: advice, body: body)

proc sectionJson*(s: Section): JsonNode =
  ## Машинный вид секции. Порядок полей фиксирован, поэтому повторный
  ## запуск даёт байт-в-байт тот же JSON (#88).
  result = newJObject()
  result["id"] = %s.id
  result["title"] = %s.title
  result["status"] = %statusName(sectionStatus(s))
  var checksJson = newJArray()
  for c in s.checks:
    var checkJson = newJObject()
    checkJson["id"] = %c.id
    checkJson["title"] = %c.title
    checkJson["status"] = %statusName(c.status)
    var details = newJArray()
    for line in c.lines:
      details.add %line
    checkJson["details"] = details
    checkJson["advice"] = %c.advice
    if c.body != nil:
      checkJson["facts"] = c.body
    checksJson.add checkJson
  result["checks"] = checksJson

proc counts*(sections: seq[Section]): tuple[ok, note, warn, fail: int] =
  ## Счётчики по статусам. `note` отделён от `warn` намеренно: «на заметку»
  ## не повод менять код возврата, и смешивать их значило бы врать сводкой.
  for s in sections:
    for c in s.checks:
      case c.status
      of csOk: inc result.ok
      of csNote: inc result.note
      of csWarn: inc result.warn
      of csFail: inc result.fail

proc renderHuman*(sections: seq[Section]; verbose: bool): seq[string] =
  ## Человекочитаемый вид секций: «[статус] заголовок», детали с отступом,
  ## рекомендация — при проблеме и всегда в `--verbose`.
  for s in sections:
    result.add "[" & statusName(sectionStatus(s)) & "] " & s.title
    for c in s.checks:
      result.add "    [" & statusName(c.status) & "] " & c.title
      for line in c.lines:
        result.add "        " & line
      if c.advice.len > 0 and (c.status != csOk or verbose):
        result.add "        рекомендация: " & c.advice

proc summaryJson*(sections: seq[Section]): JsonNode =
  ## Сводка по проверкам: `{"ok": …, "warn": …, "fail": …}`. Считается
  ## ровно тем же обходом, что отдаёт `counts`, поэтому код возврата команды
  ## не может разойтись со сводкой в `--json`.
  let total = counts(sections)
  %*{"ok": total.ok, "note": total.note, "warn": total.warn,
     "fail": total.fail}
