# libs/compose/scale.nim
#
# Лады и тональности для «композиции как код» (issue #COMPOSE-005).
#
# Зачем: мелодию на裸 нотах (`n(57,0.5); n(60,0.5)`) нельзя перенастроить —
# смена тональности требует переписать все pitch. Здесь лад — это правило
# («мажор от A»), а `degree(1..7)` даёт ступени. Меняешь `key` — мелодия
# сама переезжает: `minorScale("A")` и `minorScale("C")` различаются только
# корнем, а структура мелодии (`degree(1); degree(3); degree(5)`) та же.
#
# Это чисто музыкальная семантика верхнего слоя: в Core ладов нет и быть не
# должно (Core не знает про «минор» и «дорий»). Здесь — да.

import std/[math, strutils]

{.push raises: [].}

type
  ScaleKind* = enum
    ## Лад: набор полутонов от тоники в пределах октавы.
    skMajor
    skMinor
    skHarmonicMinor
    skMelodicMinor
    skPentatonic
    skBlues
    skDorian
    skPhrygian
    skLydian
    skMixolydian
    skLocrian
    skChromatic

  Scale* = object
    ## Тональность: корневая нота (MIDI pitch) и лад. `degree` считает
    ## ступени от корня с переносом в соседние октавы при выходе за лад.
    root*: int
    kind*: ScaleKind

# ============================================================================
# Полутоны ладов
# ============================================================================

proc scaleSteps*(kind: ScaleKind): seq[int] =
  ## Полутоновые смещения ступеней лада от тоники (в пределах октавы).
  ## Порядок = порядок ступеней, поэтому `degree(1)` — тоника, `degree(3)`
  ## — терция и т.д. Хроматический лад даёт все 12 — для пробных/хромати-
  ## ческих пассажей.
  case kind
  of skMajor:          @[0, 2, 4, 5, 7, 9, 11]
  of skMinor:          @[0, 2, 3, 5, 7, 8, 10]
  of skHarmonicMinor:  @[0, 2, 3, 5, 7, 8, 11]
  of skMelodicMinor:   @[0, 2, 3, 5, 7, 9, 11]
  of skPentatonic:     @[0, 2, 4, 7, 9]
  of skBlues:          @[0, 3, 5, 6, 7, 10]
  of skDorian:         @[0, 2, 3, 5, 7, 9, 10]
  of skPhrygian:       @[0, 1, 3, 5, 7, 8, 10]
  of skLydian:         @[0, 2, 4, 6, 7, 9, 11]
  of skMixolydian:     @[0, 2, 4, 5, 7, 9, 10]
  of skLocrian:        @[0, 1, 3, 5, 6, 8, 10]
  of skChromatic:      @[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]

proc scaleName*(kind: ScaleKind): string =
  ## Имя лада — для отчётов и отладки.
  case kind
  of skMajor: "major"
  of skMinor: "minor"
  of skHarmonicMinor: "harmonic minor"
  of skMelodicMinor: "melodic minor"
  of skPentatonic: "pentatonic"
  of skBlues: "blues"
  of skDorian: "dorian"
  of skPhrygian: "phrygian"
  of skLydian: "lydian"
  of skMixolydian: "mixolydian"
  of skLocrian: "locrian"
  of skChromatic: "chromatic"

# ============================================================================
# Имена нот: "A" → 69, "C#" → 61, "Bb4" → 70
# ============================================================================
#
# Нужно и здесь, и в `harmony` (аккорды задаются именами). Парсер общий —
# одна арифметика на всю библиотеку. Октава по умолчанию 4 (как в научной
# нотации: C4 = 60), поэтому `minorScale("A")` = минор от A4.

proc pitchClassOf(letter: char): int =
  ## Нотный класс буквы: c→0, d→2, e→4, f→5, g→7, a→9, b→11.
  case letter.toLowerAscii
  of 'c': 0
  of 'd': 2
  of 'e': 4
  of 'f': 5
  of 'g': 7
  of 'a': 9
  of 'b': 11
  else: 0

