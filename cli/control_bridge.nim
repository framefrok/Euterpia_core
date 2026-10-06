# cli/control_bridge.nim
#
# Мост между CLI и control-слоем документа (issue #139, MANIFEST §20, §65).
#
# CLI больше не решает, что можно делать с проектом: он разбирает аргументы,
# собирает команду и получает `ErrorFrame`. Три вещи остаются его делом,
# потому что ядро о них знать не должна:
#
#   1. `cliNodeTypeProvider` — перевод дескриптора реестра нод в описатель,
#      который понимает control-слой. Core не знает типов нод (§54), но обязан
#      знать порты и границы параметров, поэтому хозяин документа отдаёт их
#      через провайдер;
#   2. `stampClock` — отметка изменения документа. Часы внедряются, а не
#      берутся из системы: иначе CLI и тестовый клиент, выполнившие одну
#      команду, дали бы разные документы и их нельзя было бы сравнить;
#   3. `frameReport` — перевод кадра ошибки в отчёт CLI: тот же код возврата и
#      та же подсказка, но текст приходит из ядра и не дублируется в клиенте.
#
# Обратное направление (ядро → CLI) здесь единственное: ядро ничего не знает
# ни о файлах, ни о stdout, ни о кодах возврата.

import std/os

import project
import handles
import control/error_frame
import control/commands
import control/document

import catalog
import context
import stamp

proc cliNodeTypeProvider*(nodeType: string; spec: var NodeTypeSpec): bool =
  ## Описатель типа из каталога CLI. Флаги параметра переводятся в один факт
  ## (`integerLike`): control-слой не знает перечисления `NodeParamFlag`, но
  ## обязан знать, что параметр не принимает дробное значение.
  let cat = catalog()
  var info: NodeTypeInfo
  var found = false
  for candidate in cat:
    if candidate.id == nodeType:
      info = candidate
      found = true
      break
  if not found:
    return false
  spec = NodeTypeSpec(
    id: info.id,
    name: info.name,
    audioIn: info.audioIn, audioOut: info.audioOut,
    ctrlIn: info.ctrlIn, ctrlOut: info.ctrlOut,
    eventIn: info.eventIn, eventOut: info.eventOut,
    latencyFrames: info.latencyFrames
  )
  for p in info.params:
    spec.params.add ParamSpec(
      name: p.name,
      minValue: p.minValue, maxValue: p.maxValue,
      defaultValue: p.defaultValue, step: p.step,
      integerLike: p.paramIsInteger(),
      automatable: p.paramIsAutomatable(),
      modulatable: p.paramIsModulatable(),
      hidden: p.paramIsHidden()
    )
  true

proc controlPortKind*(kind: PortKind): ControlPortKind {.inline.} =
  ## Перевод вида порта каталога CLI в вид порта команды. Порядковые значения
  ## совпадают с `SignalType`, но переход явный: «совпало случайно» — плохой
  ## признак контракта (§58).
  case kind
  of pkAudio:
    cpkAudio
  of pkCtrl:
    cpkControl
  of pkEvent:
    cpkEvent

proc stampClock*(): string =
  ## Отметка изменения документа в формате проекта (§58).
  nowStamp()

proc exitCodeFor*(code: ErrorCode): ExitCode =
  ## Код возврата CLI по коду control-слоя. Классы ошибок прежние
  ## (`usage`/`env`/`panic`), а причина приходит отдельным полем `errorCode`.
  case code
  of ecOk:
    exOk
  of ecNoDescriptor:
    # Хост не дал описатели типов — это проблема окружения, а не данные.
    exEnv
  of ecInternal:
    exPanic
  else:
    exUsage

proc frameReport*(frame: ErrorFrame): Report =
  ## Кадр ошибки control-слоя в отчёте CLI: текст и подсказка — из ядра, класс
  ## и код возврата — по таблице выше. Клиент своего текста не выдумывает,
  ## поэтому CLI и Editor говорят об одном отказе одинаково (#148).
  if frame.isOk():
    return okReport()
  errReport(exitCodeFor(frame.code), $frame.code, frame.message, frame.hint,
            errorCode = frameCodeValue(frame.code))

proc openDocument*(path: string; proj: ProjectFormat): Document =
  ## Документ из загруженного проекта: идентификатор документа тот же, что у
  ## адресов (#143), описатели типов — каталог CLI, часы — `stampClock`.
  var doc: Document
  initDocument(doc, proj, documentIdForPath(absolutePath(path)),
               cliNodeTypeProvider, stampClock)
  doc
