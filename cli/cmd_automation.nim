# cli/cmd_automation.nim
#
# `euterpia automation list|add|rm|clear` — линии автоматизации проекта
# (issue #114).
#
# До этой команды автоматизация существовала с двух сторон и не была
# соединена: проект хранил `AutomationLaneFormat`, секвенсор умел кривые,
# offline-рендер применял значения, — но создать линию было нечем.
#
# Здесь только правка ДАННЫХ проекта: значение попадает в движок на рендере
# через `applyParamNow` (`offline_render`), а сетка «тик ↔ сэмпл» считается
# транспортом. Живой продюсер блоков — `fillAutomationBlock` в секвенсоре;
# CLI не крутит блоки.
#
# Коды возврата (#88): 0 — успех, 1 — данные/использование, 2 — среда,
# 3 — внутренняя.

import std/[algorithm, json, math, strutils, tables]

import context
import project
import sequencer
import cmd_project
import stamp
import cli_spec
import control_bridge
import control/document
import control/query

const
  AutomationSubcommands* = @["list", "add", "rm", "clear"]

  AutomationSpec* = CommandSpec(
    name: "automation",
    summary: "автоматизация параметров: list/add/rm/clear линии проекта",
    synopsis: "automation <list|add|rm|clear> <проект.eproj> " &
              "[--node N] [--param имя|id] [--tick T] [--value V] [--curve имя]",
    subcommands: AutomationSubcommands,
    args: @[
      arg("подкоманда", "list, add, rm или clear"),
      arg("проект.eproj", "проект, чьи линии правятся"),
    ],
    options: @[
      opt("--node", "id ноды", value = "N"),
      opt("--param", "параметр: имя (`gain`) или id (`0`)", value = "имя|id"),
      opt("--tick", "позиция точки в тиках проекта", value = "T"),
      opt("--value", "значение параметра в его единицах (дБ, Гц, …)", value = "V"),
      opt("--curve", "кривая к следующей точке: linear, step, smooth, bezier",
          value = "имя", default = "linear"),
    ],
    example: "euterpia automation add demo.eproj --node 2 --param gain " &
             "--tick 0 --value -12 --curve smooth",
    fields: @[
      field("project", "проект"),
      field("action", "что сделала команда"),
      field("lanes", "линии автоматизации после правки"),
      field("nodeId", "нода правки"),
      field("paramId", "id параметра"),
      field("param", "имя параметра"),
      field("points", "точек в линии"),
      field("tick", "тик точки"),
      field("value", "значение точки"),
      field("curve", "кривая точки"),
      field("changed", "были ли изменения"),
      field("written", "записан ли файл"),
    ],
    notes: @[
      "значения — в единицах параметра (`gain` в дБ, `cutoff` в Гц), не 0…1",
      "`--param` принимает имя из описателя ноды или числовой id",
      "точка на том же тике заменяется: повторный `add` не плодит дубли",
      "`rm` без `--tick` удаляет линию целиком; `clear` — все линии (или одну ноду)",
      "границы: до первой точки держится первая, после последней — последняя",
      "рендер применяет линии на границе чанка; живой продюсер — `fillAutomationBlock`",
      "лимит точек на линию — 1024 (`sequencer.MaxAutomationPoints`)",
    ])

type
  AutomationScan = object
    ok: bool
    rep: Report
    sub: string
    project: string
    node: int
    haveNode: bool
    param: string
    haveParam: bool
    tick: int32
    haveTick: bool
    value: float32
    haveValue: bool
    curve: int
    curveName: string

proc curveFromName(name: string): int =
  case name.toLowerAscii()
  of "linear": ord(acLinear)
  of "step": ord(acStep)
  of "smooth": ord(acSmooth)
  of "bezier": ord(acBezier)
  else: -1

proc curveName(value: int): string =
  case value
  of ord(acLinear): "linear"
  of ord(acStep): "step"
  of ord(acSmooth): "smooth"
  of ord(acBezier): "bezier"
  else: "unknown"

