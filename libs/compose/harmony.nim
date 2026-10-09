# libs/compose/harmony.nim
#
# Аккорды и прогрессии для «композиции как код» (issue #COMPOSE-004).
#
# Зачем: сейчас аккорды задаются вручную (`proc chord(name): seq[int] = …` с
# хардкодом в каждой композиции). Это не масштабируется и не выражает
# гармонию как модель. Здесь аккорд — это корень + качество + обращение, а
# `chord("Am")`/`chord("G7")` разбирают привычные обозначения. Мелодия и
# бас смогут спрашивать «какие ноты сейчас звучат» (`notes()`), а генератор —
# «какая ступень здесь ударная» (`degreeOf`), вместо того чтобы гонять pitch
# вручную (issue #COMPOSE-006 строится поверх этого).
#
# Чистая музыкальная семантика верхнего слоя: в Core про «Am» и «доминант-
# септаккорд» знать нельзя — здесь можно и нужно.

import std/[math, algorithm, strutils, sequtils]

import compose/scale
  # notePitch/noteName — общий парсер имён нот, чтобы «Am» и лад «A minor»
  # считали корень одной арифметикой.

{.push raises: [].}

type
  ChordQuality* = enum
    ## Качество аккорда: какие интервалы над корнем.
    cqMajor
    cqMinor
    cqDominant7
    cqMajor7
    cqMinor7
    cqDiminished
    cqAugmented
    cqSus2
    cqSus4
    cqMinorMajor7
    cqDiminished7

  Chord* = object
    ## Аккорд: корень (MIDI pitch), качество и обращение (0 — основное
    ## положение; 1/2 — первый/второй перевертыши, т.е. терция/квинта в
    ## басу). Обращение — это аранжировочное решение, `notes()` его учтет.
    root*: int
    quality*: ChordQuality
    inversion*: int

# ============================================================================
# Интервалы качеств
# ============================================================================

proc chordSteps*(quality: ChordQuality): seq[int] =
  ## Полутоновые интервалы аккорда от корня. Порядок сверху вниз определяет
  ## обращение: при inversion>0 нижние ноты уезжают на октаву вверх.
  case quality
  of cqMajor:        @[0, 4, 7]
  of cqMinor:        @[0, 3, 7]
  of cqDominant7:    @[0, 4, 7, 10]
  of cqMajor7:       @[0, 4, 7, 11]
  of cqMinor7:       @[0, 3, 7, 10]
  of cqDiminished:   @[0, 3, 6]
  of cqAugmented:    @[0, 4, 8]
  of cqSus2:         @[0, 2, 7]
  of cqSus4:         @[0, 5, 7]
  of cqMinorMajor7:  @[0, 3, 7, 11]
  of cqDiminished7:  @[0, 3, 6, 9]

proc qualityName*(quality: ChordQuality): string =
  case quality
  of cqMajor: ""
  of cqMinor: "m"
  of cqDominant7: "7"
  of cqMajor7: "maj7"
  of cqMinor7: "m7"
  of cqDiminished: "dim"
  of cqAugmented: "aug"
  of cqSus2: "sus2"
  of cqSus4: "sus4"
  of cqMinorMajor7: "m(maj7)"
  of cqDiminished7: "dim7"

proc chord*(root: int; quality: ChordQuality; inversion: int = 0): Chord =
  ## Аккорд от ноты-MIDI: `chord(60, cqMinor)` = C минор.
  Chord(root: root, quality: quality, inversion: inversion)

proc notes*(c: Chord): seq[int] =
  ## Ноты аккорда как MIDI-питчи, с учётом обращения. Обращение 1 поднимает
  ## корень на октаву (терция в басу), 2 — корень и терцию (квинта в басу).
  let steps = chordSteps(c.quality)
  var raw = steps.mapIt(c.root + it)
  let inv = ((c.inversion mod max(1, steps.len)) + max(1, steps.len)) mod max(1, steps.len)
  for i in 0 ..< inv:
    if i < raw.len:
      raw[i] += 12
  raw.sort()
  raw

# ============================================================================
# Разбор обозначений: Am, G7, Cmaj7, F#m7, Bb
# ============================================================================

