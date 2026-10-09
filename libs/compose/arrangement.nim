# libs/compose/arrangement.nim
#
# Аранжировочный слой «композиции как код» (issues #COMPOSE-008, #COMPOSE-024,
# #COMPOSE-033, #COMPOSE-047 — начало).
#
# Зачем: `song.nim` умеет только «партия → дорожка с нуля», а `form.nim` —
# только «секции формы». Между ними — дыра: нельзя сказать «bell играет
# тему в intro и verse, bass входит с chorus». `Piece`/`Voice` этот мост:
#   * `Voice` = инструмент (name/nodeType/notesName) + список пьес (`Play`);
#   * `bell.play("theme", themePattern).during("intro")` — что и когда звучит;
#   * `.also("chorus")` — добавить секции; `.variant(k)` — вариация по секции;
#   * `toArrangement()` — компиляция в `song.Arrangement`: каждый голос
#     превращается в `Part` с правильным `startTick` (паузы там, где голос
#     молчит), т.е. в обычные Core clips/notes (#COMPOSE-024).
#
# Модель — CLIP-ориентированная, как Core: паттерн кладётся на «клип»
# (секцию), а пустые секции становятся паузами. Это compile-time
# трансформация, НЕ рантайм-движок (#COMPOSE-025): повторы и паузы
# разворачиваются в ноты сразу. Никакого второго секвенсора — на выходе те
# же `Part`/`NoteFormat`, что читает Core.

import std/[math, strutils, sequtils]

import project
  # NoteFormat — ноты проекта ядра (для `build`).

import compose/score
import compose/pattern
import compose/time
import compose/form
import compose/harmony
import compose/scale
import compose/melody
import compose/variation
import compose/song
  # song.Instrument/Arrangement/add — единый формат проекта ядра.

{.push raises: [].}

type
  TrackRole* = enum
    ## Роль дорожки (COMPOSE-009, задел): кем голос является в миксе.
    ## Роль пока — маркер для чтения и будущих команд (`mute roleBass`,
    ## `all roleLead: transpose 12`); на компиляцию не влияет.
    roleDrums
    roleBass
    roleSubBass
    roleLead
    roleCounterLead
    rolePad
    roleChord
    roleArp
    roleMelody
    roleTexture
    roleFx
    roleVocal
    rolePercussion
    roleCustom

  Play* = object
    ## Одно размещение пьесы: именованный паттерн, звучащий в наборе секций
    ## с необязательной вариацией. `variant > 0` применяет приём развития
    ## (`variation.applyVariant`) — независимо от других секций (#COMPOSE-033).
    ## `role` — роль дорожки (COMPOSE-009); `melody` — мелодия вместо паттерна
    ## (рендерится поверх гармонии пьесы при `build`).
    partName*: string
    pattern*: Pattern
    hasPattern*: bool
    tune*: Melody
    hasMelody*: bool
    role*: TrackRole
    sections*: seq[string]
    variant*: int

  Voice* = object
    ## Голос: инструмент + несколько размещений пьес. Несколько `play`
    ## позволяют одной дорожке звучать разными паттернами в разных секциях
    ## (например, бас: паттерн в verse, филл в drop). `params` — переопределения
    ## параметров ноды (level, tone, …), уходят в `song.Instrument`.
    trackName*: string
    nodeType*: string
    notesName*: string
    program*: int
    params*: seq[tuple[name: string; value: float32]]
    plays*: seq[Play]

  Piece* = object
    ## Композиция: форма (`Song`) + голоса + гармония для мелодий.
    ## Компилируется в `song.Arrangement` (`toArrangement`) и в абсолютные
    ## ноты (`build`).
    song*: Song
    voices*: seq[Voice]
    prog*: Progression
      ## Гармония пьесы — по ней рендерятся все мелодии (`harmony(...)`).
    key*: Scale
      ## Тональность — ступени мелодий (`degree`); по умолчанию C major,
      ## задаётся вместе с гармонией: `song.harmony(prog, minorScale("A"))`.

# ============================================================================
# Голоса
# ============================================================================

