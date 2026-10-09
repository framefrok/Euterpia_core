# libs/compose/arrangement.nim
#
# Композиционный слой: «что играет, когда, в какой секции» (#COMPOSE-008,
# #COMPOSE-024).
#
# Зачем: `song.nim` превращает `Arrangement` (партии) сразу в `ProjectFormat`.
# Между музыкальным замыслом и проектом нужен промежуточный слой, где пьеса —
# это форма (секции) + партии + адресация «играй это там-то». Тогда:
#   bell.play(theme).during("intro")
#   bass.play(bassPattern).during("verse", "chorus")
# читаются как партитура, а не как ручной подсчёт тактов, и компилируются в
# готовые `Part` (со `startTick`) для существующего `song.Arrangement`.
#
# Архитектура (issue):
#   Musical API (form/pattern/harmony) → Composition → (резолв) → Part'ы →
#   song.Arrangement → ProjectFormat → Core.
# Здесь `Composition` держит форму и «партитуры» партий, а `resolve`
# материализует их в Part'ы. Резолв детерминирован (без случайности), поэтому
# один и тот же замысел даёт один и тот же ProjectFormat (#COMPOSE-041).
#
# Важно: это НЕ второй Sequencer и НЕ второй Transport. Время берётся из
# `time.nim`/`transport` (PpqTicksPerQuarter), а партии уходят в тот же
# `score.Part`, что и раньше. Нового рантайм-движка повторов нет.

import compose/score
import compose/time
import compose/form
import compose/pattern
import compose/song
  # Arrangement/instrument/arrangement — резолв пьесы идёт в готовый song.Arrangement,
  # чтобы buildProject (song.nim) дальше делал ProjectFormat. Композиционный слой
  # не строит проект сам — он отдаёт партии в существующий конвейер (не дубль song).

{.push raises: [].}

type
  Voice* = object
    ## Партия в пьесе: инструмент (`song.Instrument`-совместимый тип ноды)
    ## и набор «партитур» — что и когда играть. `parts` — это размещённые
    ## партитуры (pattern/motif + секция), которые резолвятся в Part'ы.
    name*: string
    nodeType*: string
    notesName*: string
    plays*: seq[VoicePlay]

  VoicePlay* = object
    ## Размещение партитуры в секциях: `theme` играет в перечисленных секциях.
    ## `sections` пустые = играть во всей пьесе от начала.
    label*: string
    pattern*: Pattern
    sections*: seq[string]

  Composition* = object
    ## Пьеса: форма + голоса. Резолвится в `song.Arrangement` через `resolve`.
    song*: Song
    voices*: seq[Voice]

# ============================================================================
# Голоса
# ============================================================================

proc voice*(name, nodeType, notesName: string): Voice =
  ## Голос (партия) в пьесе. `nodeType`/`notesName` — совместимы с
  ## `song.instrument`, чтобы `resolve` сразу строил `PartEntry`.
  Voice(name: name, nodeType: nodeType, notesName: notesName, plays: @[])

proc play*(v: var Voice; label: string; pattern: Pattern): var Voice =
  ## Разместить партитуру `pattern` (метка `label`) — без секций (играет от
  ## начала). Возврат `var Voice` даёт fluent-цепочку
  ## `bell.play(theme).during("intro")`; секции задаёт `during`.
  v.plays.add VoicePlay(label: label, pattern: pattern, sections: @[])
  v

proc during*(v: var Voice; sections: varargs[string]) =
  ## Fluent-продолжение `play`: `bell.play(theme).during("intro")`. Меняет
  ## секции последней размещённой партитуры — читается как фраза. `varargs`,
  ## чтобы `.during("intro")` и `.during("verse", "chorus")` писались без `@[]`.
  ## Возвращает void, чтобы цепочка не требовала `discard`.
  if v.plays.len > 0:
    v.plays[^1].sections = @sections


# ============================================================================
# Композиция
# ============================================================================

proc piece*(name: string; tempo: float32 = 120.0): Composition =
  ## Новая пьеса с заданным темпом. Форма строится тем же `form.composition`,
  ## поэтому секции пьесы и секции `Song` — один механизм (не два транспорта
  ## формы). Имя `piece`, а не `composition`, чтобы не спорить с `form`.
  var s = composition(name, tempo)
  Composition(song: s, voices: @[])