proc scanAutomationArgs(args: seq[string]): AutomationScan =
  result.node = -1
  result.curve = ord(acLinear)
  result.curveName = "linear"
  if args.len == 0:
    return AutomationScan(ok: false,
      rep: usageError("automation: не указана подкоманда",
        "подкоманды: " & AutomationSubcommands.join(", ")))
  result.sub = args[0]
  if result.sub notin AutomationSubcommands:
    return AutomationScan(ok: false,
      rep: usageError("automation: неизвестная подкоманда «" & result.sub & "»",
        "подкоманды: " & AutomationSubcommands.join(", ")))

  var i = 1
  while i < args.len:
    let key = args[i]
    if key in ["--node", "--param", "--tick", "--value", "--curve"]:
      if i + 1 >= args.len:
        return AutomationScan(ok: false,
          rep: usageError(key & ": нужно значение",
            "например: automation add p.eproj --node 2 --param gain --tick 0 --value -12"))
      let value = args[i + 1]
      case key
      of "--node":
        try:
          let n = parseInt(value)
          if n < 0:
            return AutomationScan(ok: false,
              rep: usageError("--node: id не может быть отрицательным", value))
          result.node = n
          result.haveNode = true
        except ValueError:
          return AutomationScan(ok: false,
            rep: usageError("--node: ожидается целое, получено: " & value,
              "id ноды: euterpia node list"))
      of "--param":
        result.param = value
        result.haveParam = true
      of "--tick":
        try:
          let t = parseInt(value)
          if t < 0:
            return AutomationScan(ok: false,
              rep: usageError("--tick: позиция не может быть отрицательной",
                value))
          result.tick = int32(t)
          result.haveTick = true
        except ValueError:
          return AutomationScan(ok: false,
            rep: usageError("--tick: ожидается целое, получено: " & value,
              "тики проекта: 960 на четверть"))
      of "--value":
        try:
          let v = parseFloat(value)
          if v.classify in {fcNan, fcInf, fcNegInf}:
            return AutomationScan(ok: false,
              rep: usageError("--value: нужно конечное число", value))
          result.value = float32(v)
          result.haveValue = true
        except ValueError:
          return AutomationScan(ok: false,
            rep: usageError("--value: ожидается число, получено: " & value,
              "например: --value -12"))
      else: # --curve
        let c = curveFromName(value)
        if c < 0:
          return AutomationScan(ok: false,
            rep: usageError("--curve: неизвестная кривая «" & value & "»",
              "допустимо: linear, step, smooth, bezier"))
        result.curve = c
        result.curveName = value.toLowerAscii()
      i += 2
      continue
    if key.startsWith("-"):
      return AutomationScan(ok: false,
        rep: usageError("неизвестный ключ: " & key,
          "ключи automation: --node, --param, --tick, --value, --curve"))
    if result.project.len == 0 and isProjectPath(key):
      result.project = key
    else:
      return AutomationScan(ok: false,
        rep: usageError("лишний аргумент: " & key,
          "форма: automation <list|add|rm|clear> <проект.eproj> [ключи]"))
    inc i

  if result.project.len == 0:
    return AutomationScan(ok: false,
      rep: usageError("automation: не указан проект",
        "например: automation list demo.eproj"))
  result.ok = true

proc paramIndex(node: NodeInfo; spec: string):
    tuple[ok: bool; id: int; name: string] =
  ## Имя параметра из описателя ноды или числовой id.
  var numeric = -1
  try:
    numeric = parseInt(spec)
  except ValueError:
    numeric = -1
  for p in node.params:
    if (numeric >= 0 and p.index == numeric) or
       (numeric < 0 and p.name == spec):
      return (true, p.index, p.name)
  if numeric >= 0:
    return (true, numeric, spec)
  (false, -1, "")

proc findLane(proj: ProjectFormat; nodeId: int; paramId: uint32): int =
  for i, lane in proj.sequencer.automationLanes:
    if lane.nodeId == int32(nodeId) and lane.paramId == paramId:
      return i
  -1

proc laneJson(lane: AutomationLaneFormat; nodeName: string): JsonNode =
  var points = newJArray()
  for p in lane.points:
    points.add %*{"tick": int(p.tick), "value": p.value,
                  "curve": curveName(p.curve)}
  %*{"nodeId": lane.nodeId, "nodeName": nodeName, "paramId": lane.paramId,
     "points": points, "count": lane.points.len}