proc voice*(trackName, nodeType, notesName: string; program: int = 0): Voice =
  ## Голос-дорожка. `program` — MIDI-номер инструмента (0 — как раньше).
  Voice(trackName: trackName, nodeType: nodeType, notesName: notesName,
        program: program)

# Размещения пьес мутируют `var Voice`/`var Piece` и возвращают ту же
# переменную: цепочка `bell.play("theme", theme).during("intro")` работает
# через проки `var` (возврат `var T` сохраняет привязку к исходной
# переменной — method-call syntax получает тот же локатор). Все цепочки
# `discardable`: и голый `play(...).during(...)`, и `discard play(...).during
# (...)` законны — обе формы используются в композициях и тестах.
proc play*(v: var Voice; partName: string; p: Pattern;
           role: TrackRole = roleCustom;
           sections: varargs[string]): var Voice {.discardable.} =
  ## Разместить паттерн в голосе. Секции можно задать здесь же или позже
  ## через `.during(...)`.
  var pl = Play(partName: partName, pattern: p, hasPattern: true,
                role: role, variant: 0)
  if sections.len > 0:
    pl.sections = @sections
  v.plays.add pl
  v

proc play*(v: var Voice; partName: string; m: Melody;
           role: TrackRole = roleCustom;
           sections: varargs[string]): var Voice {.discardable.} =
  ## Разместить мелодию: при компиляции она рендерится поверх гармонии
  ## пьесы (`harmony`), а не по фиксированным высотам (#COMPOSE-006).
  var pl = Play(partName: partName, tune: m, hasMelody: true,
                role: role, variant: 0)
  if sections.len > 0:
    pl.sections = @sections
  v.plays.add pl
  v

proc during*(v: var Voice; names: varargs[string]): var Voice {.discardable.} =
  ## `...play(...).during("intro")` — задать (заменить) секции последней
  ## пьесы голоса.
  if v.plays.len > 0:
    v.plays[^1].sections = @names
  v

proc also*(v: var Voice; names: varargs[string]): var Voice {.discardable.} =
  ## `...play(...).also("chorus")` — добавить секции последней пьесы.
  if v.plays.len > 0:
    for n in names:
      if n notin v.plays[^1].sections:
        v.plays[^1].sections.add n
  v

proc variant*(v: var Voice; k: int): var Voice {.discardable.} =
  ## `...play(...).variant(2)` — вариация последней пьесы (#COMPOSE-033).
  if v.plays.len > 0:
    v.plays[^1].variant = k
  v

proc setParam*(v: var Voice; name: string; value: float32) =
  ## Переопределить параметр ноды голоса (level, tone, bars, …) — тот же
  ## механизм, что у `song.Instrument.setParam`.
  v.params.add (name, value)

# ============================================================================
# Композиция
# ============================================================================

proc piece*(title: string; tempo: float = 120.0;
            beatsPerBar: float = 4.0): Piece =
  ## Композиция с формой и темпом. Секции добавляются через `section`,
  ## голоса — через `play`/`add`, гармония мелодий — через `harmony`.
  Piece(song: form.composition(title, tempo, beatsPerBar),
        prog: Progression(barsPerChord: 1), key: scale(60, skMajor))

proc section*(c: var Piece; name: string; length: Duration): Piece =
  ## Добавить секцию в форму (делегирует `form.Song.section`).
  discard c.song.section(name, length)
  c

proc add*(c: var Piece; v: Voice) =
  ## Добавить голос в композицию.
  c.voices.add v

proc isEmpty*(c: Piece): bool =
  ## Пустая композиция: нет ни одного голоса (секции без голосов — тоже
  ## пусто, т.к. звука нет).
  c.voices.len == 0

# ============================================================================
# Запросы к форме и гармонии
# ============================================================================

proc find*(c: Piece; name: string): Section =
  ## Секция по имени (делегирует `form.find`; неизвестная — пустышка с
  ## длиной 0). Удобно проверять раскладку: `song.find("chorus").startBar`.
  c.song.find(name)

