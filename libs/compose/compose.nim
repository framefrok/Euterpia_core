# libs/compose/compose.nim
#
# Одна точка входа для «композиции как код» (issue #311).
#
# Зачем: `arr.render(...)` живёт в `compose/engine`, а `arrangement(...)` и
# `instrument(...)` — в `compose/song`. Забытый импорт стоил пользователю
# сообщения `Error: attempting to call undeclared routine: 'render'` — то
# есть ровно того места, где он и так застрял. Теперь достаточно одного
# `import compose/compose`.
#
# Что можно взять и откуда:
#   * `compose/score`    — события, такты, мотивы, партии;
#   * `compose/song`     — раскладка, инструменты, проверка, запись;
#   * `compose/engine`   — рендер в WAV;
#   * `compose/progress` — индикатор прогресса;
#   * `compose/builder`  — произвольный граф (импортируется отдельно: его
#     `Builder` — низкоуровневый инструмент, а не часть повседневного API).

import compose/score
import compose/song
import compose/engine
import compose/progress

# Импорт сам по себе НЕ делает символы видимыми дальше: нужен явный
# `export`. Имя модуля для export — последний сегмент пути импорта,
# поэтому `export score`, а не `export compose/score` (последнее даёт
# «cannot export»).
{.warning[UnusedImport]: off.}
export score
export song
export engine
export progress