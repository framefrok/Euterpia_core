# core/sequencer.nim
import std/[algorithm, math]
import signal_types, transport

{.push raises: [].}

const
  MaxNotesPerClip*      = 4096
  MaxClips*             = 256
  MaxAutomationPoints*  = 1024
  DefaultMaxSongTicks*  = 1_000_000'i32   
  MaxScheduledPerClip*  = MaxNotesPerClip * 2  
  PI_F*                 = 3.14159265358979f

type
  AutomationCurve* = enum
    acLinear
    acStep
    acSmooth      
    acBezier      

  NoteEvent* = object
    startTick*:  int32
    duration*:   int32
    pitch*:      uint8
    velocity*:   uint8
    channel*:    uint8

  ClipType* = enum
    ctMidi, ctAudio, ctAutomation

  Clip* = object
    id*:            int32
    clipType*:      ClipType
    name*:          string
    startTick*:     int32
    lengthTicks*:   int32
    loopEnabled*:   bool
    notes*:         seq[NoteEvent]
    audioBufferId*: int32
    color*:         uint32

  TrackType* = enum
    ttMidi, ttAudio, ttBus, ttMaster

  Track* = object
    id*:            int32
    name*:          string
    trackType*:     TrackType
    clips*:         seq[Clip]
    volume*:        float32
    pan*:           float32
    mute*:          bool
    solo*:          bool
    armed*:         bool
    inputChannel*:  int32
    outputBus*:     int32

  AutomationPoint* = object
    tick*:  int32
    value*: float32
    curve*: AutomationCurve

  AutomationLane* = object
    paramId*: uint32
    nodeId*:  int32
    points*:  seq[AutomationPoint]

  Sequencer* = object
    tracks*:          seq[Track]
    automationLanes*: seq[AutomationLane]
    transport*:       ptr Transport
    currentBar*:      int32
    currentBeat*:     int32

  ScheduledEvent* = object
    tick*:      int32
    kind*:      RealtimeEventKind
    channel*:   uint8
    note*:      uint8
    velocity*:  float32
    trackId*:   int32
    clipId*:    int32

  CompiledClip* = object
    startTick*:    int32
    lengthTicks*:  int32
    loopEnabled*:  bool
    events*:       seq[ScheduledEvent]   

  CompiledTrack* = object
    trackId*: int32
    mute*:    bool
    clips*:   seq[CompiledClip]

  CompiledAutomation* = object
    nodeId*:  int32
    paramId*: uint32
    points*:  seq[AutomationPoint]       

  CompiledSequencer* = object
    tracks*:     seq[CompiledTrack]
    automation*: seq[CompiledAutomation]
    maxTick*:    int32                   

  SequencerRuntime* = object
    compiled*:      ptr CompiledSequencer
    droppedEvents*: uint32

# =============================================================================
# Editor-side mutators (NOT realtime)
# =============================================================================

proc initSequencer*(transport: ptr Transport): Sequencer =
  result.transport   = transport
  result.currentBar  = 1
  result.currentBeat = 1

proc addTrack*(s: var Sequencer, trackType: TrackType, name: string): int32 =
  let id = int32(s.tracks.len + 1)
  s.tracks.add Track(
    id: id, name: name, trackType: trackType,
    volume: 1.0f, pan: 0.0f, outputBus: 0
  )
  id

proc addClip*(s: var Sequencer, trackId: int32,
              clipType: ClipType, startTick, lengthTicks: int32): int32 =
  let t = trackId - 1
  if t < 0 or t >= s.tracks.len: return -1
  if lengthTicks <= 0: return -1
  let id = int32(s.tracks[t].clips.len + 1)
  s.tracks[t].clips.add Clip(
    id: id, clipType: clipType,
    name: "Clip " & $id,
    startTick: startTick, lengthTicks: lengthTicks,
    color: 0xFF6B6B'u32, audioBufferId: -1
  )
  id

proc addNote*(s: var Sequencer, trackId, clipId: int32,
              startTick, duration: int32, pitch, velocity: uint8) =
  let t = trackId - 1
  if t < 0 or t >= s.tracks.len: return
  let c = clipId - 1
  if c < 0 or c >= s.tracks[t].clips.len: return
  if s.tracks[t].clips[c].notes.len >= MaxNotesPerClip: return
  s.tracks[t].clips[c].notes.add NoteEvent(
    startTick: startTick, duration: duration,
    pitch: pitch, velocity: velocity, channel: 0
  )

