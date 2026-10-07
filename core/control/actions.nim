# core/control/actions.nim
#
# Клиентский контракт: «действие интерфейса = команда» (issue #148,
# MANIFEST §19-21, §60, §61, §65).
#
# Зачем это в Core. CLI и Editor — равноправные клиенты ОДНОЙ модели (§60),
# поэтому поверхность действий должна быть одна: то, что собрано мышью,
# обязано воспроизводиться скриптом (§61), а действие, у которого нет
# CLI-эквивалента, — не появляться в интерфейсе вообще. Держать этот
# перечень в клиенте нельзя: у двух клиентов появятся две поверхности, и
# «равноправность» останется словом. Здесь лежат ТОЛЬКО данные и правила,
# ни одной зависимости от CLI/Editor (§63: клиент не знает внутренностей,
# ядро — не знает клиентов).
#
# Что именно проверяется машинно (`tests/cli_test.nim`, suite «паритет
# клиентов»):
#
#   * `issue == 0` — действие поставляется полностью: у него есть CLI-команда
#     из реестра CLI, а команда документа РЕАЛИЗОВАНА в control-слое;
#   * `issue > 0` — действие объявлено контрактом, но поставляется частями:
#     номер issue обязателен, иначе «запланировано» превращается в «забыто»;
#   * каждое имя CLI-команды действия существует в `help --json`;
#   * обратная сторона (GUI-действие без CLI-эквивалента): каждая видимая
#     команда CLI либо покрыта действием, либо объяснена в `cliOnlyCommands`;
#   * каждая РЕАЛИЗОВАННАЯ команда документа имеет действие (кроме
#     внутренних — отката), иначе команда ядра недоступна из интерфейса.
#
# `command` — идентификатор команды ядра, а не «строка для красоты»:
#   * для `csEdit` он вычисляется из `ControlCommandKind` (`commandName`),
#     то есть расхождение с командой документа невозможно по построению;
#   * для `csRuntime` — имя процедуры движка (`audio_engine.postPlay`),
#     существование которой проверяется по исходнику ядра;
#   * у файловых и клиентских действий команды ядра нет: их путём исполнения
#     и остаётся CLI-команда (у окна — собственная логика, §20/§64).

import commands

type
  ClientScope* = enum
    ## Кто исполняет действие и что оно меняет. Разделение принципиальное:
    ## только `csEdit` меняет документ, а значит только оно попадает в
    ## историю и откат (#109).
    csEdit = "edit"        ## документ, через control-слой (§65)
    csRuntime = "runtime"  ## состояние времени исполнения, но не документ (§10)
    csIo = "io"            ## файлы: проект, рендер, экспорт, импорт
    csView = "view"        ## представление: только чтение (§21)
    csSession = "session"  ## настройки и диагностика окружения
    csWindow = "window"    ## само окно: палитра, раскладка, attach (#148, F2)

  ClientAction* = object
    ## Одно действие клиента и его связь с командой ядра и CLI.
    id*: string
      ## Стабильный идентификатор ДЕЙСТВИЯ (`transport.play`). По нему
      ## палитра, горячие клавиши и «запись сессии в скрипт» (#148) находят
      ## одно и то же независимо от того, нажата кнопка или набран ключ.
    title*: string
      ## Как действие подписано в интерфейсе (человеческий текст, не id).
    scope*: ClientScope
    cli*: string
      ## Имя CLI-команды-эквивалента; пусто — эквивалента ещё нет, и тогда
      ## `issue` обязан быть ненулевым.
    command*: string
      ## Идентификатор команды ядра: `commandName` для `csEdit`, имя
      ## процедуры движка для `csRuntime`, иначе пусто.
    issue*: int
      ## Что осталось до полной пары: 0 — поставляется целиком, иначе номер
      ## issue, закрывающий разрыв.
    hasControl*: bool
      ## Есть ли у действия команда документа (проверяется компилятором:
      ## `control` — перечисление, а не строка).
    control*: ControlCommandKind
      ## Сама команда документа; осмысленна только при `hasControl`.

  CliOnlyCommand* = object
    ## Команда CLI, у которой нет и не должно быть действия интерфейса.
    ## «Нет действия» — это решение, а не забывчивость, поэтому причина
    ## обязательна: иначе исключение из обратной сверки никто не отличит от
    ## дырки в паритете.
    name*: string
    reason*: string

proc editAction(id, title: string; kind: ControlCommandKind;
                cli: string; issue = 0): ClientAction =
  ## Действие над документом. `command` берётся из того же перечисления, что
  ## разбирает control-слой: имя команды в отчётах и в клиенте — одно.
  ClientAction(id: id, title: title, scope: csEdit, cli: cli,
               command: commandName(kind), issue: issue,
               hasControl: true, control: kind)

