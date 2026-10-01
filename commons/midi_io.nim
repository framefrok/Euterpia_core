#midi_io.nim
import std/atomics
import signal_types

{.push raises: [].}

when defined(windows):
  const RtMidiLib = "rtmidi.dll"
elif defined(macosx):
  const RtMidiLib = "librtmidi.dylib"
else:
  const RtMidiLib = "librtmidi.so"

type
  RtMidiPtr = pointer
  RtMidiInPtr = pointer
  RtMidiOutPtr = pointer

  MidiMessage* = object
    status*: uint8
    data1*: uint8
    data2*: uint8
    timestamp*: float64
    portId*: int32

  MidiDeviceType* = enum
    mdInput
    mdOutput

  MidiDevice* = object
    id*: int32
    name*: string
    deviceType*: MidiDeviceType
    isOpen*: bool
    channelFilter*: int32

  # Correct RtMidi C API callback signature
  MidiInputCallback = proc(timeStamp: cdouble, message: ptr UncheckedArray[uint8], messageSize: csize_t, userData: pointer) {.cdecl.}

{.pragma: rtmidi_import, importc, dynlib: RtMidiLib.}

proc rtmidi_in_create_default(): RtMidiInPtr {.rtmidi_import.}
proc rtmidi_out_create_default(): RtMidiOutPtr {.rtmidi_import.}
proc rtmidi_in_free(device: RtMidiInPtr) {.rtmidi_import.}
proc rtmidi_out_free(device: RtMidiOutPtr) {.rtmidi_import.}
proc rtmidi_get_port_count(device: RtMidiPtr): cuint {.rtmidi_import.}
proc rtmidi_get_port_name(device: RtMidiPtr, portNumber: cuint, bufOut: cstring, bufLen: ptr cint): cint {.rtmidi_import.}
proc rtmidi_open_port(device: RtMidiPtr, portNumber: cuint, portName: cstring) {.rtmidi_import.}
proc rtmidi_close_port(device: RtMidiPtr) {.rtmidi_import.}
proc rtmidi_in_set_callback(device: RtMidiInPtr, callback: MidiInputCallback, userData: pointer) {.rtmidi_import.}
proc rtmidi_in_cancel_callback(device: RtMidiInPtr) {.rtmidi_import.}
proc rtmidi_out_send_message(device: RtMidiOutPtr, message: ptr uint8, length: cint): cint {.rtmidi_import.}
proc rtmidi_in_ignore_types(device: RtMidiInPtr, midiSysex: bool, midiTime: bool, midiSense: bool) {.rtmidi_import.}

const MidiRingBufferSize = 1024 # Must be power of 2 for fast modulo

type
  MidiRingBuffer* = object
    buffer: array[MidiRingBufferSize, MidiMessage]
    writePos: Atomic[int]
    readPos: Atomic[int]

proc initMidiRingBuffer*(rb: var MidiRingBuffer) =
  rb.writePos.store(0, moRelaxed)
  rb.readPos.store(0, moRelaxed)

proc pushMidiMessage*(rb: var MidiRingBuffer, msg: MidiMessage): bool {.inline.} =
  let currentWrite = rb.writePos.load(moRelaxed)
  let nextWrite = (currentWrite + 1) and (MidiRingBufferSize - 1)
  if nextWrite == rb.readPos.load(moAcquire):
    return false # Full
  rb.buffer[currentWrite] = msg
  rb.writePos.store(nextWrite, moRelease)
  return true

proc popMidiMessage*(rb: var MidiRingBuffer, msg: var MidiMessage): bool {.inline.} =
  let currentRead = rb.readPos.load(moRelaxed)
  if currentRead == rb.writePos.load(moAcquire):
    return false # Empty
  msg = rb.buffer[currentRead]
  rb.readPos.store((currentRead + 1) and (MidiRingBufferSize - 1), moRelease)
  return true

type
  MidiInputPort* = object
    device: RtMidiInPtr
    info: MidiDevice
    ringBuffer: MidiRingBuffer
    timeAccumulator: float64 # MIDI clock accumulator (seconds)

  MidiOutputPort* = object
    device: RtMidiOutPtr
    info: MidiDevice

  MidiManager* = object
    inputs: seq[MidiInputPort]
    outputs: seq[MidiOutputPort]
    sampleRate: float64

proc getPortName(device: RtMidiPtr, portNumber: cuint): string =
  var bufLen: cint = 0
  discard rtmidi_get_port_name(device, portNumber, nil, addr bufLen)
  if bufLen > 0:
    var buf = newString(bufLen)
    discard rtmidi_get_port_name(device, portNumber, cstring(buf), addr bufLen)
    result = buf
    if result.len > 0 and result[^1] == '\0':
      result.setLen(result.len - 1)
  else:
    result = ""