proc addAutomationPoint*(s: var Sequencer, nodeId: int32, paramId: uint32,
                         tick: int32, value: float32,
                         curve: AutomationCurve = acLinear) =
  for lane in s.automationLanes.mitems:
    if lane.nodeId == nodeId and lane.paramId == paramId:
      if lane.points.len < MaxAutomationPoints:
        lane.points.add AutomationPoint(tick: tick, value: value, curve: curve)
        lane.points.sort(proc(a, b: AutomationPoint): int = cmp(a.tick, b.tick))
      return
  var lane = AutomationLane(nodeId: nodeId, paramId: paramId)
  lane.points.add AutomationPoint(tick: tick, value: value, curve: curve)
  s.automationLanes.add lane

# =============================================================================
# Compile: Sequencer → CompiledSequencer
# =============================================================================

proc expandClipEvents(clip: Clip, trackId: int32,
                      maxSongTicks: int32,
                      outEvents: var seq[ScheduledEvent]) =
  if clip.lengthTicks <= 0: return
  if clip.notes.len == 0: return

  let velScale = 1.0f / 127.0f

  if not clip.loopEnabled:
    for n in clip.notes:
      let a0 = clip.startTick + n.startTick
      let a1 = a0 + n.duration
      if a0 >= maxSongTicks: continue
      outEvents.add ScheduledEvent(
        tick: a0, kind: evNoteOn,
        channel: n.channel, note: n.pitch,
        velocity: float32(n.velocity) * velScale,
        trackId: trackId, clipId: clip.id
      )
      let offTick = min(a1, clip.startTick + clip.lengthTicks)
      outEvents.add ScheduledEvent(
        tick: offTick, kind: evNoteOff,
        channel: n.channel, note: n.pitch,
        velocity: 0.0f,
        trackId: trackId, clipId: clip.id
      )
  else:
    var iter = clip.startTick
    while iter < maxSongTicks:
      for n in clip.notes:
        let a0 = iter + n.startTick
        let a1 = a0 + n.duration
        if a0 >= maxSongTicks: continue
        outEvents.add ScheduledEvent(
          tick: a0, kind: evNoteOn,
          channel: n.channel, note: n.pitch,
          velocity: float32(n.velocity) * velScale,
          trackId: trackId, clipId: clip.id
        )
        let offTick = min(a1, iter + clip.lengthTicks)
        outEvents.add ScheduledEvent(
          tick: offTick, kind: evNoteOff,
          channel: n.channel, note: n.pitch,
          velocity: 0.0f,
          trackId: trackId, clipId: clip.id
        )
      iter += clip.lengthTicks

proc compile*(s: Sequencer,
              maxSongTicks: int32 = DefaultMaxSongTicks): CompiledSequencer =
  var maxTick: int32 = 0

  for track in s.tracks:
    var ct = CompiledTrack(trackId: track.id, mute: track.mute)
    for clip in track.clips:
      if clip.lengthTicks <= 0: continue
      var cc = CompiledClip(
        startTick: clip.startTick,
        lengthTicks: clip.lengthTicks,
        loopEnabled: clip.loopEnabled
      )
      expandClipEvents(clip, track.id, maxSongTicks, cc.events)
      cc.events.sort(proc(a, b: ScheduledEvent): int = cmp(a.tick, b.tick))
      if cc.events.len > 0:
        let last = cc.events[^1].tick
        if last > maxTick: maxTick = last
      ct.clips.add cc
    result.tracks.add ct

  for lane in s.automationLanes:
    var ca = CompiledAutomation(nodeId: lane.nodeId, paramId: lane.paramId)
    ca.points = lane.points  
    if ca.points.len > 0:
      let last = ca.points[^1].tick
      if last > maxTick: maxTick = last
    result.automation.add ca

  result.maxTick = maxTick

# =============================================================================
# Runtime — audio thread
# =============================================================================

proc initRuntime*(compiled: ptr CompiledSequencer): SequencerRuntime =
  result.compiled = compiled
  result.droppedEvents = 0'u32

