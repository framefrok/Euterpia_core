# nodes/builtin/scene_loader.nim
#
# Загрузка сцены: данные проекта → живой пайплайн, готовый к рендеру.
#
# Зачем это здесь, а не в CLI:
#   собрать сцену — значит сложить вместе три знания: формат проекта
#   (Core), список типов нод (реестр) и правила конкретных нод (нотный
#   секвенсор получает паттерн, а не «параметр»). Ни Core, ни CLI не знают
#   этот набор целиком (§20, §54): Core не знает список нод, CLI не имеет
#   права собирать пайплайн. Место стыка — builtin: он и так знает все
#   официальные ноды.
#
# Что делает загрузчик:
#   1. создаёт состояния нод по данным графа и применяет значения
#      параметров (по именам — так же, как они лежат в файле проекта);
#   2. собирает пайплайн через SDK (`buildPipeline`): компиляция + мастер;
#   3. превращает дорожки проекта в паттерны нотных нод: клип дорожки —
#      это паттерн одной ноды `euterpia.notes`;
#   4. переводит дорожки автоматизации в форму, понятную офлайн-рендеру.
#
# Владение:
#   сцена владеет и пайплайном, и состояниями нод. Состояния НЕ освобождает
#   `destroyPipeline` (он снимает только то, что создало ядро), поэтому
#   список созданных состояний хранится в сцене и освобождается
#   `destroyScene`. Порядок обязателен: пайплайн первым — он ссылается на
#   состояния через шаги.
#
# Ошибки не бросаются: неполный проект — нормальный исход, а не исключение.
# Наружу уходит `Scene` с `ok`/`error`, а всё, что «подозрительно, но не
# смертельно» (неизвестное имя параметра, значение вне диапазона, дорожка
# автоматизации на ноду, которой нет), копится в `issues` — пользователь
# видит причину, а рендер не срывается.

import std/[algorithm, tables, strutils]

import
  std/[os, tables, math],
  project,
  signal_types,
  transport,
  graph_compiler,
  compiled_pipeline,
  offline_render,
  sequencer,
  audio_file_io,
  ../sdk/node_api,
  ../sdk/node_registry,
  ../sdk/pipeline_builder,
  sequencer/notes,
  io/clip_player

{.push raises: [].}

const
  ## Потолок повторов рисунка клипа. Клип не должен превращаться в
  ## бесконечный цикл: если рисунок короче клипа в тысячи раз, это ошибка
  ## данных, а не музыкальный приём.
  MaxLoopCopyCount* = 64

  ClipTypeAudio = 1
    ## Ординал `ctAudio` (`core/sequencer.ClipType`): признаки «клип — аудио».
    ## У MIDI-клипов `resourceId` в объекте по умолчанию 0, поэтому одного
    ## `resourceId >= 0` мало — аудиоклип помечается ещё и видом.

type
  SceneIssue* = object
    ## Замечание загрузки: сцена собрана, но что-то в данных проекта
    ## выглядит подозрительно.
    nodeId*: int
    what*: string
    message*: string

  Scene* = object
    ## Собранная сцена: то, что нужно рендеру, и ничего больше.
    ok*: bool
    error*: string
    pipeline*: ptr CompiledPipeline
      ## Собственность сцены. Указатель отдаётся рендеру, но освобождает
      ## его `destroyScene` — иначе рендер распоряжался бы чужой памятью.
    masterNodeId*: int
      ## Нода, чей выход идёт в мастер-шину.
    sampleRate*: int32
    songEndTick*: int32
      ## Тик, на котором заканчивается последнее событие всех паттернов.
      ## Ноль — в сцене нет нотных нод (рендеру нужна явная длина).
    noteNodeIds*: seq[int]
      ## Нотные ноды в порядке возрастания id: в этом же порядке им
      ## достались дорожки проекта.
    clipNodeIds*: seq[int]
      ## Ноды-плееры аудиоклипов в порядке возрастания id: в этом же порядке
      ## им достались дорожки с аудиоклипами (issue #107).
    automation*: seq[OfflineAutomationLane]
      ## Автоматизация проекта в форме офлайн-рендера.
    issues*: seq[SceneIssue]
      ## Порядок замечаний детерминирован (по id ноды, затем по имени),
      ## поэтому вывод CLI воспроизводим (§21).

    states: seq[tuple[entry: ptr NodeTypeEntry, state: pointer]]
    clipBuffers: seq[seq[float32]]
      ## Сэмплы аудиоресурсов, которыми владеет сцена (issue #107). Ноды
      ## держат на них УКАЗАТЕЛИ, поэтому буферы обязаны жить, пока живёт
      ## сцена: список держит их до `destroyScene`.


