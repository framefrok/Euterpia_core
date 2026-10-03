import std/math
import builtin/native/eut_native

const Sr = 48000.0f

proc rms(a: openArray[float32]): float32 =
  var s = 0.0
  for x in a: s += float64(x) * float64(x)
  float32(sqrt(s / float64(a.len)))

proc renderOrgan(): float32 =
  let g = newOrgan(8, Sr)
  doAssert g.isReady
  organSet(addr g, 0.6f, 0.8f, 0.3f, 5.0f, 0.0f, 0.8f)
  organNoteOn(addr g, 60, 0.9f)
  organNoteOn(addr g, 64, 0.9f)
  var l, r: array[4096, float32]
  var peak = 0.0f
  for b in 0 ..< 12:
    for i in 0 ..< l.len:
      l[i] = 0.0f; r[i] = 0.0f
    organProcess(addr g, addr l[0], addr r[0], 1, l.len, 0.0f, 0.0f)
    if b == 5: peak = max(peak, rms(l))
  organNoteOff(addr g, 60)
  organNoteOff(addr g, 64)
  freeOrgan(addr g)
  peak

proc renderPiano(): float32 =
  let g = newPiano(16, Sr)
  doAssert g.isReady
  pianoSet(addr g, 0.7f, 2.5f, 1.2f, 0.3f, 0.25f, 0.0f, 0.8f)
  pianoPedal(addr g, true)
  pianoNoteOn(addr g, 57, 1.0f)
  var l, r: array[4096, float32]
  var peak = 0.0f
  for b in 0 ..< 12:
    for i in 0 ..< l.len:
      l[i] = 0.0f; r[i] = 0.0f
    pianoProcess(addr g, addr l[0], addr r[0], 1, l.len, 0.0f, 0.0f)
    peak = max(peak, rms(l))
  pianoAllOff(addr g)
  freePiano(addr g)
  peak

proc renderGuitar(): float32 =
  let g = newGuitar(8, Sr)
  doAssert g.isReady
  guitarSet(addr g, 0.3f, 0.6f, 0.6f, 0.3f, 0.0f, 0.2f, 0.0f, 0.8f)
  guitarNoteOn(addr g, 52, 0.9f)
  var l, r: array[4096, float32]
  var peak = 0.0f
  for b in 0 ..< 12:
    for i in 0 ..< l.len:
      l[i] = 0.0f; r[i] = 0.0f
    guitarProcess(addr g, addr l[0], addr r[0], 1, l.len, 0.0f, 0.0f)
    peak = max(peak, rms(l))
  freeGuitar(addr g)
  peak

proc renderDrums(): float32 =
  let g = newDrums(16, Sr)
  doAssert g.isReady
  drumsSet(addr g, 0.0f, 1.0f, 1.0f, 0.6f, 0.25f, 0.0f, 0.85f)
  doAssert drumsPieceForNote(36) == EutDrumKick
  doAssert drumsPieceForNote(99) == -1
  drumsNoteOn(addr g, 36, 1.0f)
  drumsNoteOn(addr g, 42, 0.8f)
  var l, r: array[4096, float32]
  var peak = 0.0f
  for b in 0 ..< 12:
    for i in 0 ..< l.len:
      l[i] = 0.0f; r[i] = 0.0f
    drumsProcess(addr g, addr l[0], addr r[0], 1, l.len)
    peak = max(peak, rms(l))
  drumsAllOff(addr g)
  freeDrums(addr g)
  peak

doAssert abiCheck()
echo "organ=", renderOrgan()
echo "piano=", renderPiano()
echo "guitar=", renderGuitar()
echo "drums=", renderDrums()
doAssert sizeof(Organ) == sizeof(pointer)
doAssert sizeof(Piano) == sizeof(pointer)
doAssert sizeof(Guitar) == 2 * sizeof(pointer)
doAssert sizeof(Drums) == sizeof(pointer)
echo "SMOKE OK"
