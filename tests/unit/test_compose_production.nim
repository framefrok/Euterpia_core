# tests/unit/test_compose_production.nim
#
# Пресеты, шаблоны графа и sound design (Milestone 4: COMPOSE-021/022/023).
#
# Проверяется то, чем композиция превращается в проект на низком уровне:
#   * пресеты — имя → тип ноды + параметры, и параметры РЕАЛЬНЫ (проходят
#     `validate(arr)`, то есть сверяются с описателями нод, #311);
#   * шаблоны графа — notes → инструмент/осц → фильтр → сумматор: проект
#     собирается и ЗАГРУЖАЕТСЯ сценой (значит, граф связный и типы совпали);
#   * sound design — «звук как данные» компилируется в тот же Builder.

import std/unittest

import project
import sdk/node_registry
import builtin/builtin_registry
import builtin/scene_loader

import compose/score
import compose/time
  # `4.bars` — DSL времени для секций.
import compose/pattern
import compose/arrangement
import compose/song
  # validate(arr) приходит из song (как и в остальной библиотеке).
import compose/builder
import compose/preset
import compose/graph
import compose/sound
import compose/generators/drums

proc loadsOk(proj: ProjectFormat): bool =
  ## Собирается ли проект сценой (то же, что делает рендер) — граф и типы
  ## нод проверяются настоящим загрузчиком, а не только валидатором.
  var reg = initNodeRegistry()
  discard registerBuiltinNodes(reg)
  var scene = loadScene(reg, proj, -1, 48000'i32)
  result = scene.ok
  destroyScene(scene)

suite "Compose presets (COMPOSE-021)":
  test "пресет разворачивается в тип ноды и параметры":
    let p = preset("dark_bell")
    check p.nodeType == "euterpia.bell"
    check p.params.len > 0
    check hasPreset("dark_bell")
    check not hasPreset("no_such_preset")
    check ($p).len > 0

  test "неизвестное имя — честный fallback, а не падение":
    let p = preset("whatever")
    check p.nodeType == "euterpia.osc"

  test "playPreset ставит ноду и проходит проверку параметров":
    var s = piece("P", 120.0)
    discard s.section("verse", 4.bars)
    discard s.playPreset("bass", "sub_bass",
                         pattern("b", n(45, 4.0)), roleBass).during("verse")
    let arr = s.toArrangement()
    check arr.entries.len == 1
    check arr.entries[0].inst.nodeType == "euterpia.organ"
    check validate(arr).len == 0

  test "у каждого пресета параметры реальны (валидатор молчит)":
    for name in presetNames():
      var s = piece("P", 120.0)
      discard s.section("v", 2.bars)
      discard s.playPreset("t", name,
                           pattern("p", n(60, 2.0)), roleLead).during("v")
      let arr = s.toArrangement()
      check validate(arr).len == 0

suite "Compose graph templates and sound design (COMPOSE-022/023)":
  test "синтезаторная и инструментная цепочки собираются и грузятся":
    var b = builder("Graph")
    let masterId = master(b, level = -6.0f32)
    let lead = synthChain(b, "lead",
                          pattern("lead", n(69, 1.0), n(72, 1.0)).toPart(),
                          waveform = 1.0f32, cutoff = 4000.0f32)
    connectToMaster(b, lead, masterId, 0)
    let bells = instrumentChain(b, "bells", "euterpia.bell",
                                pattern("bells", n(76, 1.0)).toPart(),
                                [("decay", 5.0f32)])
    connectToMaster(b, bells, masterId, 1)
    check b.issues.len == 0
    check loadsOk(b.build())

  test "барабанная цепочка: GM-ноты и характер установки":
    var b = builder("Drums")
    let masterId = master(b)
    let kit = drumChain(b, "kit", trapKit(7).toPart())
    connectToMaster(b, kit, masterId, 0)
    check b.issues.len == 0
    check loadsOk(b.build())

  test "эффект вставляется в цепочку":
    var b = builder("Fx")
    let masterId = master(b)
    var chain = synthChain(b, "pad",
                           pattern("pad", n(60, 4.0)).toPart(),
                           waveform = 3.0f32)
    chain.tail = effectChain(b, chain.tail, "euterpia.delay",
                             [("mix", 0.25f32), ("feedback", 0.4f32)])
    connectToMaster(b, chain, masterId, 0)
    check b.issues.len == 0
    check loadsOk(b.build())

  test "sound design: спеки компилируются в Builder и грузятся":
    var b = builder("Sound")
    let masterId = master(b)
    let bass = sound(b, "bright bass",
                     pattern("bass", n(45, 2.0), n(48, 2.0)).toPart())
    connectToMaster(b, bass, masterId, 0)
    let pad = sound(b, "triangle pad", pattern("pad", n(60, 4.0)).toPart())
    connectToMaster(b, pad, masterId, 1)
    check b.issues.len == 0
    check loadsOk(b.build())

  test "sound транспонирует партию в регистр звука":
    check soundSpec("bright bass").transpose == -24
    check soundNames().len >= 4
    var b = builder("Oct")
    let masterId = master(b)
    let chain = sound(b, "dark sub", pattern("sub", n(69, 4.0)).toPart())
    connectToMaster(b, chain, masterId, 0)
    # Партия ушла на две октавы вниз — ноты в проекте это подтверждают.
    let notes = b.build().sequencer.tracks[0].clips[0].notes
    check notes.len == 1
    check notes[0].pitch == 45'u8
    check ($soundSpec("saw lead")).len > 0
