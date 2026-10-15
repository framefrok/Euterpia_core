# libs/compose/sound.nim
#
# Sound design рядом с композицией (issue #COMPOSE-022).
#
# Зачем: `graph.synthChain` даёт механику (осц → фильтр → компрессор), но
# описывать характер звука числами в каждом проекте — тот же ручной труд, что
# и раньше. `SoundSpec` — это «звук как данные»: форма волны, фильтр, регистр;
# `sound(builder, "bright bass", part)` компилирует его в существующий Builder
# (никакого второго движка и никакого JSON — те же ноды).
#
# Отличие от `preset`: пресет — для высокого уровня (`Arrangement`/`Piece`,
# готовые инструменты), sound — для низкого (`Builder`, синтез из узлов).

import compose/score
  # Part/Motif/transpose — сдвиг регистра партии.
import compose/graph
  # Chain/synthChain/instrumentChain — цепочки графа.
import compose/builder
  # Builder — то, во что компилируется звук.

{.push raises: [].}

type
  SoundSpec* = object
    ## Описание синтезаторного звука: форма волны, уровень, фильтр, регистр.
    name*: string
    waveform*: float32   # 0 синус, 1 пила, 2 меандр, 3 треугольник
    level*: float32
    filter*: bool
    filterType*: float32 # 0 LP, 1 HP, 2 BP, …
    cutoff*: float32
    q*: float32
    compressor*: bool
    transpose*: int      # сдвиг партии в полутонах (регистр звука)

proc soundSpec*(name: string): SoundSpec =
  ## Готовый характер звука по имени. Неизвестное имя — базовый пилообразный
  ## тембр (композиция не падает из-за опечатки).
  case name
  of "bright bass":
    SoundSpec(name: name, waveform: 1.0f32, level: -7.0f32, filter: true,
              filterType: 0.0f32, cutoff: 1800.0f32, q: 1.2f32,
              compressor: true, transpose: -24)
  of "dark sub":
    SoundSpec(name: name, waveform: 0.0f32, level: -6.0f32, filter: true,
              filterType: 0.0f32, cutoff: 300.0f32, q: 0.8f32,
              transpose: -24)
  of "saw lead":
    SoundSpec(name: name, waveform: 1.0f32, level: -10.0f32, filter: true,
              filterType: 0.0f32, cutoff: 6000.0f32, q: 0.9f32,
              compressor: true)
  of "square pluck":
    SoundSpec(name: name, waveform: 2.0f32, level: -11.0f32, filter: true,
              filterType: 0.0f32, cutoff: 4200.0f32, q: 3.0f32)
  of "triangle pad":
    SoundSpec(name: name, waveform: 3.0f32, level: -12.0f32, filter: true,
              filterType: 0.0f32, cutoff: 2500.0f32, q: 0.7f32,
              transpose: -12)
  of "noise sweep":
    SoundSpec(name: name, waveform: 2.0f32, level: -14.0f32, filter: true,
              filterType: 2.0f32, cutoff: 1200.0f32, q: 4.0f32)
  else:
    SoundSpec(name: name, waveform: 1.0f32, level: -9.0f32, filter: true,
              filterType: 0.0f32, cutoff: 16000.0f32)

proc soundNames*(): seq[string] =
  ## Все описанные звуки (для подсказок и тестов).
  @["bright bass", "dark sub", "noise sweep", "saw lead", "square pluck",
    "triangle pad"]

proc sound*(b: var Builder; spec: SoundSpec; part: Part): Chain =
  ## Собрать звук в графе: `sound(b, soundSpec("bright bass"), bassPart)`.
  ## Партия транспонируется в регистр звука (`spec.transpose`), поэтому один
  ## и тот же нотный материал годится и басу, и лиду.
  var p = part
  if spec.transpose != 0:
    p.bars = transpose(p.bars, spec.transpose)   # Motif = seq[Bar]
  synthChain(b, part.name, p, waveform = spec.waveform, level = spec.level,
             filterType = spec.filterType, cutoff = spec.cutoff, q = spec.q,
             filter = spec.filter, compressor = spec.compressor)

proc sound*(b: var Builder; name: string; part: Part): Chain =
  ## То же по имени звука: `sound(b, "saw lead", leadPart)`.
  sound(b, soundSpec(name), part)

proc `$`*(s: SoundSpec): string =
  ## Читаемое описание звука.
  s.name & " (волна " & $s.waveform & ", level " & $s.level &
    (if s.filter: ", фильтр " & $s.filterType & " @ " & $s.cutoff else: "") &
    (if s.transpose != 0: ", сдвиг " & $s.transpose else: "") & ")"

{.pop.}