proc notePitch*(name: string): int =
  ## MIDI-питч из имени ноты: `"A"`→69, `"C#"`→61, `"Bb4"`→70, `"Db"`→61.
  ## Знаки # (диез) и b (бемоль) поддерживаются, опционально несколько;
  ## хвостовая цифра — октава (по умолчанию 4). Неразбираемое имя даёт
  ## класс C октавы 4 (60), а не падение: лад лучше построить хоть как-то,
  ## чем уронить композицию из-за опечатки в одном аккорде.
  var s = name.strip()
  if s.len == 0:
    return 60
  let pc = pitchClassOf(s[0])
  var alter = 0
  var idx = 1
  while idx < s.len and (s[idx] == '#' or s[idx] == 'b' or s[idx] == 'B'):
    # 'B' — бемоль только если не последняя и следующая не буква ноты; на
    # практике 'Bb' всегда бемоль. Регистр b/B различаем: b — бемоль.
    if s[idx] == 'b':
      alter.dec
    elif s[idx] == '#':
      alter.inc
    inc idx
  var octave = 4
  if idx < s.len:
    let rest = s[idx ..^ 1]
    try:
      octave = parseInt(rest)
    except ValueError:
      octave = 4
  (octave + 1) * 12 + pc + alter

proc noteName*(pitch: int): string =
  ## Имя ноты из MIDI-питча (диезы): 69 → `a4`, 61 → `c#4`. Совпадает с
  ## `score.pname`, но без импорта `score` — лад не должен зависеть от
  ## партитуры, только от чистоты именования.
  const Names = ["c", "c#", "d", "d#", "e", "f", "f#", "g",
                 "g#", "a", "a#", "b"]
  Names[pitch mod 12] & $(pitch div 12 - 1)

# ============================================================================
# Конструкторы ладов
# ============================================================================

proc scale*(root: int; kind: ScaleKind): Scale =
  ## Лад от ноты-MIDI: `scale(69, skMajor)` = A мажор.
  Scale(root: root, kind: kind)

proc scale*(root: string; kind: ScaleKind): Scale =
  ## Лад от имени ноты: `scale("A", skMajor)`.
  scale(notePitch(root), kind)

proc majorScale*(root: int): Scale = scale(root, skMajor)
proc minorScale*(root: int): Scale = scale(root, skMinor)
proc majorScale*(root: string): Scale = scale(notePitch(root), skMajor)
proc minorScale*(root: string): Scale = scale(notePitch(root), skMinor)

# ============================================================================
# Ступени
# ============================================================================

proc degree*(s: Scale; n: int): int =
  ## MIDI-питч n-й ступени (1-базная, как в теории музыки). Выход за
  ## пределы лада переносит в соседнюю октаву: `degree(8)` = тоника на
  ## октаву выше, `degree(-1)` — септима на октаву ниже (floorDiv корректно
  ## берёт и отрицательные). Это и есть «меняешь key — мелодия едет сама».
  let steps = scaleSteps(s.kind)
  let len = steps.len
  let idx = n - 1
  let oct = floorDiv(idx, len)
  let deg = idx - oct * len
  s.root + oct * 12 + steps[deg]

proc degrees*(s: Scale; ns: openArray[int]): seq[int] =
  ## Несколько ступеней сразу: `degrees(s, @[1, 3, 5])` → `@[тоника,3,5]`.
  for n in ns:
    result.add s.degree(n)

proc contains*(s: Scale; pitch: int): bool =
  ## Принадлежит ли питч ладу (безотносительно октавы).
  let steps = scaleSteps(s.kind)
  let rel = ((pitch - s.root) mod 12 + 12) mod 12
  rel in steps

proc stepsInOctave*(s: Scale): seq[int] =
  ## Все ступени одной октавы от корня: мажор от C → [60,62,64,65,67,69,71].
  for st in scaleSteps(s.kind):
    result.add s.root + st

proc transpose*(s: Scale; semis: int): Scale =
  ## Смена тональности на `semis` полутонов (тот же лад, другой корень).
  scale(s.root + semis, s.kind)

proc `==`*(a, b: Scale): bool =
  a.root == b.root and a.kind == b.kind

proc `$`*(s: Scale): string =
  ## Читаемая тональность: `a minor`, `c dorian`.
  noteName(s.root) & " " & scaleName(s.kind)

{.pop.}
