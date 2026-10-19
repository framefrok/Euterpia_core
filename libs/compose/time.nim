# libs/compose/time.nim
#
# Музыкальное время для «композиции как код» (issue #COMPOSE-001).
#
# Зачем: `score.nim` считает такты вручную (`for b in 1 .. BARS`), и сказать
# «bell играет первые 9 секунд, потом входит bass» без подсчёта тактов
# невозможно — а это главный UX-недостаток текущего API. Здесь появляется
# абстракция музыкального времени: `MusicalTime` (позиция) и `Duration`
# (длина) с удобным DSL (`4.bars`, `2.beats`, `1.bar`, `0.5.beat`) и
# функциями `barAt`/`beatAt`/`secondsAt`/`beatsAt`.
#
# Важно — это НЕ второй transport. Core уже даёт:
#   * `PpqTicksPerQuarter` (единственный источник разрешения PPQ);
#   * `positionFromSeconds` (единая арифметика секунды→BBT, issue #387).
# Compose их только использует: `totalTicks` считает тики тем же разрешением
# ядра, а `secondsAt`/`secondsOf` строятся на `positionFromSeconds`. Своего
# транспорт-движка и своей шкалы тиков здесь нет и быть не должно.
#
# Единица «доля» (`beats`) совпадает со `score.nim`: 1 доля = 1 четверть =
# `PpqTicksPerQuarter` тиков. `beatsPerBar` (по умолчанию 4 — размер 4/4)
# параметризует размер, поэтому 6/8 и 5/4 считаются тем же кодом.

import std/math

import transport
  # PpqTicksPerQuarter — разрешение ядра; positionFromSeconds — секунды↔BBT.

{.push raises: [].}

type
  MusicalTime* = object
    ## Позиция на музыкальной временной линии: целое число тактов и дробное
    ## число долей внутри такта. `bars` нормализовано (0-базное смещение от
    ## начала пьесы), `beats` в [0, beatsPerBar).
    bars*: int
    beats*: float32

  Duration* = object
    ## Длина: число тактов и дробное число долей. Хранится «как есть»
    ## (`4.bars + 1.beat` = bars:4, beats:1), нормализация не навязывается —
    ## `totalBeats` и `totalTicks` корректны для любых значений.
    bars*: int
    beats*: float32

# ============================================================================
# DSL: 4.bars, 2.beats, 1.bar, 0.5.beat
# ============================================================================
#
# Две формы каждого (`bar`/`bars`, `beat`/`beats`) и приём int/float: `1.bar`
# читается как «один такт», `0.5.beat` — как «половина доли». Без вариантов
# пришлось бы писать `bar(1)` и `beat(0.5)` — шумно в том месте, где время
# должно читаться как партитура.

proc bars*(n: int): Duration =
  ## Длина в целых тактах: `8.bars`.
  Duration(bars: n, beats: 0.0f32)

proc bar*(n: int): Duration =
  ## Единственный такт: `1.bar` (= `1.bars`).
  bars(n)

proc beats*(n: int): Duration =
  ## Длина в целых долях: `4.beats`.
  Duration(bars: 0, beats: float32(n))

proc beat*(n: int): Duration =
  ## Единственная доля: `1.beat`.
  beats(n)

proc beats*(n: float32): Duration =
  ## Дробная длина в долях: `0.5.beat`, `1.5.beats`.
  Duration(bars: 0, beats: n)

proc beat*(n: float32): Duration =
  ## Дробная доля: `0.5.beat`.
  beats(n)

# ============================================================================
# Арифметика длительностей
# ============================================================================

proc `+`*(a, b: Duration): Duration =
  ## Сложение длительностей: `8.bars + 2.beats`. `beats` не переносится в
  ## `bars` — нормализация делается при превращении в позицию (`beatsAt`).
  Duration(bars: a.bars + b.bars, beats: a.beats + b.beats)

proc `-`*(a, b: Duration): Duration =
  ## Вычитание длительностей: `16.bars - 4.bars`.
  Duration(bars: a.bars - b.bars, beats: a.beats - b.beats)

proc totalBeats*(d: Duration; beatsPerBar: float32 = 4.0f32): float32 =
  ## Длина в долях: `bars` приводится к долям через размер такта.
  ## `8.bars.totalBeats == 32.0` при 4/4.
  float32(d.bars) * beatsPerBar + d.beats

