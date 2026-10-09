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
#   * `compose/time`     — музыкальное время (4.bars, barAt, secondsAt);
#   * `compose/scale`    — лады и ступени (minorScale, degree);
#   * `compose/harmony`  — аккорды и прогрессии (chord("Am"), progression);
#   * `compose/pattern`  — ритмические паттерны с приёмами (repeat, reverse,
#                          overlay, swing, humanize);
#   * `compose/rhythm`   — библиотека ритмов (tresillo, trap16, clave, DSL);
#   * `compose/random`   — детерминированный RNG (musicRandom, seed);
#   * `compose/form`     — секции и форма песни (intro/verse/chorus/drop);
#   * `compose/melody`   — аккорд-осведомлённая мелодия (chordTone/passing);
#   * `compose/variation` — развитие мотива (invert, retrograde, fragment);
#   * `compose/arrangement` — пьеса: play/during/build/harmony (компиляция);
#   * `compose/generators/drums` — барабанные связки и филлы (trapKit, fill);
#   * `compose/song`     — раскладка, инструменты, проверка, запись;
#   * `compose/engine`   — рендер в WAV;
#   * `compose/progress` — индикатор прогресса;
#   * `compose/builder`  — произвольный граф (импортируется отдельно: его
#     `Builder` — низкоуровневый инструмент, а не часть повседневного API).

import compose/score
import compose/time
import compose/scale
import compose/harmony
import compose/pattern
import compose/rhythm
import compose/random
import compose/form
import compose/melody
import compose/variation
import compose/arrangement
import compose/generators/drums
import compose/song
import compose/engine
import compose/progress

# Импорт сам по себе НЕ делает символы видимыми дальше: нужен явный
# `export`. Имя модуля для export — последний сегмент пути импорта,
# поэтому `export score`, а не `export compose/score` (последнее даёт
# «cannot export»).
{.warning[UnusedImport]: off.}
export score
export time
export scale
export harmony
export pattern
export rhythm
export random
export form
export melody
export variation
export arrangement
export drums
export song
export engine
export progress