proc engineAction(id, title, engineProc, cli: string;
                  issue = 0): ClientAction =
  ## Действие времени исполнения: команда идёт по пути control → audio
  ## (`postPlay`, `postStop`, `postSeekSeconds`), документ при этом не
  ## меняется — «нажал Play» не делает проект грязным (§10, §65).
  ClientAction(id: id, title: title, scope: csRuntime, cli: cli,
               command: engineProc, issue: issue)

proc ioAction(id, title, cli: string; issue = 0): ClientAction =
  ## Файловое действие: путь исполнения — сам клиент (CLI-команда либо
  ## диалог окна), команды документа нет.
  ClientAction(id: id, title: title, scope: csIo, cli: cli, issue: issue)

proc viewAction(id, title, cli: string; issue = 0): ClientAction =
  ClientAction(id: id, title: title, scope: csView, cli: cli, issue: issue)

proc historyAction(id, title, cli: string): ClientAction =
  ## Действие над ИСТОРИЕЙ правок: документ меняется (откат/повтор), но не
  ## командой control-слоя, а воспроизведением уже записанных обратных команд
  ## (§66, #109, #331). Поэтому `hasControl=false`, а scope — `edit`: правка
  ## документа, а не представление.
  ClientAction(id: id, title: title, scope: csEdit, cli: cli)

proc sessionAction(id, title, cli: string; issue = 0): ClientAction =
  ClientAction(id: id, title: title, scope: csSession, cli: cli, issue: issue)

proc windowAction(id, title: string; issue: int): ClientAction =
  ## Действие самого окна: команды ядра не существует по определению, поэтому
  ## и CLI-эквивалента быть не может — но `issue` обязателен: действие
  ## объявлено контрактом и появится вместе с интерфейсом.
  ClientAction(id: id, title: title, scope: csWindow, issue: issue)

# ==============================================================================
# Перечень действий
#
# Порядок — «как в интерфейсе»: граф, транспорт, секвенсор, файлы,
# представления, окружение, окно. Он же порядок строк в docs/clients.md, и он
# же порядок кандидатов палитры команд (Ctrl+K): палитра строится из этого
# списка, а не из своего.
# ==============================================================================

