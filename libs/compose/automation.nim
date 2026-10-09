# libs/compose/automation.nim
#
# DSL автоматизации (issue #COMPOSE-011).
#
# Зачем: музыка без автоматизации быстро превращается в статичный MIDI, а
# `AutomationLaneFormat`/`AutomationPointFormat`/`AutomationCurve` уже есть в
# Core — второй движок здесь недопустим. Compose даёт только оболочку: точки
# задаются в МУЗЫКАЛЬНОМ времени (такты), а перевод в тики и числовые id
# параметров делает компилятор (`toArrangement` → `buildProject`), тот же, что
# и для нот. Поэтому значения попадают точно в те параметры, которые читает
# нода (`level`, `pan`, `cutoff`, …).
#
# Порядок `AutoCurve` совпадает с `AutomationCurve` ядра (`core/sequencer`):
# в проект уходит ординал — ровно так его читает `scene_loader`. Синхронность
# стережёт тест.

import std/strutils

import compose/time
  # Duration/totalBeats — такты и длительности в музыкальном времени.

{.push raises: [].}

type
  AutoCurve* = enum
    ## Кривая между соседними точками. Порядок совпадает с
    ## `AutomationCurve` ядра (acLinear/acStep/acSmooth/acBezier), но имена
    ## свои — по образцу `builder.PortKind` vs `SignalType`: модуль Compose
    ## импортируется вместе с ядром, и одинаковые имена сделали бы enum
    ## неоднозначным. Синхронность ординалов стережёт тест.
    curveLinear
    curveStep
    curveSmooth
    curveBezier

  AutoPoint* = object
    ## Точка автоматизации: позиция в тактах (0.5.bar = 0.5) и значение.
    bar*: float32
    value*: float32
    curve*: AutoCurve

  AutoLane* = object
    ## Дорожка автоматизации: какую дорожку и какой параметр ведём.
    ## `track` — имя дорожки пьесы (или `@mix` — сумматор).
    track*: string
    param*: string
    points*: seq[AutoPoint]

const MixTrack* = "@mix"
  ## Имя «дорожки» для автоматизации сумматора (его параметр `level`).

# ============================================================================
# Построение дорожек
# ============================================================================

proc autom*(track, param: string; atBar: float32; value: float32;
            curve: AutoCurve = curveLinear): AutoLane =
  ## Дорожка из одной точки: `autom("bass", "level", 0.0, -8.0)`.
  ## Позиции — в тактах числом (0.0 — начало, 8.0 — девятый такт, 16.5 — его
  ## середина): то же музыкальное время, что `4.bars`, но дробное.
  AutoLane(track: track, param: param,
           points: @[AutoPoint(bar: atBar, value: value, curve: curve)])

proc at*(lane: var AutoLane; atBar: float32; value: float32;
         curve: AutoCurve = curveLinear): var AutoLane {.discardable.} =
  ## Добавить точку к дорожке (цепочка):
  ## `autom("bell", "pan", 0, -0.6).at(8, 0.6)`.
  lane.points.add AutoPoint(bar: atBar, value: value, curve: curve)
  lane

proc ramp*(track, param: string; fromBar, toBar: float32;
           fromV, toV: float32; curve: AutoCurve = curveLinear): AutoLane =
  ## Переход между двумя значениями: `ramp("pad", "level", 0, 8, -40, -6)` —
  ## подъём пада за восемь тактов.
  AutoLane(track: track, param: param,
           points: @[AutoPoint(bar: fromBar, value: fromV, curve: curve),
                     AutoPoint(bar: toBar, value: toV, curve: curve)])

proc ramp*(track, param: string; fromBar: float32; over: Duration;
           fromV, toV: float32; curve: AutoCurve = curveLinear): AutoLane =
  ## Переход длиной `over` (музыкальная длительность): `over = 4.bars`.
  ramp(track, param, fromBar,
       fromBar + float32(over.totalBeats(4.0f32) / 4.0f32), fromV, toV, curve)

proc fadeIn*(track, param: string; atBar: float32; over: Duration;
             fromV, toV: float32; curve: AutoCurve = curveSmooth): AutoLane =
  ## Появление: от `fromV` к `toV` за `over` (обычно на `level`).
  ramp(track, param, atBar, over, fromV, toV, curve)

proc fadeOut*(track, param: string; atBar: float32; over: Duration;
              fromV, toV: float32; curve: AutoCurve = curveSmooth): AutoLane =
  ## Уход: от `fromV` к `toV` за `over`.
  ramp(track, param, atBar, over, fromV, toV, curve)

proc lengthBars*(lane: AutoLane): float32 =
  ## Длина дорожки в тактах (по последней точке) — для отчётов и проверок.
  for p in lane.points:
    if p.bar > result:
      result = p.bar

proc `$`*(lane: AutoLane): string =
  ## Читаемая дорожка: `bass.level: 0→-8, 8→-2`.
  var parts: seq[string]
  for p in lane.points:
    parts.add $p.bar & "→" & $p.value
  lane.track & "." & lane.param & ": " & parts.join(", ")

{.pop.}
