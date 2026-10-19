# core/live_automation.nim
#
# Продюсер автоматизации живого пути (issue #413).
#
# Зачем отдельный модуль: офлайн-рендер применяет линии на границе чанка
# (`offline_render`), а живой путь до этого — только стартовые значения.
# Здесь живёт POD-набор линий, который движок читает в audio-потоке:
#
#   * память выделяется ОДИН раз при создании движка (двойной буфер);
#   * control-path заполняет неактивный буфер и публикует индекс атомарно;
#   * audio-поток читает индекс один раз на блок и бинарным поиском находит
#     значение на текущем тике — без аллокаций, локов и исключений.
#
# Почему не `cmdAutomationBlock` из shared-пула: блок пула — 4096 байт, а
# одна линия проекта может содержать 1024 точки (12 байт каждая). Двойной
# предвыделенный буфер — это и есть «предвыделенный буфер» из issue, но без
# дробления линии на десятки команд и без потери точек на границах блоков.
#
# Привязка «тик ↔ сэмпл» — та же формула, что у транспорта и офлайн-рендера
# (`liveAutomationTickForFrame`), поэтому живой и offline результат совпадают.

import sequencer
from transport import PpqTicksPerQuarter

{.push raises: [].}

const
  MaxLiveAutomationLanes* = 16
    ## Больше линий одновременно живому пути не нужно: проект с десятками
    ## автоматизируемых параметров всё равно требует UI-редактора, а
    ## молча терять линии нельзя — `postLiveAutomation` вернёт число
    ## принятых и `dropped`.

  MaxLiveAutomationPoints* = sequencer.MaxAutomationPoints
    ## Предел точек на линию — тот же, что у формата проекта (1024).

type
  LiveAutomationPoint* = object
    tick*: int32
    value*: float32
    curve*: uint8
      ## Ординал `sequencer.AutomationCurve`.

  LiveAutomationLane* = object
    nodeId*: int32
    paramId*: uint32
    pointCount*: int32
    points*: array[MaxLiveAutomationPoints, LiveAutomationPoint]

  LiveAutomationSet* = object
    ## Набор линий для audio-потока. POD, без GC-полей.
    laneCount*: int32
    lanes*: array[MaxLiveAutomationLanes, LiveAutomationLane]

  LiveAutomationValue* = object
    ## Результат выборки на блок: что применить в пайплайн.
    nodeId*: int32
    paramId*: uint32
    value*: float32

proc liveAutomationTickForFrame*(frame: int64; sampleRate, tempo: float64): float64 =
  ## Кадр транспорта → тик (960 PPQ на четверть). Формула совпадает с
  ## `offline_render`: samplesPerTick = sr * 60 / (tempo * PPQ).
  if sampleRate <= 0.0 or tempo <= 0.0:
    return 0.0
  float64(frame) * tempo * float64(PpqTicksPerQuarter) /
    (60.0 * sampleRate)

proc liveAutomationValueAt*(lane: LiveAutomationLane; tick: float64): float32 =
  ## Значение линии на тике. Пустая линия — 0 (вызывающий её пропускает).
  if lane.pointCount <= 0:
    return 0.0f
  if lane.pointCount == 1:
    return lane.points[0].value
  if tick <= float64(lane.points[0].tick):
    return lane.points[0].value
  let last = int(lane.pointCount) - 1
  if tick >= float64(lane.points[last].tick):
    return lane.points[last].value

  var lo = 0
  var hi = last
  while hi - lo > 1:
    let mid = (lo + hi) div 2

    if float64(lane.points[mid].tick) <= tick:
      lo = mid
    else:
      hi = mid
  let a = lane.points[lo]
  let b = lane.points[hi]
  let span = float64(b.tick - a.tick)
  if span <= 0.0:
    return b.value
  let frac = float32((tick - float64(a.tick)) / span)
  sequencer.interpolateAutomation(
    a.value, b.value, frac, cast[sequencer.AutomationCurve](a.curve))

proc addLiveAutomationPoint*(lane: var LiveAutomationLane;
                             tick: int32; value: float32; curve: uint8) =
  ## Добавить точку с сохранением порядка по тику (линии проекта уже
  ## отсортированы; эта процедура — для тестов и хостов, собирающих линии
  ## вручную).
  if lane.pointCount >= MaxLiveAutomationPoints:
    return
  var i = int(lane.pointCount)
  while i > 0 and lane.points[i - 1].tick > tick:
    lane.points[i] = lane.points[i - 1]
    dec i
  lane.points[i] = LiveAutomationPoint(tick: tick, value: value, curve: curve)
  inc lane.pointCount

proc fillLiveAutomationSet*(
  dst: var LiveAutomationSet;
  lanes: openArray[LiveAutomationLane]
): int32 =
  ## Скопировать линии в набор. Возвращает число принятых линий; линии без
  ## точек и сверх лимита отбрасываются (вызывающий видит разницу).
  dst.laneCount = 0
  for lane in lanes:
    if dst.laneCount >= int32(MaxLiveAutomationLanes):
      break
    if lane.pointCount <= 0:
      continue
    dst.lanes[dst.laneCount] = lane
    inc dst.laneCount
  dst.laneCount

{.pop.}