proc runAutomation*(ctx: var Ctx; args: seq[string]): Report =
  let sc = scanAutomationArgs(args)
  if not sc.ok:
    return sc.rep

  let loaded = loadAt(sc.project)
  if not loaded.ok:
    return loaded.rep
  var doc = openDocument(sc.project, loaded.proj)

  # Имя ноды/параметра — через Query API: CLI не читает модель сама.
  var nodeNames = initTable[int, string]()
  var node: NodeInfo
  var haveNodeInfo = false
  for item in queryNodes(doc).nodes:
    nodeNames[item.id] = item.name
    if item.id == sc.node:
      node = item
      haveNodeInfo = true

  var paramId = 0'u32
  var paramName = ""
  if sc.haveParam or sc.sub in ["add", "rm"]:
    if sc.node < 0:
      return usageError("нужен --node: у линии есть нода и параметр",
        "например: --node 2 --param gain")
    if not haveNodeInfo:
      return usageError("нода #" & $sc.node & " не найдена",
        "id нод: euterpia node list " & sc.project)
    if not sc.haveParam:
      return usageError("нужен --param: имя или id параметра",
        "например: --param gain")
    let resolved = paramIndex(node, sc.param)
    if not resolved.ok:
      var names: seq[string] = @[]
      for p in node.params: names.add p.name
      return usageError("параметр «" & sc.param & "» не найден у ноды #" &
        $sc.node, "параметры: " & names.join(", "))
    paramId = uint32(resolved.id)
    paramName = resolved.name

  var changed = false
  var lines: seq[string] = @[CliName & " automation — " & sc.sub,
                             "проект: " & sc.project]

  case sc.sub
  of "list":
    var lanes = newJArray()
    for lane in doc.proj.sequencer.automationLanes:
      if sc.haveNode and lane.nodeId != int32(sc.node):
        continue
      if sc.haveParam and paramId != 0'u32 and lane.paramId != paramId:
        continue
      lanes.add laneJson(lane, nodeNames.getOrDefault(int(lane.nodeId), ""))
    let body = %*{"project": sc.project, "action": "list",
                  "lanes": lanes, "changed": false, "written": false}
    if lanes.len == 0:
      return okReport(body = body,
        lines = lines & @["линий автоматизации нет"])
    for lane in lanes:
      lines.add "  нода #" & $lane["nodeId"].getInt & " «" &
        lane["nodeName"].getStr & "», параметр #" &
        $lane["paramId"].getInt & ": " & $lane["count"].getInt & " точек"
    return okReport(body = body, lines = lines)

  of "add":
    if not sc.haveTick or not sc.haveValue:
      return usageError("add требует --tick и --value",
        "например: --tick 0 --value -12")
    var laneIndex = findLane(doc.proj, sc.node, paramId)
    if laneIndex < 0:
      doc.proj.sequencer.automationLanes.add AutomationLaneFormat(
        paramId: paramId, nodeId: int32(sc.node), points: @[])
      laneIndex = doc.proj.sequencer.automationLanes.len - 1
    var lane = addr doc.proj.sequencer.automationLanes[laneIndex]
    var replaced = false
    for p in lane.points.mitems:
      if p.tick == sc.tick:
        p.value = sc.value
        p.curve = sc.curve
        replaced = true
        changed = true
    if not replaced:
      if lane.points.len >= MaxAutomationPoints:
        return usageError("линия заполнена: " & $MaxAutomationPoints & " точек",
          "удалите точки: automation rm … --tick")
      lane.points.add AutomationPointFormat(tick: sc.tick, value: sc.value,
                                            curve: sc.curve)
      changed = true
    lane.points.sort(proc(a, b: AutomationPointFormat): int =
      cmp(a.tick, b.tick))
    lines.add "точка: тик " & $sc.tick & ", " & $sc.value & " (" &
      sc.curveName & ")"


  of "rm":
    let laneIndex = findLane(doc.proj, sc.node, paramId)
    if laneIndex < 0:
      return usageError("линии автоматизации ноды #" & $sc.node &
        " / параметра #" & $paramId & " нет",
        "список: euterpia automation list " & sc.project)
    if sc.haveTick:
      var kept: seq[AutomationPointFormat] = @[]
      var removed = false
      for p in doc.proj.sequencer.automationLanes[laneIndex].points:
        if p.tick == sc.tick:
          removed = true
        else:
          kept.add p
      if not removed:
        return usageError("точки на тике " & $sc.tick & " нет",
          "точки линии: euterpia automation list " & sc.project &
          " --node " & $sc.node)
      doc.proj.sequencer.automationLanes[laneIndex].points = kept
      if kept.len == 0:
        doc.proj.sequencer.automationLanes.delete(laneIndex)
      changed = true
      lines.add "удалена точка: тик " & $sc.tick
    else:
      doc.proj.sequencer.automationLanes.delete(laneIndex)
      changed = true
      lines.add "удалена линия целиком"

  else: # clear
    var kept: seq[AutomationLaneFormat] = @[]
    var removed = 0
    for lane in doc.proj.sequencer.automationLanes:
      if sc.haveNode and lane.nodeId != int32(sc.node):
        kept.add lane
      else:
        inc removed
    if removed > 0:
      doc.proj.sequencer.automationLanes = kept
      changed = true
    lines.add "удалено линий: " & $removed

  var written = false
  if changed and not ctx.dryRun:
    doc.proj.metadata.modified = nowStamp()
    let saved = writeAtomic(sc.project, doc.proj)
    if not saved.success:
      return saveError(saved, sc.project)
    written = true
    lines.add "записан: " & sc.project
  elif ctx.dryRun:
    lines.add "не записан: " & sc.project & " (--dry-run)"

  var points = 0
  var tick = 0
  var value = 0.0'f32
  var curve = sc.curveName
  if sc.node >= 0 and sc.haveParam:
    let idx = findLane(doc.proj, sc.node, paramId)
    if idx >= 0:
      points = doc.proj.sequencer.automationLanes[idx].points.len
      if sc.haveTick:
        for p in doc.proj.sequencer.automationLanes[idx].points:
          if p.tick == sc.tick:
            tick = int(p.tick)
            value = p.value
            curve = curveName(p.curve)

  okReport(
    body = %*{
      "project": sc.project,
      "action": sc.sub,
      "lanes": doc.proj.sequencer.automationLanes.len,
      "nodeId": (if sc.haveNode: sc.node else: -1),
      "paramId": paramId,
      "param": paramName,
      "points": points,
      "tick": tick,
      "value": value,
      "curve": curve,
      "changed": changed,
      "written": written,
    },
    lines = lines)

