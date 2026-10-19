# libs/compose/graph.nim
#
# Шаблоны графа для `Builder` (issue #COMPOSE-023).
#
# Зачем: `builder.addNode`/`connect` — честный низкий уровень, но собирать
# «осц → фильтр → компрессор → сумматор» руками каждый раз означает копировать
# шесть строк и знать номера портов. Здесь — шаблоны цепочек: они добавляют
# ноды, соединяют их и возвращают `Chain` (нотная нода, вход, выход), а
# вызывающий решает, куда вести выход и что ещё добавить.
#
# Это НЕ музыкальный слой: ни секций, ни гармонии здесь нет — только граф.
# Для пьесы с секциями и аккордами есть `arrangement`/`preset`.

import compose/score
  # Part — ноты дорожки (уходят в `addTrack`).
import compose/builder
  # Builder/addNode/connect/addTrack — низкоуровневая сборка проекта.

{.push raises: [].}

type
  Chain* = object
    ## Инструмент-цепочка в графе: `notes` — нотная нода дорожки,
    ## `head` — входной узел (инструмент/осциллятор), `tail` — выход цепочки
    ## (то, что соединяют с сумматором или шиной).
    notes*: int
    head*: int
    tail*: int

proc master*(b: var Builder; level: float32 = 0.0f32;
             name: string = "Master"): int =
  ## Сумматор проекта: `connectToMaster` ведёт в него выходы цепочек.
  b.addNode("euterpia.mix", name, [("level", level)])

proc connectToMaster*(b: var Builder; chain: Chain; masterId: int;
                      inputIdx: int = 0) =
  ## Соединить выход цепочки со входом сумматора.
  b.connect(chain.tail, 0, masterId, inputIdx, pkAudio)

proc notesTrack(b: var Builder; name: string; part: Part): int =
  ## Нотная нода + дорожка. Порядок добавления = порядок сопоставления
  ## дорожек и нотных нод в загрузчике сцены (как в `song.buildProject`).
  result = b.addNode("euterpia.notes", name & "_notes")
  discard b.addTrack(name, part)

proc instrumentChain*(b: var Builder; name, nodeType: string; part: Part;
                      params: openArray[(string, float32)] = []): Chain =
  ## Инструмент + дорожка: notes → instrument. Параметры берутся из описателя
  ## типа, `params` — переопределения (как `setParam`).
  result.notes = notesTrack(b, name, part)
  result.head = b.addNode(nodeType, name, params)
  b.connect(result.notes, 0, result.head, 0, pkEvent)
  result.tail = result.head

proc synthChain*(b: var Builder; name: string; part: Part;
                 waveform: float32 = 1.0f32; level: float32 = -6.0f32;
                 filterType: float32 = 0.0f32; cutoff: float32 = 16000.0f32;
                 q: float32 = 0.707f32; filter: bool = true;
                 compressor: bool = false;
                 threshold: float32 = -18.0f32;
                 ratio: float32 = 4.0f32): Chain =
  ## Синтезаторная цепочка: notes → osc → [biquad] → [compressor].
  ## `waveform`: 0 синус, 1 пила, 2 меандр, 3 треугольник.
  result.notes = notesTrack(b, name, part)
  let oscId = b.addNode("euterpia.osc", name,
                        [("waveform", waveform), ("level", level)])
  b.connect(result.notes, 0, oscId, 0, pkEvent)
  result.head = oscId
  result.tail = oscId
  if filter:
    let flt = b.addNode("euterpia.biquad", name & "_filter",
                        [("type", filterType), ("cutoff", cutoff), ("q", q)])
    b.connect(result.tail, 0, flt, 0, pkAudio)
    result.tail = flt
  if compressor:
    let comp = b.addNode("euterpia.compressor", name & "_comp",
                         [("threshold", threshold), ("ratio", ratio)])
    b.connect(result.tail, 0, comp, 0, pkAudio)
    result.tail = comp

proc drumChain*(b: var Builder; name: string; part: Part;
                tune: float32 = 1.0f32; decay: float32 = 1.0f32;
                snappy: float32 = 1.0f32; tone: float32 = 0.5f32;
                drive: float32 = 0.15f32; level: float32 = -6.0f32): Chain =
  ## Барабаны + дорожка (GM-ноты) с характером установки.
  instrumentChain(b, name, "euterpia.drums", part,
                  @[("tune", tune), ("decay", decay), ("snappy", snappy),
                    ("tone", tone), ("drive", drive), ("level", level)])

proc effectChain*(b: var Builder; input: int; kind: string;
                  params: openArray[(string, float32)] = []): int =
  ## Вставить эффект после `input` и вернуть его id:
  ## `let d = chain.effectChain(b, "euterpia.delay", [("mix", 0.25f32)])`.
  result = b.addNode(kind, kind & "_fx", params)
  b.connect(input, 0, result, 0, pkAudio)

proc `$`*(c: Chain): string =
  ## Читаемая цепочка: `notes#1 → head#2 … tail#4`.
  "chain notes#" & $c.notes & " → head#" & $c.head & " tail#" & $c.tail

{.pop.}