# ==============================================================================
# Вспомогательное
# ==============================================================================

proc paramIndexByName(desc: ptr NodeDesc; name: string): int =
  ## Индекс параметра по имени или -1. Имена в файле проекта человеческие
  ## (`bars`, `level`), а нода получает числовой id — перевод делается здесь,
  ## по дескриптору, а не по зашитой таблице.
  if desc.isNil:
    return -1
  var i = 0'i32
  while i < desc.paramCount:
    if readFixed(desc.params[i].name) == name:
      return int(i)
    inc i
  -1

proc sortedParamNames(params: Table[string, float32]): seq[string] =
  ## Имена параметров по алфавиту: `Table` обходится в порядке хешей, а
  ## замечания загрузки обязаны быть детерминированными.
  for key in params.keys:
    result.add key
  result.sort()

proc issue(s: var Scene; nodeId: int; what, message: string) {.inline.} =
  s.issues.add SceneIssue(nodeId: nodeId, what: what, message: message)

proc disposeScene(s: var Scene) =
  ## Освобождает всё, чем владеет сцена. Порядок: пайплайн, затем состояния
  ## — шаги пайплайна держат указатели на состояния.
  if not s.pipeline.isNil:
    destroyPipeline(s.pipeline)
    s.pipeline = nil
  for item in s.states:
    destroyNodeState(item.entry, item.state)
  s.states.setLen(0)

proc failScene(s: var Scene; message: string): Scene =
  ## Единая точка отказа: сцена не отдаёт наружу ни пайплайн, ни состояния,
  ## если собрать её не удалось.
  disposeScene(s)
  s.ok = false
  s.error = message
  s

proc destroyScene*(s: var Scene) =
  ## Снимает сцену. Безопасно звать на пустой и на неудачной сцене.
  disposeScene(s)
  s.ok = false

proc detachPipeline*(s: var Scene): ptr CompiledPipeline =
  ## Отдаёт пайплайн вызывающему и снимает владение со сцены: после этого
  ## `destroyScene` его не тронет.
  ##
  ## Нужно там, где пайплайн передаётся тому, кто освободит его сам:
  ## `renderToWav` отдаёт граф аудиодвижку (`postGraphUpdate`), а движок
  ## освобождает его вместе с собой. Без явного «забывания» указателя сцена
  ## освободила бы тот же пайплайн второй раз — двойное освобождение.
  result = s.pipeline
  s.pipeline = nil

# ==============================================================================
# Автоматизация
# ==============================================================================

proc automationFromProject*(proj: ProjectFormat): seq[OfflineAutomationLane] =
  ## Дорожки автоматизации проекта в форме офлайн-рендера.
  ##
  ## Кривая задана в файле ординалом `AutomationCurve`; значение вне
  ## диапазона — это испорченный файл, поэтому берётся линейная кривая, а не
  ## «как получится» при приведении типа.
  for lane in proj.sequencer.automationLanes:
    var converted = OfflineAutomationLane(
      nodeId: lane.nodeId,
      paramId: lane.paramId
    )
    for point in lane.points:
      let curve =
        if point.curve >= 0 and point.curve <= ord(AutomationCurve.high):
          cast[AutomationCurve](point.curve)
        else:
          acLinear
      converted.points.add OfflineAutomationPoint(
        tick: point.tick, value: point.value, curve: curve
      )
    result.add converted

# ==============================================================================
# Паттерны нотных нод
# ==============================================================================

