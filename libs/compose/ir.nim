# libs/compose/ir.nim
#
# Composition IR — промежуточное представление (issue #COMPOSE-046).
#
# Зачем: без явной границы «музыкальный замысел → проект» каждый модуль
# начинает знать слишком много о соседнем (score → song → builder → project).
# IR фиксирует границу: `resolve(Piece)` отдаёт уже решённые данные (абсолютные
# тики, дорожки, автоматизация), а `compile(IR)` собирает из них раскладку и
# проект. IR ничего не знает про `Song`/`Melody`/`Progression` — только данные,
# поэтому проверять и сравнивать композицию можно до генерации `ProjectFormat`
# (#COMPOSE-008/046/047). Второго секвенсора тут нет — те же `NoteFormat` Core.

import std/math

import project
  # NoteFormat — ноты ядра, масштаб тиков общий с клипами.
import transport
  # PpqTicksPerQuarter — разрешение, которым считаются тики IR.
import compose/score
  # NoteEvent/Part/bar/r — обратный перевод событий в такты.
import compose/automation
  # AutoLane — автоматизация в музыкальном времени (такты).

{.push raises: [].}

type
  EventIR* = object
    ## Нота IR: позиция и длина в тиках ядра, как в `NoteFormat`, плюс номер
    ## такта-источника (`bar`): velocity в модели `score` одна на такт, и по
    ## этому номеру обратный перевод (`partFromEvents`) кладёт velocity точно —
    ## без догадок по позиции (дрейф округления тиков не мешает).
    startTick*: int32
    duration*: int32
    pitch*: uint8
    velocity*: uint8
    channel*: uint8
    bar*: int

  TrackIR* = object
    ## Дорожка IR: нода, роль, микс-флаги и решённые события.
    name*: string
    nodeType*: string
    notesName*: string
    role*: string
    params*: seq[tuple[name: string; value: float32]]
    mute*: bool
    events*: seq[EventIR]

  SectionIR* = object
    ## Секция IR: имя, роль и место в форме (в тактах).
    name*: string
    kind*: string
    startBar*: int
    lengthBars*: int

  CompositionIR* = object
    ## Решённая композиция: то, из чего собирается проект.
    title*: string
    tempo*: float32
    sampleRate*: float32
    beatsPerBar*: float32
    key*: string
    sections*: seq[SectionIR]
    tracks*: seq[TrackIR]
    automation*: seq[AutoLane]

# ============================================================================
# Запросы
# ============================================================================

proc endBar*(ir: CompositionIR): int =
  ## Длина формы в тактах (по последней секции).
  if ir.sections.len == 0:
    return 0
  let last = ir.sections[^1]
  last.startBar + last.lengthBars

proc trackNames*(ir: CompositionIR): seq[string] =
  for t in ir.tracks:
    result.add t.name

proc noteCount*(ir: CompositionIR): int =
  ## Всего нот во всех дорожках.
  for t in ir.tracks:
    result += t.events.len

proc eventsFrom*(p: Part; channel: int): seq[EventIR] =
  ## События партии в IR: та же арифметика тиков, что у `score.toNotes`, но с
  ## номером такта-источника (velocity такта доедет до проекта без потерь).
  var cursor = 0'i32
  for barIdx, b in p.bars:
    let vel = uint8(max(1, min(127, b.vel)))
    for e in b.events:
      let dur = max(1'i32, int32(round(e.beats * float(PpqTicksPerQuarter))))
      for pitch in e.pitches:
        result.add EventIR(startTick: cursor, duration: dur, pitch: pitch,
                           velocity: vel, channel: uint8(channel),
                           bar: barIdx)
      cursor += dur

proc irNotes*(t: TrackIR): seq[NoteFormat] =
  ## События дорожки в нотах ядра — для `NoteFormat`-потребителей.
  for e in t.events:
    result.add NoteFormat(startTick: e.startTick, duration: e.duration,
                          pitch: e.pitch, velocity: e.velocity,
                          channel: e.channel)

proc irNotes*(ir: CompositionIR): seq[NoteFormat] =
  ## Все ноты IR подряд (эквивалент `build` по составу и порядку).
  for t in ir.tracks:
    result.add t.irNotes()

# ============================================================================
# Обратный перевод: события → такты (Compile: IR → ProjectFormat)
# ============================================================================

proc partFromEvents*(t: TrackIR; bars: int; beatsPerBar: float): Part =
  ## Собрать `Part` (такты `score`) из решённых событий: одинаковые старты
  ## склеиваются в аккорд, промежутки добиваются паузами, такт — до полной
  ## сетки. Позиции считаются АБСОЛЮТНЫМ курсором: сумма событий и пауз
  ## остаётся равной исходной шкале тиков, поэтому обратный перевод (IR →
  ## `Arrangement` → ноты) точен до тика. Это тот шаг, который делает IR
  ## настоящей границей, а не «примерным пересказом» музыки.
  let barTicks = int32(round(float64(beatsPerBar) * float64(PpqTicksPerQuarter)))
  result = part(t.name)
  if barTicks <= 0:
    return
  var i = 0
  var cursor = 0'i32               # абсолютный тик: музыка идёт подряд
  for b in 0 ..< max(0, bars):
    let barStart = int32(b) * barTicks
    let barEnd = barStart + barTicks
    var events: seq[NoteEvent]
    if cursor < barStart:
      # Предыдущие такты были короче (молчание) — пауза до начала такта.
      events.add r(float(barStart - cursor) / float(PpqTicksPerQuarter))
      cursor = barStart
    var barVel = 0                 # velocity такта: берём с первой ноты
    while i < t.events.len and t.events[i].bar <= b:
      let e = t.events[i]
      if e.startTick > cursor:
        events.add r(float(e.startTick - cursor) / float(PpqTicksPerQuarter))
        cursor = e.startTick
      # Все ноты с тем же стартом — один аккорд.
      var pitches: seq[uint8]
      var dur = 0'i32
      while i < t.events.len and t.events[i].startTick == e.startTick:
        pitches.add t.events[i].pitch
        if barVel == 0:
          barVel = int(t.events[i].velocity)
        if t.events[i].duration > dur:
          dur = t.events[i].duration
        inc i
      if dur > 0:
        events.add NoteEvent(pitches: pitches,
                             beats: float(dur) / float(PpqTicksPerQuarter))
      cursor += dur
    # Хвост такта — пауза (если предыдущее событие не перешло границу).
    if cursor < barEnd:
      events.add r(float(barEnd - cursor) / float(PpqTicksPerQuarter))
      cursor = barEnd
    # В модели `score` velocity одна на такт, поэтому событие несёт её на
    # уровне такта — берём с первой ноты такта.
    result.add bar(max(1, min(127, if barVel > 0: barVel else: 100)), events)

proc `$`*(ir: CompositionIR): string =
  ## Краткая сводка IR — для отладки и отчётов.
  ir.title & " (" & $ir.endBar & " тактов, " & $ir.tracks.len &
    " дорожек, " & $ir.noteCount & " нот, " & $ir.automation.len &
    " дорожек автоматизации)"

{.pop.}