proc section*(c: var Composition; name: string; length: Duration): var Composition =
  ## Добавить секцию в форму пьесы (делегируется в `form`).
  discard c.song.section(name, length)
  c

proc add*(c: var Composition; v: Voice) =
  ## Добавить голос в пьесу.
  c.voices.add v

# ============================================================================
# Резолв: секции+партитуры → Part'ы со startTick (COMPOSE-024)
# ============================================================================
#
# Каждая `VoicePlay` превращается в один `Part` на голос: если партитура
# играет в нескольких секциях, её копии склеиваются в одну партию, начиная с
# первой секции (между секциями — пауза неявная, т.к. ноты лежат по своим
# абсолютным тикам). Это «compile-time» раскладка — без рантайм-повторов.

proc barsToTicks(bars: int): int32 =
  ## Абсолютные тики начала такта `bars` (4/4, разрешение ядра).
  barAt(bars).totalTicks()

proc cycleMotif(m: Motif; bars: int): Motif =
  ## Повторить/обрезать мотив ровно до `bars` тактов (обёртка над score.cycle).
  if m.len == 0 or bars <= 0:
    return @[]
  let filled = cycle(m, bars)
  if filled.len <= bars:
    return filled
  filled[0 ..< bars]

proc resolveVoices(c: Composition; beatsPerBar: float32):
    seq[tuple[voice: Voice; part: Part; play: VoicePlay]] =
  ## Материализовать голоса в Part'ы. Для каждой партитуры строим партию по
  ## её секциям (или от начала, если секций нет), конвертируя pattern→Part
  ## через `toMotif`. Несколько секций одной партитуры — несколько копий,
  ## склеенных по абсолютным позициям.
  for v in c.voices:
    for pl in v.plays:
      if pl.sections.len == 0:
        # Играет от начала пьесы.
        result.add (v, pl.pattern.toPart(v.name, beatsPerBar), pl)
      else:
        # Собираем партию из партитуры, повторённой под каждую секцию.
        var combined: seq[Bar]
        var placed = false
        for secName in pl.sections:
          let sec = c.song.find(secName)
          if sec.lengthBars == 0:
            continue  # неизвестная секция — пропускаем
          let motif = pl.pattern.toMotif(beatsPerBar)
          # Заполняем ровно длиной секции: cycle мотива + обрезка по длине.
          let motifFull = cycleMotif(motif, sec.lengthBars)
          combined.add motifFull
          placed = true
        if placed:
          var part = Part(name: v.name)
          for b in combined:
            part.add b
          result.add (v, part, pl)

proc toArrangement*(c: Composition; tempo: float32 = 0.0f32;
                    beatsPerBar: float32 = 4.0f32): Arrangement =
  ## Резолв пьесы в `song.Arrangement` — готов к `song.buildProject`.
  ## Каждый голос = одна дорожка; партитуры склеены по секциям. Темп берётся
  ## из формы пьесы, если не передан явно.
  let t = if tempo > 0.0f32: tempo else: c.song.tempo
  var arr = arrangement(c.song.title, t)
  for r in c.resolveVoices(beatsPerBar):
    arr.add(instrument(r.voice.nodeType, r.voice.name, r.voice.notesName), r.part)
  arr

# ============================================================================
# Диагностика формы
# ============================================================================

proc isEmpty*(c: Composition): bool =
  ## Пустая ли пьеса: нет секций или нет голосов.
  c.song.sections.len == 0 or c.voices.len == 0

proc `$`*(c: Composition): string =
  ## Читаемая пьеса: форма + голоса.
  var s = c.song.title & " (" & $c.song.sections.len & " sections, " &
         $c.voices.len & " voices)"
  for sec in c.song.sections:
    s.add "\n  [" & $sec.startBar & "] " & sec.name & " " &
          $sec.lengthBars & " bars (" & kindName(sec.kind) & ")"
  for v in c.voices:
    s.add "\n  " & v.name & ": " & $v.plays.len & " plays"
  s

{.pop.}