proc midiInputCallback(timeStamp: cdouble, message: ptr UncheckedArray[uint8], messageSize: csize_t, userData: pointer) {.cdecl.} =
  let port = cast[ptr MidiInputPort](userData)
  if port == nil: return
  
  # Accumulate delta time to get absolute seconds since port open
  port.timeAccumulator += timeStamp
  
  if messageSize == 0 or message == nil: return
  
  let status: uint8 = message[0]
  let data1: uint8 = if messageSize > 1 and status < 0xF0: message[1] else: 0'u8
  let data2: uint8 = if messageSize > 2 and status < 0xF0: message[2] else: 0'u8
  
  # Convert Note On with velocity 0 to Note Off
  var finalStatus: uint8 = status
  var finalData2: uint8 = data2
  if (status and 0xF0) == 0x90 and data2 == 0:
    finalStatus = 0x80 or (status and 0x0F)
    finalData2 = 0'u8
    
  var midiMsg = MidiMessage(
    status: finalStatus,
    data1: data1,
    data2: finalData2,
    timestamp: port.timeAccumulator,
    portId: port.info.id
  )
  
  discard port.ringBuffer.pushMidiMessage(midiMsg)

proc initMidiManager*(sampleRate: float64): MidiManager =
  result.inputs = @[]
  result.outputs = @[]
  result.sampleRate = sampleRate

proc refreshDevices*(mgr: var MidiManager) =
  for i in 0 ..< mgr.inputs.len:
    if mgr.inputs[i].info.isOpen:
      rtmidi_in_cancel_callback(mgr.inputs[i].device)
      rtmidi_close_port(mgr.inputs[i].device)
    rtmidi_in_free(mgr.inputs[i].device)
    
  for i in 0 ..< mgr.outputs.len:
    if mgr.outputs[i].info.isOpen:
      rtmidi_close_port(mgr.outputs[i].device)
    rtmidi_out_free(mgr.outputs[i].device)
    
  mgr.inputs.setLen(0)
  mgr.outputs.setLen(0)
  
  # Probe Inputs
  let probeIn = rtmidi_in_create_default()
  if probeIn != nil:
    let count = rtmidi_get_port_count(probeIn)
    for i in 0 ..< count:
      let name = getPortName(probeIn, cuint(i))
      # Create a dedicated RtMidiInPtr for each logical port to fix the single-handle bug
      let dev = rtmidi_in_create_default()
      if dev != nil:
        var port: MidiInputPort
        port.device = dev
        port.info = MidiDevice(
          id: int32(i),
          name: name,
          deviceType: mdInput,
          isOpen: false,
          channelFilter: -1
        )
        port.timeAccumulator = 0.0
        initMidiRingBuffer(port.ringBuffer)
        mgr.inputs.add(port)
    rtmidi_in_free(probeIn)
    
  # Probe Outputs
  let probeOut = rtmidi_out_create_default()
  if probeOut != nil:
    let count = rtmidi_get_port_count(probeOut)
    for i in 0 ..< count:
      let name = getPortName(probeOut, cuint(i))
      let dev = rtmidi_out_create_default()
      if dev != nil:
        var port: MidiOutputPort
        port.device = dev
        port.info = MidiDevice(
          id: int32(i),
          name: name,
          deviceType: mdOutput,
          isOpen: false,
          channelFilter: -1
        )
        mgr.outputs.add(port)
    rtmidi_out_free(probeOut)

proc openInput*(mgr: var MidiManager, deviceId: int32): bool =
  if deviceId < 0 or deviceId >= int32(mgr.inputs.len):
    return false
  
  let port = addr mgr.inputs[deviceId]
  if port.info.isOpen: return true
  
  port.timeAccumulator = 0.0 
  
  rtmidi_open_port(port.device, cuint(deviceId), "Euterpia MIDI In")
  rtmidi_in_ignore_types(port.device, true, true, true)
  rtmidi_in_set_callback(port.device, midiInputCallback, cast[pointer](port))
  port.info.isOpen = true
  return true

proc openOutput*(mgr: var MidiManager, deviceId: int32): bool =
  if deviceId < 0 or deviceId >= int32(mgr.outputs.len):
    return false
  
  let port = addr mgr.outputs[deviceId]
  if port.info.isOpen: return true
  
  rtmidi_open_port(port.device, cuint(deviceId), "Euterpia MIDI Out")
  port.info.isOpen = true
  return true

proc closeInput*(mgr: var MidiManager, deviceId: int32) =
  if deviceId < 0 or deviceId >= int32(mgr.inputs.len): return
  let port = addr mgr.inputs[deviceId]
  if port.info.isOpen:
    rtmidi_in_cancel_callback(port.device)
    rtmidi_close_port(port.device)
    port.info.isOpen = false