proc processBlock*(rt: var SequencerRuntime,
                   blockStartTick, blockEndTick: int64,
                   ticksPerSample: float32,
                   events: var EventQueue) =
  clearEvents(addr events)

  if rt.compiled.isNil: return
  if ticksPerSample <= 0.0f: return

  let invTps = 1.0f / ticksPerSample

  for track in rt.compiled.tracks:
    if track.mute: continue
    for clip in track.clips:
      var lo = 0
      var hi = clip.events.len
      while lo < hi:
        let mid = (lo + hi) div 2
        if clip.events[mid].tick < blockStartTick:
          lo = mid + 1
        else:
          hi = mid

      var i = lo
      while i < clip.events.len:
        let ev = clip.events[i]
        if ev.tick >= blockEndTick: break

        let tickDiff    = int64(ev.tick) - blockStartTick
        let exactOffset = float32(tickDiff) * invTps
        let offsetInt   = int32(exactOffset)
        let offsetFrac  = exactOffset - float32(offsetInt)

        var aev: RealtimeEvent
        aev.frameOffset = uint32(offsetInt)
        aev.subFrame    = offsetFrac
        aev.kind        = ev.kind
        aev.port        = 0
        aev.channel     = ev.channel
        aev.data[0]     = float32(ev.note)
        aev.data[1]     = ev.velocity
        aev.data[2]     = 0.0f
        aev.data[3]     = 0.0f

        if not pushEvent(addr events, aev):
          inc rt.droppedEvents
        inc i

# =============================================================================
# Automation — RT read
# =============================================================================

proc interpolate(v1, v2: float32, t: float32, curve: AutomationCurve): float32 {.inline.} =
  case curve
  of acLinear:
    v1 + (v2 - v1) * t
  of acStep:
    v1
  of acSmooth:
    let u = (1.0f - cos(t * PI_F)) * 0.5f
    v1 + (v2 - v1) * u
  of acBezier:
    let u = t * t * (3.0f - 2.0f * t)
    v1 + (v2 - v1) * u

proc findAutomationLane(c: CompiledSequencer,
                        nodeId: int32, paramId: uint32): int =
  for i in 0 ..< c.automation.len:
    if c.automation[i].nodeId == nodeId and
       c.automation[i].paramId == paramId:
      return i
  return -1

proc getAutomationValue*(c: CompiledSequencer,
                         nodeId: int32, paramId: uint32,
                         tick: int64): float32 =
  let idx = findAutomationLane(c, nodeId, paramId)
  if idx < 0: return 0.0f
  let pts = c.automation[idx].points
  if pts.len == 0: return 0.0f
  if pts.len == 1: return pts[0].value

  let t = int32(tick)
  if t <= pts[0].tick: return pts[0].value
  if t >= pts[^1].tick: return pts[^1].value

  var lo = 0
  var hi = pts.len - 1
  while hi - lo > 1:
    let mid = (lo + hi) div 2
    if pts[mid].tick <= t: lo = mid
    else:                  hi = mid

  let p1 = pts[lo]
  let p2 = pts[hi]
  let span = float32(p2.tick - p1.tick)
  if span <= 0.0f: return p1.value
  let frac = float32(t - p1.tick) / span
  interpolate(p1.value, p2.value, frac, p1.curve)

proc fillAutomationBlock*(c: CompiledSequencer,
                          nodeId: int32, paramId: uint32,
                          blockStartTick: int64,
                          ticksPerSample: float32,
                          output: ptr UncheckedArray[float32],
                          numSamples: int) =
  if numSamples <= 0: return
  let idx = findAutomationLane(c, nodeId, paramId)
  if idx < 0:
    for s in 0 ..< numSamples: output[s] = 0.0f
    return

  let pts = c.automation[idx].points
  if pts.len == 0:
    for s in 0 ..< numSamples: output[s] = 0.0f
    return

  var seg = 0
  let lastIdx = pts.len - 1
  for s in 0 ..< numSamples:
    let sampleOffset = float32(s) * ticksPerSample
    let tick = blockStartTick + int64(sampleOffset)
    let t = int32(tick)

    if t <= pts[0].tick:
      output[s] = pts[0].value
      continue
    if t >= pts[lastIdx].tick:
      output[s] = pts[lastIdx].value
      continue

    while seg + 1 < lastIdx and pts[seg + 1].tick <= t:
      inc seg

    let p1 = pts[seg]
    let p2 = pts[seg + 1]
    let span = float32(p2.tick - p1.tick)
    if span <= 0.0f:
      output[s] = p1.value
    else:
      let frac = float32(t - p1.tick) / span
      output[s] = interpolate(p1.value, p2.value, frac, p1.curve)

{.pop.}