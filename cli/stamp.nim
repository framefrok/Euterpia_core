# cli/stamp.nim
#
# Отметка изменения документа (`metadata.created`/`modified`) — issue #139.
#
# Отдельный модуль, а не функция в `cmd_project`: тот же формат нужен
# инъекции часов control-слоя (`cli/control_bridge.stampClock`), а раньше это
# замыкало импорт `cmd_project → control_bridge → cmd_project`. Часы и формат
# принадлежат клиенту: ядро хранит эти поля как непрозрачные строки (§58), но
# две отметки одного клиента обязаны быть сравнимы, поэтому формат — константа
# одного места, а не «как получилось».

import std/times

const
  StampFormat* = "yyyy-MM-dd'T'HH:mm:ss"
    ## Формат `metadata.created`/`modified`: ISO 8601 без зоны (локальное
    ## время). Ядро хранит эти поля как непрозрачные строки, но формат
    ## лексикографически упорядочен, поэтому строки сравнимы между собой.

proc nowStamp*(): string =
  ## Отметка времени для `metadata.created`/`modified`.
  now().format(StampFormat)