proc fillPattern(st: ptr NotesState; track: TrackFormat;
                 issues: var seq[SceneIssue]; nodeId: int) =
  ## Раскладывает дорожку проекта в паттерн нотной ноды.
  ##
  ## Клип — это окно дорожки: ноты лежат внутри него со своими тиками
  ## (относительно начала клипа). `loopEnabled` повторяет РИСУНОК клипа
  ## внутри его собственной длины: клип не растягивается за свои границы,
  ## иначе он перекрыл бы следующий.
  if st.isNil:
    return
  notesClear(st[])

  for clip in track.clips:
    if clip.notes.len == 0:
      continue
    if clip.lengthTicks <= 0:
      issues.add SceneIssue(nodeId: nodeId, what: "clip",
                            message: "клип \"" & clip.name &
                              "\" без длины: ноты не разложены")
      continue

    var patternTicks = 0'i32
    for note in clip.notes:
      let endTick = note.startTick + max(note.duration, 1'i32)
      if endTick > patternTicks:
        patternTicks = endTick

    var copies = 1
    if clip.loopEnabled and patternTicks > 0:
      copies = max(1, int(clip.lengthTicks div patternTicks))
    if copies > MaxLoopCopyCount:
      issues.add SceneIssue(nodeId: nodeId, what: "clip",
                            message: "клип \"" & clip.name & "\" повторился бы " &
                              $copies & " раз; взято " & $MaxLoopCopyCount)
      copies = MaxLoopCopyCount

    var copy = 0
    while copy < copies:
      let base = clip.startTick + int32(copy * patternTicks)
      for note in clip.notes:
        let start = base + note.startTick
        let duration = max(note.duration, 1'i32)
        if not notesAddNote(st[], int(start), int(duration), int(note.pitch),
                            float32(note.velocity) / 127.0f,
                            int(note.channel)):
          issues.add SceneIssue(nodeId: nodeId, what: "pattern",
                                message: "паттерн переполнен: ноты дорожки \"" &
                                  track.name & "\" не поместились целиком")
          return
      inc copy

# ==============================================================================
# Загрузка
# ==============================================================================

proc resourceById(proj: ProjectFormat; id: int32): int =
  ## Индекс ресурса по id или -1.
  for i in 0 ..< proj.resources.len:
    if proj.resources[i].id == id:
      return i
  -1

proc resolveResourcePath(baseDir, path: string): string =
  ## Путь к аудиоресурсу: абсолютный берётся как есть, относительный —
  ## от каталога проекта (`baseDir`, задаёт клиент; §58).
  if path.len == 0:
    return ""
  if isAbsolute(path):
    return path
  if baseDir.len > 0:
    return baseDir / path
  path

proc fillClips(nodeId: int; st: ptr ClipState; track: TrackFormat;
               proj: ProjectFormat; baseDir: string;
               sampleRate: int32; tempo: float64;
               buffers: var seq[seq[float32]];
               bufferIndex: var Table[int32, int];
               issues: var seq[SceneIssue]) =
  ## Раскладывает аудиоклипы дорожки в ноду-плеер (issue #107): читает
  ## ресурсы, кэширует сэмплы по id ресурса и наполняет слоты.
  if st.isNil:
    return
  clipClear(st[])

  # Тик → сэмпл: переводится ОДИН раз здесь, чтобы в audio-потоке осталась
  # только целочисленная арифметика.
  let sr = if sampleRate > 0: float64(sampleRate) else: 48000.0
  let bpm = if tempo > 1.0: tempo else: 120.0
  let samplesPerTick = sr * 60.0 / (bpm * 960.0)

  for clip in track.clips:
    if clip.clipType != ClipTypeAudio or clip.resourceId < 0:
      continue                       # не аудиоклип
    let ridx = resourceById(proj, clip.resourceId)
    if ridx < 0:
      issues.add SceneIssue(nodeId: nodeId, what: "resource",
        message: "клип \"" & clip.name & "\" ссылается на ресурс #" &
          $clip.resourceId & ", которого нет в проекте")
      continue

    let res = proj.resources[ridx]
    var bufIdx = bufferIndex.getOrDefault(res.id, -1)
    if bufIdx < 0:
      let path = resolveResourcePath(baseDir, res.path)
      var samples: seq[float32]
      try:
        (samples, _) = loadAudioFile(path)
      except CatchableError:
        issues.add SceneIssue(nodeId: nodeId, what: "resource",
          message: "аудиоресурс не прочитан: " & path)
        continue
      if samples.len == 0 or res.channels <= 0:
        issues.add SceneIssue(nodeId: nodeId, what: "resource",
          message: "аудиоресурс пуст: " & path)
        continue
      # Сначала кладём буфер в список (владение сцены), потом берём на него
      # указатель: элементы seq не двигаются при росте ВНЕШНЕГО списка.
      buffers.add samples
      bufIdx = buffers.len - 1
      bufferIndex[res.id] = bufIdx

    let startSample = int64(round(float64(clip.startTick) * samplesPerTick))
    let lengthSamples =
      int64(round(float64(max(clip.lengthTicks, 0'i32)) * samplesPerTick))
    let endSample = startSample + lengthSamples
    let data = cast[ptr UncheckedArray[float32]](addr buffers[bufIdx][0])
    if not clipAddSlot(st[], data, res.channels, res.numFrames,
                       clip.offsetFrames, startSample, endSample):
      issues.add SceneIssue(nodeId: nodeId, what: "clip",
        message: "клип \"" & clip.name & "\" не поместился в ноду " & ClipTypeId &
          " (слотов не больше " & $MaxClipSlots & ")")

proc loadScene*(reg: var NodeRegistry; proj: ProjectFormat;
                masterNodeId: int = -1;
                sampleRate: int32 = 48000;
                baseDir: string = ""): Scene =
  ## Собирает сцену из данных проекта.
  ##
  ## `masterNodeId` — нода, подключённая к мастер-шине. При -1 она
  ## определяется по графу: это единственная нода с аудиовыходом, у которой
  ## нет исходящих аудиосвязей. Если таких нод несколько или нет ни одной,
  ## загрузка останавливается: угадывать «какой выход — главный» нельзя,
  ## иначе проект звучал бы не так, как задумано.
  var g: NodeGraph
  var created: seq[tuple[entry: ptr NodeTypeEntry, state: pointer]] = @[]
  var noteStates: seq[tuple[id: int, st: ptr NotesState]] = @[]
  var clipStates: seq[tuple[id: int, st: ptr ClipState]] = @[]
  var clipBuffers: seq[seq[float32]] = @[]
  var bufferIndex = initTable[int32, int]()

  result.ok = false
  result.sampleRate = if sampleRate > 0: sampleRate else: 48000
  result.masterNodeId = masterNodeId

  # Уборка при любом раннем возврате: `created` заполняется постепенно,
  # а пайплайна в этот момент ещё нет.
  template bail(message: string): untyped =
    for item in created:
      destroyNodeState(item.entry, item.state)
    result.states.setLen(0)
    result.pipeline = nil
    result.ok = false
    result.error = message
    return result

  if proj.graph.nodes.len == 0:
    bail("в проекте нет нод: собирать нечего")

  # --- ноды ---------------------------------------------------------------
  var seenIds: seq[int] = @[]
  for node in proj.graph.nodes:
    if node.id in seenIds:
      bail("повтор id ноды: #" & $node.id)
    seenIds.add node.id

    let entry = reg.findNodeType(node.nodeType)
    if entry.isNil:
      bail("тип ноды не зарегистрирован: " & node.nodeType &
           " (нода #" & $node.id & ")")

    var en: EditorNode
    if not reg.instantiateNode(node.nodeType, node.id, en):
      bail("нода #" & $node.id & " (" & node.nodeType & ") не создалась")

    created.add (entry, en.userData)
    g.nodes[node.id] = en
    if node.nodeType == NotesTypeId:
      noteStates.add (node.id, cast[ptr NotesState](en.userData))
    if node.nodeType == ClipTypeId:
      clipStates.add (node.id, cast[ptr ClipState](en.userData))

    # --- параметры: имена из файла → значения в единицах ноды --------------
    for name in sortedParamNames(node.parameters):
      let value = node.parameters.getOrDefault(name, 0.0f)
      let idx = paramIndexByName(entry.desc, name)
      if idx < 0:
        issue(result, node.id, "param",
              "у типа " & node.nodeType & " нет параметра \"" & name &
              "\": значение " & $value & " пропущено")
        continue
      let paramId = entry.desc.params[idx].id
      let clamped = clampParam(entry.desc[], paramId, value)
      if clamped != value:
        issue(result, node.id, "param",
              "параметр \"" & name & "\" вне диапазона: " & $value &
              " → " & $clamped)
      entry.factory.setParam(en.userData, paramId, clamped, false)


  # --- связи ---------------------------------------------------------------
  for conn in proj.graph.connections:
    if conn.sigType < 0 or conn.sigType > ord(SignalType.high):
      bail("связь #" & $conn.srcNodeId & "→#" & $conn.dstNodeId &
           ": неизвестный вид сигнала " & $conn.sigType)
    g.connections.add EditorConnection(
      srcNodeId: conn.srcNodeId,
      srcPortIdx: conn.srcPortIdx,
      dstNodeId: conn.dstNodeId,
      dstPortIdx: conn.dstPortIdx,
      sigType: cast[SignalType](conn.sigType)
    )

  # --- мастер --------------------------------------------------------------
  if result.masterNodeId < 0:
    var candidates: seq[int] = @[]
    for node in proj.graph.nodes:
      if node.audioOutCount <= 0:
        continue
      var used = false
      for conn in proj.graph.connections:
        if conn.sigType == ord(sigAudio) and conn.srcNodeId == node.id:
          used = true
          break
      if not used:
        candidates.add node.id
    if candidates.len == 0:
      bail("в графе нет ноды, подключённой к мастеру: выход каждой ноды " &
           "занят другой нодой")
    if candidates.len > 1:
      var list: seq[string] = @[]
      for id in candidates:
        list.add "#" & $id
      bail("на мастер претендует несколько нод (" & list.join(", ") &
           "): укажите мастер явно")
    result.masterNodeId = candidates[0]

  # --- компиляция ----------------------------------------------------------
  var cr: CompileResult
  var binding: ptr PipelineBinding
  if not buildPipeline(reg, g, result.masterNodeId, cr, binding):
    bail("граф не компилируется: проверьте связи (euterpia graph check)")
  result.pipeline = cr.pipeline

  # С этого момента владение переходит сцене: пайплайн — её, состояния — её.
  # Дальнейшие ошибки уходят через `failScene` (он снимет и то, и другое).
  result.states = created

  # --- паттерны нот -------------------------------------------------------
  # Дорожки берутся в порядке файла, нотные ноды — по возрастанию id:
  # соответствие «дорожка → нода» детерминировано и не зависит от порядка
  # обхода `Table`.
  noteStates.sort(proc(a, b: tuple[id: int, st: ptr NotesState]): int =
    cmp(a.id, b.id))
  for item in noteStates:
    result.noteNodeIds.add item.id

  var withNotes: seq[int] = @[]      # индексы дорожек, где есть ноты
  for i in 0 ..< proj.sequencer.tracks.len:
    for clip in proj.sequencer.tracks[i].clips:
      if clip.notes.len > 0:
        withNotes.add i
        break

  if withNotes.len > noteStates.len:
    return failScene(result,
      "нотных дорожек " & $withNotes.len & ", а нод " & NotesTypeId & " — " &
      $noteStates.len & ": добавьте нотные ноды в граф")

  for k in 0 ..< withNotes.len:
    fillPattern(noteStates[k].st, proj.sequencer.tracks[withNotes[k]],
                result.issues, noteStates[k].id)
    let last = notesLastTick(noteStates[k].st[])
    if last > result.songEndTick:
      result.songEndTick = last

  # --- аудиоклипы (issue #107) --------------------------------------------
  # То же правило «дорожка → нода», что у нот: порядок дорожек и нод по id
  # детерминирован, и дорожка с аудиоклипами получает свою ноду-плеер.
  clipStates.sort(proc(a, b: tuple[id: int, st: ptr ClipState]): int =
    cmp(a.id, b.id))
  for item in clipStates:
    result.clipNodeIds.add item.id

  var withAudio: seq[int] = @[]
  for i in 0 ..< proj.sequencer.tracks.len:
    for clip in proj.sequencer.tracks[i].clips:
      if clip.clipType == ClipTypeAudio and clip.resourceId >= 0:
        withAudio.add i
        break

  if withAudio.len > clipStates.len:
    return failScene(result,
      "аудиодорожек " & $withAudio.len & ", а нод " & ClipTypeId & " — " &
      $clipStates.len & ": добавьте ноду-плеер в граф")

  for k in 0 ..< withAudio.len:
    let track = proj.sequencer.tracks[withAudio[k]]
    fillClips(clipStates[k].id, clipStates[k].st, track, proj, baseDir,
              result.sampleRate, float64(proj.metadata.tempo),
              clipBuffers, bufferIndex, result.issues)
    # Конец сцены — по тикам клипов: рендер мыслит музыкальным временем.
    for clip in track.clips:
      if clip.clipType == ClipTypeAudio:
        let endTick = int64(clip.startTick) + int64(max(clip.lengthTicks, 0'i32))
        if endTick > int64(result.songEndTick):
          result.songEndTick = int32(min(endTick, int64(high(int32))))

  # Сэмплы ресурсов живут столько же, сколько сцена: ноды держат указатели.
  result.clipBuffers = clipBuffers

  # --- автоматизация ------------------------------------------------------
  result.automation = automationFromProject(proj)
  if result.automation.len > 0:
    var known: seq[int] = @[]
    for node in proj.graph.nodes:
      known.add node.id
    for lane in result.automation:
      if int(lane.nodeId) notin known:
        issue(result, int(lane.nodeId), "automation",
              "дорожка автоматизации ссылается на ноду #" & $lane.nodeId &
              ", которой нет в графе")

  result.ok = true
  result

proc sceneSeconds*(s: Scene; tempo: float64): float64 =
  ## Длительность партитуры в секундах. Сцена — это ноты и тики, а сколько
  ## это в секундах, зависит от темпа: он берётся из проекта.
  let t = if tempo > 1.0: tempo else: 120.0
  float64(s.songEndTick) * 60.0 / (t * float64(PpqTicksPerQuarter))

{.pop.}