proc hasSection*(c: Piece; name: string): bool =
  c.song.hasSection(name)

proc endBar*(c: Piece): int =
  ## Общая длина формы в тактах.
  c.song.endBar

proc harmony*(c: var Piece; p: Progression; s: Scale): var Piece {.discardable.} =
  ## Гармония и тональность пьесы: по ним рендерятся все размещённые мелодии
  ## (`chordTone`, `degree`, `stack`) при `build`/`toArrangement`
  ## (#COMPOSE-004/005/006).
  c.prog = p
  c.key = s
  c

# ============================================================================
# Piece-level play/during: адресация без ручного создания голосов
# ============================================================================
#
# `song.play("bell", theme, roleLead).during("intro")` — компактная форма
# повседневного API: голос создаётся при первом упоминании (нода
# `euterpia.osc`, нотное имя `<track>_notes`; тип ноды задаётся `nodeType`).
# Возврат `var Piece` (а не `var Voice`) надёжен: указатель на голос внутри
# `seq` протух бы при следующем `add`, а сама переменная пьесы живёт у
# вызывающего.

proc ensureVoice(c: var Piece; trackName: string; nodeType: string): int =
  ## Индекс голоса: существующий по имени или созданный с нодой `nodeType`.
  for i, v in c.voices:
    if v.trackName == trackName:
      return i
  c.voices.add voice(trackName, nodeType, trackName & "_notes")
  c.voices.len - 1

proc play*(c: var Piece; trackName: string; p: Pattern;
           role: TrackRole = roleCustom; nodeType = "euterpia.osc";
           sections: varargs[string]): var Piece {.discardable.} =
  ## Разместить паттерн на дорожке `trackName` (создаётся при первом
  ## вызове). `role` — роль дорожки (#COMPOSE-009); `nodeType` применяется
  ## только при создании голоса.
  let i = c.ensureVoice(trackName, nodeType)
  var pl = Play(partName: p.name, pattern: p, hasPattern: true,
                role: role, variant: 0)
  if sections.len > 0:
    pl.sections = @sections
  c.voices[i].plays.add pl
  c

proc play*(c: var Piece; trackName: string; m: Melody;
           role: TrackRole = roleCustom; nodeType = "euterpia.osc";
           sections: varargs[string]): var Piece {.discardable.} =
  ## Разместить мелодию на дорожке: высоты вычислятся поверх `harmony`
  ## пьесы при компиляции.
  let i = c.ensureVoice(trackName, nodeType)
  var pl = Play(partName: m.name, tune: m, hasMelody: true,
                role: role, variant: 0)
  if sections.len > 0:
    pl.sections = @sections
  c.voices[i].plays.add pl
  c

proc during*(c: var Piece; names: varargs[string]): var Piece {.discardable.} =
  ## `...play(...).during("intro", "chorus")` — секции последнего
  ## размещения (последнего добавленного голоса).
  if c.voices.len > 0 and c.voices[^1].plays.len > 0:
    c.voices[^1].plays[^1].sections = @names
  c

proc also*(c: var Piece; names: varargs[string]): var Piece {.discardable.} =
  ## `...play(...).also("drop")` — добавить секции последнему размещению.
  if c.voices.len > 0 and c.voices[^1].plays.len > 0:
    for n in names:
      if n notin c.voices[^1].plays[^1].sections:
        c.voices[^1].plays[^1].sections.add n
  c

proc variant*(c: var Piece; k: int): var Piece {.discardable.} =
  ## `...play(...).variant(2)` — вариация последнего размещения
  ## (независимо от других секций, #COMPOSE-033).
  if c.voices.len > 0 and c.voices[^1].plays.len > 0:
    c.voices[^1].plays[^1].variant = k
  c

proc setParam*(c: var Piece; trackName: string; name: string;
               value: float32): var Piece {.discardable.} =
  ## Параметр ноды дорожки: `song.setParam("bass", "level", -9.0f32)`.
  ## Голос создаётся, если его ещё нет (как в `play`).
  let i = c.ensureVoice(trackName, "euterpia.osc")
  c.voices[i].params.add (name, value)
  c