proc chord*(name: string): Chord =
  ## Аккорд из обозначения: `"Am"`→A minor, `"G7"`→G доминантсепт,
  ## `"Cmaj7"``, `"F#m7"`, `"Bb"`, `"Dm7"`, `"Esus4"`, `"Cdim"`.
  ##
  ## Корень (буква + знаки) разбирается общим с ладом парсером (`notePitch`),
 ## поэтому «Am» и лад «A minor» — один и тот же A. Неизвестное качество
  ## трактуется как мажор, а неразбираемый корень — как C: композиция не
  ## должна падать из-за одного непонятого аккорда.
  var s = name.strip()
  if s.len == 0:
    return Chord(root: 60, quality: cqMajor)
  # Корень: буква + знаки (до первого символа качества).
  var rootEnd = 1
  while rootEnd < s.len and (s[rootEnd] == '#' or s[rootEnd] == 'b' or s[rootEnd] == 'B'):
    inc rootEnd
  let rootName = s[0 ..< rootEnd]
  let qualityStr = s[rootEnd ..^ 1]
  let root = notePitch(rootName)
  var quality: ChordQuality
  case qualityStr.toLowerAscii
  of "", "maj": quality = cqMajor
  of "m", "min", "-": quality = cqMinor
  of "7", "dom7": quality = cqDominant7
  of "maj7", "m7+", "M7": quality = cqMajor7
  of "m7", "min7", "-7": quality = cqMinor7
  of "dim", "o": quality = cqDiminished
  of "dim7": quality = cqDiminished7
  of "aug", "+": quality = cqAugmented
  of "sus2": quality = cqSus2
  of "sus4", "sus": quality = cqSus4
  of "m(maj7)", "minmaj7": quality = cqMinorMajor7
  else: quality = cqMajor
  Chord(root: root, quality: quality, inversion: 0)

proc chordName*(c: Chord): string =
  ## Обозначение аккорда: A minor → `am`, C мажор → `c`, G доминантсепт → `g7`.
  let q = qualityName(c.quality)
  # Кто короче в записи: покажем корень одной буквой + качество.
  let n = noteName(c.root)
  if q.len == 0:
    n
  else:
    n & (if q[0] in {'a'..'z'}: q else: q)

proc transpose*(c: Chord; semis: int): Chord =
  ## Транспозиция аккорда на `semis` полутонов (обращение сохраняется).
  chord(c.root + semis, c.quality, c.inversion)

# ============================================================================
# Аккордовые ступени (основа для chord-aware мелодии, #COMPOSE-006)
# ============================================================================

proc rootPitch*(c: Chord): int =
  ## Основной тон с учётом обращения — что реально в басу.
  let ns = c.notes()
  if ns.len == 0: c.root else: ns[0]

proc chordTone*(c: Chord; degree: int): int =
  ## degree-я нота аккорда (1-базная, как у лада): 1=корень/бас, 3=терция,
  ## 5=квинта, 7=септима. Выход за число нот переносит на октаву — так
  ## мелодия может «идти по аккорду» в любом регистре.
  let ns = c.notes()
  let len = ns.len
  # floorDiv корректно берёт и отрицательные степени (chordTone(0) = септима
  # на октаву ниже), поэтому проходящие/заходящие тоны мелодии не падают.
  let idx = degree - 1
  let oct = floorDiv(idx, len)
  let deg = idx - oct * len
  ns[deg] + oct * 12

proc contains*(c: Chord; pitch: int): bool =
  ## Принадлежит ли питч аккорду (безотносительно октавы).
  let rel = ((pitch - c.root) mod 12 + 12) mod 12
  rel in chordSteps(c.quality)

# ============================================================================
# Прогрессии
# ============================================================================

type
  Progression* = object
    ## Последовательность аккордов, обычно на такт каждый. `chordAt(bar)`
    ## берёт аккорд по номеру такта с зацикливанием; `degreeAt` — его
    ## ступень; `rootAt`/`notesAt` — корень/ноты для генераторов.
    chords*: seq[Chord]
    barsPerChord*: int
      ## Сколько тактов держится каждый аккорд (1 — аккорд на такт).

proc progression*(names: openArray[string]; barsPerChord: int = 1): Progression =
  ## Прогрессия из обозначений: `progression(@["Am","Em","G","G"])`.
  var chords: seq[Chord]
  for n in names:
    chords.add chord(n)
  Progression(chords: chords, barsPerChord: max(1, barsPerChord))

proc progression*(chords: openArray[Chord]; barsPerChord: int = 1): Progression =
  ## Прогрессия из готовых аккордов (если нужны обращения).
  Progression(chords: @chords, barsPerChord: max(1, barsPerChord))

proc chordAt*(p: Progression; bar: int): Chord =
  ## Аккорд на такте `bar` (0-базный), с зацикливанием по длине прогрессии.
  if p.chords.len == 0:
    return Chord(root: 60, quality: cqMajor)
  let slot = (bar div p.barsPerChord) mod p.chords.len
  p.chords[slot]

proc rootAt*(p: Progression; bar: int): int =
  ## Корень аккорда на такте `bar`.
  p.chordAt(bar).root

proc notesAt*(p: Progression; bar: int): seq[int] =
  ## Ноты аккорда на такте `bar` — чтобы bass/pad знали, что играть.
  p.chordAt(bar).notes()

proc degreeAt*(p: Progression; bar: int; degree: int): int =
  ## degree-я ступень аккорда на такте `bar` (chordTone через время).
  p.chordAt(bar).chordTone(degree)

proc transpose*(p: Progression; semis: int): Progression =
  ## Транспозиция всей прогрессии.
  progression(p.chords.mapIt(it.transpose(semis)), p.barsPerChord)

proc `$`*(c: Chord): string = chordName(c)

proc `$`*(p: Progression): string =
  ## Читаемая прогрессия: `am | em | g | g`.
  p.chords.mapIt(chordName(it)).join(" | ")

{.pop.}