proc totalTicks*(d: Duration; beatsPerBar: float32 = 4.0f32): int32 =
  ## Длина в тиках ядра (`PpqTicksPerQuarter` на долю) — готова к `startTick`
  ## и `duration` в `NoteFormat`/`ClipFormat`. Тот же масштаб, что в
  ## `score.nim`/`song.nim`, поэтому клипы и ноты согласованы.
  int32(round(d.totalBeats(beatsPerBar) * float32(PpqTicksPerQuarter)))

# ============================================================================
# Позиции: barAt / beatAt / beatsAt / secondsAt
# ============================================================================

proc beatsAt*(beats: float32; beatsPerBar: float32 = 4.0f32): MusicalTime =
  ## Позиция из абсолютного числа долей: `beatsAt(32)` → такт 8 (при 4/4).
  ## Нормализует доли в такты: 32 доли = 8 тактов + 0 долей.
  if beatsPerBar <= 0.0f32:
    return MusicalTime(bars: 0, beats: beats)
  let total = max(0.0f32, beats)
  let b = int(floor(total / beatsPerBar))
  let r = total - float32(b) * beatsPerBar
  MusicalTime(bars: b, beats: r)

proc barAt*(bar: int; beatsPerBar: float32 = 4.0f32): MusicalTime =
  ## Позиция начала такта `bar` (0-базная): `barAt(8)` → такт 8, доля 0.
  beatsAt(float32(max(0, bar)) * beatsPerBar, beatsPerBar)

proc beatAt*(beat: float32; beatsPerBar: float32 = 4.0f32): MusicalTime =
  ## Позиция на доле `beat` (синоним `beatsAt` для партитурного чтения).
  beatsAt(beat, beatsPerBar)

proc secondsAt*(seconds: float32; tempo: float32;
                beatsPerBar: float32 = 4.0f32): MusicalTime =
  ## Позиция из секунд при темпе `tempo`. Строится на `positionFromSeconds`
  ## ядра (единая арифметика секунды↔BBT, issue #387) — своя шкала здесь не
  ## заводится. Ровно это и закрывает «bell играет первые 9 секунд».
  if tempo <= 0.0f32:
    return MusicalTime(bars: 0, beats: 0.0f32)
  let pos = positionFromSeconds(float64(seconds), float64(tempo),
                                int32(max(1, round(beatsPerBar))), 4'i32)
  # positionFromSeconds отдаёт четверти в quarterNotePosition — это и есть
  # наши доли (1 доля = 1 четверть). Переводим их в такты+доли.
  beatsAt(float32(pos.quarterNotePosition), beatsPerBar)

# ============================================================================
# Позиции: абсолютные координаты, смещение
# ============================================================================

proc totalBeats*(t: MusicalTime; beatsPerBar: float32 = 4.0f32): float32 =
  ## Абсолютная позиция в долях от начала пьесы.
  float32(t.bars) * beatsPerBar + t.beats

proc totalTicks*(t: MusicalTime; beatsPerBar: float32 = 4.0f32): int32 =
  ## Абсолютная позиция в тиках ядра — для `startTick` клипа/ноты.
  int32(round(t.totalBeats(beatsPerBar) * float32(PpqTicksPerQuarter)))

proc `+`*(t: MusicalTime; d: Duration; beatsPerBar: float32 = 4.0f32): MusicalTime =
  ## Позиция, сдвинутая на длительность: `barAt(8) + 4.bars`.
  beatsAt(t.totalBeats(beatsPerBar) + d.totalBeats(beatsPerBar), beatsPerBar)

proc secondsOf*(t: MusicalTime; tempo: float32;
                beatsPerBar: float32 = 4.0f32): float32 =
  ## Время позиции в секундах при темпе `tempo` (доля = четверть).
  if tempo <= 0.0f32:
    return 0.0f32
  float32(float64(t.totalBeats(beatsPerBar)) * 60.0 / float64(tempo))

# ============================================================================
# Вывод
# ============================================================================

proc `$`*(t: MusicalTime): string =
  ## Читаемая позиция: `8:0.0` = такт 8, доля 0.
  $t.bars & ":" & $t.beats

proc `$`*(d: Duration): string =
  ## Читаемая длина: `8b + 2.0` = 8 тактов и 2 доли.
  $d.bars & "b + " & $d.beats

{.pop.}