# ============================================================================
# Компиляция: секции + пьесы → такты формы (#COMPOSE-008/024/033/047)
# ============================================================================
#
# Для каждого голоса строим `Part`, длина которого = вся форма (в тактах):
#   * секции, где голос звучит, заполняются паттерном/мелодией (повтор/обрез
#     до длины секции — compile-time трансформация, без рантайм-движка
#     повторов, #COMPOSE-025);
#   * секции, где молчит, — паузой той же длины.
# Такт всегда дополняется паузой до `beatsPerBar`: паттерн в 2 доли звучит
# раз в такт, а не «плывёт» по хвостам событий — сетка такта = сетка клипа
# Core. `startTick` считается автоматически: Part начинается с начала песни,
# молчащие секции — это паузы, которые и сдвигают звучащие. Несколько пьес в
# одной секции сливаются по времени (`mergeEvents`): одновременные ноты
# становятся аккордом. Вариация (variant>0) — `variation` (#COMPOSE-007/033).

proc padBar(b: Bar; beatsPerBar: float): Bar =
  ## Дополнить такт паузой до полной сетки (паттерн может быть короче такта).
  result = b
  var total = 0.0
  for e in b.events:
    total += e.beats
  let missing = beatsPerBar - total
  if missing > 1e-6:
    result.events.add r(missing)

proc fillPatternBars(pat: Pattern; bars: int; variant: int;
                     beatsPerBar: float): seq[Bar] =
  ## `bars` тактов паттерна: мотив (`toMotif`), опционально вариация, затем
  ## повтор/обрез ровно до `bars` — и каждый такт на полную сетку.
  if bars <= 0:
    return @[]
  var motif = pat.toMotif(beatsPerBar)
  if motif.len == 0:
    # Пустой паттерн — секция-пауза (иначе cycle делит на ноль).
    for _ in 0 ..< bars:
      result.add bar(r(beatsPerBar))
    return
  if variant > 0:
    motif = motif.applyVariantMotif(variant)
  for i in 0 ..< bars:
    result.add padBar(motif[i mod motif.len], beatsPerBar)

proc fillMelodyBars(tune: Melody; sec: Section; bars: int;
                    prog: Progression; key: Scale; beatsPerBar: float;
                    variant: int): seq[Bar] =
  ## `bars` тактов мелодии. Каждая реплика фразы РЕНДЕРИТСЯ ЗАНОВО со
  ## стартовым тактом `sec.startBar + уже заполнено` — поэтому аккорды
  ## прогрессии идут по форме: фраза длиной в такт повторяется такт в такт
  ## по своему аккорду, а многотактовая фраза получает смену гармонии внутри
  ## себя (#COMPOSE-006: мелодия живёт поверх гармонии, а не поверх
  ## фиксированных высот).
  if bars <= 0:
    return @[]
  while result.len < bars:
    let repStartBar = sec.startBar + result.len
    let evs = tune.render(prog, key, startBar = repStartBar)
    var len = 0.0
    for e in evs:
      len += e.beats
    var phrase = rawPattern(tune.name, evs, len).toMotif(beatsPerBar)
    if phrase.len == 0:
      # Мелодия без шагов — такт паузы, чтобы цикл двигался дальше.
      result.add bar(r(beatsPerBar))
      continue
    if variant > 0:
      phrase = phrase.applyVariantMotif(variant)
    for b in phrase:
      if result.len >= bars:
        break
      result.add padBar(b, beatsPerBar)

proc composeSection(p: Play; s: Section; bars: int; prog: Progression;
                    key: Scale; beatsPerBar: float): seq[Bar] =
  ## Такты одной пьесы внутри секции: паттерн или отрендеренная мелодия.
  if bars <= 0:
    return @[]
  if p.hasMelody:
    return fillMelodyBars(p.tune, s, bars, prog, key, beatsPerBar, p.variant)
  elif p.hasPattern:
    return fillPatternBars(p.pattern, bars, p.variant, beatsPerBar)
  for _ in 0 ..< bars:
    result.add bar(r(beatsPerBar))

