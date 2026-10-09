# libs/compose/analyze.nim
#
# Анализ композиции (issue #COMPOSE-031).
#
# Зачем: оценить пьесу ДО рендера — длину, темп, тональность, форму, дорожки,
# плотность. Считается по модели (`Piece.build`), поэтому отчёт доступен и без
# проекта, а его числа детерминированы (один seed — один отчёт). Это основа для
# будущих оценок качества и batch-генерации (#COMPOSE-050/051), но без ML:
# обычный rule-based подсчёт.
#
# Замечания — не здесь: музыкальные проблемы ищет `validate(Piece)`, а этот
# модуль только описывает, что получилось.

import std/[math, strutils]

import compose/form
import compose/harmony
import compose/scale
import compose/arrangement
  # Piece/Voice/TrackRole/roleName/build + Section.

{.push raises: [].}

type
  SectionInfo* = object
    ## Секция в отчёте: имя, роль и место в форме.
    name*: string
    kind*: string
    startBar*: int
    lengthBars*: int

  TrackInfo* = object
    ## Дорожка в отчёте: имя, роль и сколько нот.
    name*: string
    role*: string
    notes*: int

  CompositionReport* = object
    ## Отчёт о композиции: метаданные, форма, дорожки, плотность.
    title*: string
    tempo*: float
    key*: string
    lengthBars*: int
    lengthSeconds*: float
    sections*: seq[SectionInfo]
    tracks*: seq[TrackInfo]
    totalNotes*: int
    density*: float
      ## Нот на такт (по всей пьесе).
    chordChanges*: int
      ## Сколько раз меняется аккорд за пьесу (по прогрессии).
    automationLanes*: int

proc analyze*(c: Piece): CompositionReport =
  ## Отчёт о пьесе: длина, темп, тональность, секции, дорожки, плотность,
  ## смены гармонии, дорожки автоматизации (COMPOSE-031).
  result.title = c.song.title
  result.tempo = c.song.tempo
  result.key = $c.key
  result.lengthBars = c.song.endBar
  result.lengthSeconds = c.song.lengthSeconds
  for s in c.song.sections:
    result.sections.add SectionInfo(
      name: s.name, kind: kindName(s.kind), startBar: s.startBar,
      lengthBars: s.lengthBars)

  # Ноты считаем той же компиляцией, что уйдёт в клипы (`build`), а по каналам
  # раскладываем их обратно по голосам: канал = индекс голоса.
  let notes = c.build()
  result.totalNotes = notes.len
  if result.lengthBars > 0:
    result.density = float(notes.len) / float(result.lengthBars)
  var perChannel: seq[int]
  for n in notes:
    let ci = int(n.channel)
    while perChannel.len <= ci:
      perChannel.add 0
    inc perChannel[ci]
  for i, v in c.voices:
    var role = roleCustom
    for p in v.plays:
      if p.role != roleCustom:
        role = p.role
        break
    var count = 0
    if i < perChannel.len:
      count = perChannel[i]
    result.tracks.add TrackInfo(name: v.trackName, role: roleName(role),
                                notes: count)

  if c.prog.chords.len > 1 and result.lengthBars > 1:
    var prev = c.prog.chordAt(0)
    for b in 1 ..< result.lengthBars:
      let cur = c.prog.chordAt(b)
      if cur.root != prev.root or cur.quality != prev.quality:
        inc result.chordChanges
      prev = cur
  result.automationLanes = c.automation.len

proc `$`*(r: CompositionReport): string =
  ## Читаемый отчёт (человеку в терминал).
  result = r.title & "\n"
  result.add "  " & $r.tempo & " BPM, тональность: " & r.key & ", " &
             $r.lengthBars & " тактов (" &
             formatFloat(r.lengthSeconds, ffDecimal, 1) & " c)\n"
  result.add "  секции:"
  for s in r.sections:
    result.add "\n    " & s.name & " [" & $s.startBar & "–" &
               $(s.startBar + s.lengthBars) & "] " & s.kind
  result.add "\n  дорожки:"
  for t in r.tracks:
    result.add "\n    " & t.name & " (" & t.role & "): " & $t.notes & " нот"
  result.add "\n  плотность: " & formatFloat(r.density, ffDecimal, 2) &
             " нот/такт, смен гармонии: " & $r.chordChanges &
             ", автоматизации: " & $r.automationLanes

{.pop.}