proc closeOutput*(mgr: var MidiManager, deviceId: int32) =
  if deviceId < 0 or deviceId >= int32(mgr.outputs.len): return
  let port = addr mgr.outputs[deviceId]
  if port.info.isOpen:
    rtmidi_close_port(port.device)
    port.info.isOpen = false

proc pollMidiEvents*(mgr: var MidiManager, currentHostTimeSec: float64, output: ptr EventQueue) =
  output.clearEvents()
  
  for i in 0 ..< mgr.inputs.len:
    let port = addr mgr.inputs[i]
    if not port.info.isOpen: continue
    
    var msg: MidiMessage
    while port.ringBuffer.popMidiMessage(msg):
      let status = msg.status and 0xF0
      let channel = msg.status and 0x0F
      
      if port.info.channelFilter >= 0 and int32(channel) != port.info.channelFilter:
        continue
        
      # Convert absolute MIDI time (seconds) to relative block frames
      let timeDiffSec = msg.timestamp - currentHostTimeSec
      var frameOffset = int32(timeDiffSec * mgr.sampleRate)
      
      # Clamp bounds
      if frameOffset < 0: frameOffset = 0
      if frameOffset >= MaxBlockSize: frameOffset = MaxBlockSize - 1
      
      var ev: RealtimeEvent
      ev.frameOffset = uint32(frameOffset)
      ev.subFrame = 0.0f
      ev.port = uint8(i)
      ev.channel = uint8(channel)
      
      case status
      of 0x90:
        ev.kind = evNoteOn
        ev.data[0] = float32(msg.data1)
        ev.data[1] = float32(msg.data2) / 127.0f
        discard output.pushEvent(ev)
      of 0x80:
        ev.kind = evNoteOff
        ev.data[0] = float32(msg.data1)
        ev.data[1] = 0.0f
        discard output.pushEvent(ev)
      of 0xB0:
        ev.kind = evCC
        ev.data[0] = float32(msg.data1)
        ev.data[1] = float32(msg.data2) / 127.0f
        discard output.pushEvent(ev)
      of 0xE0: # Pitch Bend
        ev.kind = evPitchBend
        let bend = (int32(msg.data2) shl 7) or int32(msg.data1)
        ev.data[0] = float32(bend - 8192) / 8192.0f
        discard output.pushEvent(ev)
      of 0xD0: # Aftertouch
        ev.kind = evAftertouch
        ev.data[0] = float32(msg.data1) / 127.0f
        discard output.pushEvent(ev)
      of 0xC0: # Program Change
        ev.kind = evProgramChange
        ev.data[0] = float32(msg.data1)
        discard output.pushEvent(ev)
      else:
        discard
        
  output.sortEvents()

proc sendNoteOn*(mgr: var MidiManager, deviceId: int32, channel, note, velocity: uint8) =
  if deviceId < 0 or deviceId >= int32(mgr.outputs.len): return
  let port = addr mgr.outputs[deviceId]
  if not port.info.isOpen: return
  
  var msg: array[3, uint8] = [0x90'u8 or (channel and 0x0F), note, velocity]
  discard rtmidi_out_send_message(port.device, addr msg[0], 3)

proc sendNoteOff*(mgr: var MidiManager, deviceId: int32, channel, note: uint8) =
  if deviceId < 0 or deviceId >= int32(mgr.outputs.len): return
  let port = addr mgr.outputs[deviceId]
  if not port.info.isOpen: return
  
  var msg: array[3, uint8] = [0x80'u8 or (channel and 0x0F), note, 0'u8]
  discard rtmidi_out_send_message(port.device, addr msg[0], 3)

proc sendCC*(mgr: var MidiManager, deviceId: int32, channel, cc, value: uint8) =
  if deviceId < 0 or deviceId >= int32(mgr.outputs.len): return
  let port = addr mgr.outputs[deviceId]
  if not port.info.isOpen: return
  
  var msg: array[3, uint8] = [0xB0'u8 or (channel and 0x0F), cc, value]
  discard rtmidi_out_send_message(port.device, addr msg[0], 3)

proc destroyMidiManager*(mgr: var MidiManager) =
  for i in 0 ..< mgr.inputs.len:
    if mgr.inputs[i].info.isOpen:
      rtmidi_in_cancel_callback(mgr.inputs[i].device)
      rtmidi_close_port(mgr.inputs[i].device)
    rtmidi_in_free(mgr.inputs[i].device)
    
  for i in 0 ..< mgr.outputs.len:
    if mgr.outputs[i].info.isOpen:
      rtmidi_close_port(mgr.outputs[i].device)
    rtmidi_out_free(mgr.outputs[i].device)
    
  mgr.inputs.setLen(0)
  mgr.outputs.setLen(0)

{.pop.}