proc clientActions*(): seq[ClientAction] =
  ## Действия клиента. Список строится вызовом, а не лежит в `const`: зато
  ## `commandName` вызывается тем же кодом, что и в control-слое, и имя
  ## команды документа не может разойтись с ним по недосмотру.
  result = @[
    # --- граф: есть и в ядре, и в CLI (#90) -------------------------------
    editAction("graph.node.add", "Добавить ноду", ccCreateNode, "node"),
    editAction("graph.node.delete", "Удалить ноду", ccDeleteNode, "node"),
    editAction("graph.connect", "Соединить ноды", ccConnect, "connect"),
    editAction("graph.disconnect", "Разъединить ноды", ccDisconnect,
               "disconnect"),
    editAction("param.set", "Задать параметр", ccSetParameter, "param"),
    editAction("project.setInfo", "Задать метаданные проекта",
               ccSetProjectInfo, "project"),
    viewAction("view.graph", "Показать граф: ноды и связи", "node"),
    viewAction("view.graphCheck", "Проверить граф и компиляцию", "graph"),

    # --- транспорт --------------------------------------------------------
    # Поверхность транспорта целиком — CLI-команда `transport` (#257).
    # Темп/размер меняют документ (`csEdit`); play/pause/stop/seek/loop —
    # рантайм (`csRuntime`, документа не трогают); position/state — чтение.
    # Живой путь (устройство, реальный Play) остаётся за #92: у play/pause/
    # stop/seek там же и backend lifecycle. Команды документа
    # (`ccSetTransport`) control-слой ещё не реализует, поэтому `transport.set`
    # поставляется частями (#257).
    editAction("transport.set", "Задать темп, размер и петлю", ccSetTransport,
               "transport", issue = 257),
    engineAction("transport.play", "Играть", "postPlay", "transport",
                 issue = 92),
    engineAction("transport.pause", "Пауза", "postPause", "transport",
                 issue = 257),
    engineAction("transport.stop", "Остановить", "postStop", "transport",
                 issue = 92),
    engineAction("transport.seek", "Перейти к позиции", "postSeekSeconds",
                 "transport", issue = 92),
    engineAction("transport.loop", "Задать цикл воспроизведения", "postSetLoop",
                 "transport", issue = 257),
    viewAction("transport.position", "Показать позицию транспорта",
               "transport"),
    viewAction("transport.state", "Показать состояние транспорта", "transport"),

    # --- секвенсор: дорожки, клипы, ноты ----------------------------------
    # Команды документа объявлены (#139) и отвечают `ecUnsupportedCommand`,
    # команд CLI для них тоже нет — поэтому пары «действие ↔ команда» пока
    # неполные, и это записано номером issue, а не умалчивается (#87).
    editAction("track.add", "Добавить дорожку", ccAddTrack, "", issue = 87),
    editAction("track.delete", "Удалить дорожку", ccRemoveTrack, "",
               issue = 87),
    editAction("clip.add", "Добавить клип", ccAddClip, "", issue = 87),
    editAction("clip.delete", "Удалить клип", ccDeleteClip, "", issue = 87),
    editAction("note.add", "Добавить ноту", ccAddNote, "", issue = 87),
    editAction("note.delete", "Удалить ноту", ccDeleteNote, "", issue = 87),
    viewAction("view.timeline", "Показать таймлайн и клипы", "project"),

    # --- файлы: проект, рендер, экспорт -----------------------------------
    ioAction("project.new", "Новый проект", "init"),
    ioAction("project.validate", "Проверить проект", "project"),
    ioAction("file.render", "Отрендерить в WAV", "render"),
    ioAction("file.midiExport", "Экспорт в MIDI", "midi"),
    ioAction("file.notationImport", "Импорт партитуры", "notation"),
    ioAction("file.audioImport", "Импорт аудио", "import"),
    ioAction("file.audioInspect", "Инспектор аудио", "analyze"),
    ioAction("file.stemsExport", "Экспорт стемов и батч-рендер", "",
             issue = 108),
    viewAction("view.project", "Показать проект: метаданные и треки",
               "project"),

    # --- окружение --------------------------------------------------------
    sessionAction("session.settings", "Настройки окружения", "config"),
    sessionAction("session.diagnostics", "Диагностика окружения", "doctor"),

    # --- история правок (#331): откат и повтор поверх control-слоя (#109) -
    # Документ меняется, но команды в перечислении нет: откат воспроизводит
    # обратные команды записи, а не новую команду документа.
    historyAction("edit.undo", "Отменить последнюю правку", "undo"),
    historyAction("edit.redo", "Повторить отменённую правку", "redo"),
    viewAction("view.history", "Показать историю правок", "history"),

    # --- само окно (#148): команды ядра нет, CLI-эквивалента быть не может -
    windowAction("window.palette", "Палитра команд (Ctrl+K)", issue = 148),
    windowAction("window.recordScript", "Записать сессию в скрипт",
                 issue = 148),
    windowAction("window.attachSession", "Подключиться к сессии (attach)",
                 issue = 148),
  ]


proc cliOnlyCommands*(): seq[CliOnlyCommand] =
  ## Видимые команды CLI, у которых действия интерфейса нет ПО РЕШЕНИЮ.
  ## Список исчерпывающий: команда, появившаяся в реестре CLI и не попавшая
  ## ни сюда, ни в действия, валит тест паритета. Решение о её месте
  ## принимается в момент добавления команды, а не задним числом.
  result = @[
    CliOnlyCommand(
      name: "completion",
      reason: "автодополнение оболочки: у окна нет оболочки, дополнять нечего"),
    CliOnlyCommand(
      name: "help",
      reason: "справка печатается в окне; в GUI это палитра и меню, а не команда"),
    CliOnlyCommand(
      name: "version",
      reason: "версия показывается в окне «О программе», а не выполняется"),
  ]

# ==============================================================================
# Сверки
# ==============================================================================

proc findAction*(actions: seq[ClientAction]; id: string): int =
  ## Индекс действия по стабильному id или -1, если такого действия нет.
  for i in 0 ..< actions.len:
    if actions[i].id == id:
      return i
  -1

proc cliCommands*(actions: seq[ClientAction]): seq[string] =
  ## Имена CLI-команд, покрытых действиями: без повторов, в порядке перечня.
  ## По этому множеству считается обратная сторона паритета — «нет команды
  ## CLI, недоступной из интерфейса и не объяснённой».
  for action in actions:
    if action.cli.len > 0 and action.cli notin result:
      result.add action.cli

proc pendingActions*(actions: seq[ClientAction]): seq[ClientAction] =
  ## Действия, поставляемые частями: у них есть номер issue.
  for action in actions:
    if action.issue != 0:
      result.add action

proc readyActions*(actions: seq[ClientAction]): seq[ClientAction] =
  ## Действия, поставляемые целиком: `issue == 0`.
  for action in actions:
    if action.issue == 0:
      result.add action

