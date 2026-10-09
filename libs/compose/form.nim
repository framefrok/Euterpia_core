# libs/compose/form.nim
#
# Секции и форма песни для «композиции как код» (issue #COMPOSE-002).
#
# Зачем: без понятия intro/verse/chorus сложная композиция превращается в
# набор циклов `for i in 0 ..< 8`. Секция — именованный участок формы с
# длиной; именно по именам потом адресуются партии (`bell.during("intro")`),
# а не по номерам тактов. `startBar` вычисляется автоматически при добавлении
# секций подряд, поэтому форма читается как партитура, а не как таблица
# смещений.
#
# Это музыкальная семантика верхнего слоя. В Core нет ни «куплетов», ни
# «дропов» — они живут здесь, в Compose. `Song` — только контейнер формы;
# связи с партиями/гармонией появятся в `arrangement.nim` (COMPOSE-008),
# поэтому здесь нет зависимости от `song`/`score` — избегаем циклов импорта.

import std/[math, strutils]

import compose/time
  # Duration DSL (8.bars, 4.bars) — секции задаются музыкальной длиной.

{.push raises: [].}

type
  SectionKind* = enum
    ## Роль секции в форме песни. `skCustom` — для нетривиальных случаев
    ## (interlude, hook), где стандартное имя не подходит.
    skIntro
    skVerse
    skPreChorus
    skChorus
    skDrop
    skBreak
    skBridge
    skOutro
    skCustom

  Section* = object
    ## Именованный участок формы: название, роль, стартовый такт и длина.
    ## `startBar` — 0-базное смещение от начала песни (считается при
    ## добавлении секций подряд в `Song`), `lengthBars` — длина в тактах.
    name*: string
    kind*: SectionKind
    startBar*: int
    lengthBars*: int

  Song* = object
    ## Песня как последовательность секций. Имя песни + форма. `endBar`
    ## (после последней секции) — общая длина; генераторы и анализатор
    ## используют его как границу.
    title*: string
    sections*: seq[Section]
    tempo*: float
    beatsPerBar*: float

# ============================================================================
# Имена ролей
# ============================================================================

proc kindName*(kind: SectionKind): string =
  ## Имя роли секции — для отчётов/отладки.
  case kind
  of skIntro: "intro"
  of skVerse: "verse"
  of skPreChorus: "pre-chorus"
  of skChorus: "chorus"
  of skDrop: "drop"
  of skBreak: "break"
  of skBridge: "bridge"
  of skOutro: "outro"
  of skCustom: "section"

# ============================================================================
# Song: построение формы
# ============================================================================

proc endBar*(song: Song): int
  # Объявлено заранее: `section` вызывает его до определения ниже.

proc composition*(title: string; tempo: float = 120.0;
                  beatsPerBar: float = 4.0): Song =
  ## Новая песня с темпом и размером. Пустая форма — секции добавляются
  ## через `section`. Темп/размер — свойства песни (а не Core-транспорта),
  ## чтобы форма знала, сколько длится в секундах (см. `secondsOf`).
  Song(title: title, sections: @[], tempo: tempo, beatsPerBar: beatsPerBar)

proc section*(song: var Song; name: string; length: Duration): Section =
  ## Добавить секцию с длиной `length` (напр. `8.bars`). Роль определяется
  ## по имени, если оно совпадает со стандартным (intro/verse/…), иначе
  ## `skCustom`. `startBar` = конец предыдущей секции, поэтому секции
  ## выстраиваются подряд без ручного счёта тактов. Возвращает добавленную
  ## секцию — удобно для цепочек и проверок.
  let bars = if length.bars > 0: length.bars else: max(1, round(length.beats / song.beatsPerBar).int)
  let start = endBar(song)
  var kind = skCustom
  case name.toLowerAscii
  of "intro": kind = skIntro
  of "verse": kind = skVerse
  of "pre-chorus", "prechorus", "pre_chorus", "build": kind = skPreChorus
  of "chorus", "hook": kind = skChorus
  of "drop": kind = skDrop
  of "break", "breakdown": kind = skBreak
  of "bridge": kind = skBridge
  of "outro": kind = skOutro
  else: kind = skCustom
  let s = Section(name: name, kind: kind, startBar: start,
                  lengthBars: max(1, bars))
  song.sections.add s
  s

proc section*(song: var Song; kind: SectionKind; length: Duration): Section =
  ## Добавить секцию, задав роль явно (напр. `song.section(skDrop, 4.bars)`).
  ## Имя берётся из роли.
  song.section(kindName(kind), length)

# ============================================================================
# Запросы к форме
# ============================================================================

proc endBar*(song: Song): int =
  ## Номер такта сразу за последней секцией = общая длина песни в тактах.
  if song.sections.len == 0:
    return 0
  let last = song.sections[^1]
  last.startBar + last.lengthBars

proc find*(song: Song; name: string): Section =
  ## Секция по имени (регистронезависимо). Если нет — секция-пустышка
  ## `skCustom` с длиной 0 (не падаем: часть `during("typo")` просто
  ## ничего не сыграет, а не уронит композицию).
  for s in song.sections:
    if s.name.toLowerAscii == name.toLowerAscii:
      return s
  Section(name: name, kind: skCustom, startBar: 0, lengthBars: 0)

proc hasSection*(song: Song; name: string): bool =
  ## Есть ли секция с таким именем.
  for s in song.sections:
    if s.name.toLowerAscii == name.toLowerAscii:
      return true
  false

proc sectionNames*(song: Song): seq[string] =
  ## Все имена секций по порядку.
  for s in song.sections:
    result.add s.name

proc sectionAt*(song: Song; bar: int): Section =
  ## Секция, которой принадлежит такт `bar`. Если между секциями или вне
  ## формы — пустышка (skCustom, длина 0). Нужно анализатору и генераторам,
  ## чтобы понять контекст точки на таймлайне.
  for s in song.sections:
    if bar >= s.startBar and bar < s.startBar + s.lengthBars:
      return s
  Section(name: "", kind: skCustom, startBar: 0, lengthBars: 0)

proc secondsOf*(song: Song; bar: int): float =
  ## Позиция такта `bar` в секундах при темпе песни (доля = четверть).
  ## Общая арифметика времени — та же, что в `time.secondsOf`, чтобы форма и
  ## время не расходились.
  let beats = float(bar) * song.beatsPerBar
  if song.tempo <= 0.0:
    return 0.0
  beats.float * 60.0 / song.tempo

proc lengthSeconds*(song: Song): float =
  ## Длина всей песни в секундах.
  song.secondsOf(song.endBar)

proc `$`*(song: Song): string =
  ## Читаемая форма: `Dark Trap [intro 0-8, verse 8-24, ...]`.
  var parts: seq[string]
  for s in song.sections:
    parts.add s.name & " " & $s.startBar & "-" & $(s.startBar + s.lengthBars)
  song.title & " [" & parts.join(", ") & "]"

{.pop.}