proc sameSection(a, b: string): bool =
  ## Совпадение имён секций без учёта регистра (как `form.find`).
  a.toLowerAscii == b.toLowerAscii

proc composePart(v: Voice; frm: Song; prog: Progression; key: Scale;
                 beatsPerBar: float): Part =
  ## `Part` голоса по всей форме: по секции на такт, молчащие секции — паузы,
  ## несколько пьес одной секции — слиянием по времени.
  result = part(v.trackName)
  for s in frm.sections:
    let sectionBars = max(0, s.lengthBars)
    # Холст секции: такты-паузы; поверх — все пьесы, чьи секции совпали.
    var collected: seq[Bar]
    for _ in 0 ..< sectionBars:
      collected.add bar(r(beatsPerBar))
    for pl in v.plays:
      var inSection = false
      for name in pl.sections:
        if sameSection(s.name, name):
          inSection = true
          break
      if not inSection:
        continue
      let bars = composeSection(pl, s, sectionBars, prog, key, beatsPerBar)
      for i in 0 ..< min(sectionBars, bars.len):
        collected[i] = Bar(
          events: mergeEvents(collected[i].events, bars[i].events, beatsPerBar),
          vel: max(collected[i].vel, bars[i].vel))
    for b in collected:
      result.add b

# ============================================================================
# Компиляция композиции: build (абсолютные ноты) и toArrangement (#COMPOSE-024)
# ============================================================================

proc hasSoundNotes(p: Part): bool =
  ## Есть ли в партии хоть одна нота (а не только паузы).
  for b in p.bars:
    for e in b.events:
      if e.pitches.len > 0:
        return true
  false

proc build*(c: Piece): seq[NoteFormat] =
  ## Ноты всей пьесы с абсолютными позициями: `startTick` отсчитывается от
  ## начала песни (молчащие секции — паузы), канал = индекс голоса. Это тот
  ## же результат, что попадёт в клипы Core, но без построения проекта —
  ## проверить аранжировку до генерации `ProjectFormat` (#COMPOSE-008/046).
  var channel = 0
  for v in c.voices:
    let p = composePart(v, c.song, c.prog, c.key, c.song.beatsPerBar)
    let notes = p.toNotes(channel = channel mod 16)
    if notes.len > 0:
      result.add notes
    inc channel

proc toArrangement*(c: Piece; sampleRate: float32 = 48000.0f32): song.Arrangement =
  ## Скомпилировать композицию в `song.Arrangement` (готовый к `writeProject`
  ## /`toJson`/`validate`/`render`). Имя/темп — из формы. Клип каждой дорожки
  ## покрывает всю песню, поэтому все ноты лежат внутри клипа и их позиции
  ## совпадают с `build`. Голос без звука не даёт дорожки.
  result = song.arrangement(c.song.title, float32(c.song.tempo), sampleRate)
  for v in c.voices:
    let p = composePart(v, c.song, c.prog, c.key, c.song.beatsPerBar)
    if not p.hasSoundNotes:
      continue
    var inst = song.instrument(v.nodeType, v.trackName, v.notesName)
    for pv in v.params:
      inst.params.add pv
    result.add(inst, p)

proc sectionCount*(c: Piece): int =
  ## Число секций формы.
  c.song.sections.len

proc sectionNames*(c: Piece): seq[string] =
  ## Имена секций по порядку.
  c.song.sections.mapIt(it.name)

proc voiceNames*(c: Piece): seq[string] =
  ## Имена дорожек голосов по порядку.
  c.voices.mapIt(it.trackName)

proc `$`*(c: Piece): string =
  ## Читаемая композиция: форма, голоса и их секции.
  var voices: seq[string]
  for v in c.voices:
    for p in v.plays:
      let win = if p.sections.len > 0: "[" & p.sections.join(",") & "]" else: ""
      voices.add v.trackName & "=" & p.partName & win
  c.song.title & " (" & $c.song.sections.len & " sections): " & voices.join(", ")

{.pop.}
