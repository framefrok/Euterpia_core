# tests/tmp_drums_measure.nim
#
# Измеритель голоса ударных — инструмент разработки, НЕ часть прогона CI
# (как и `tests/tmp_smoke_inst.nim`). Печатает объективные метрики, по
# которым видно «проработку» удара:
#   * пик/RMS — уровень и баланс деталей;
#   * спектральный центроид в разные фазы удара — раскрывается ли звук во
#     времени (у синтетического «одного тумблера» центроид не менялся);
#   * T40 — время спада на 40 дБ;
#   * bursts — число хлопков клэпа;
#   * отчёт инспектора аудио (#290) — нет ли щелчков/клиппинга/алиасинга.
#
# Запуск:  nim c -f -r --hints:off tests/tmp_drums_measure.nim
# Ключ `-f` обязателен: Nim не пересобирает C-ядро, если изменился только
# `.c` (кеш в ~/.cache/nim сверяет `.sha1` от аргументов сборки, а не от
# файла), и без `-f` замеры покажут старый звук.

import std/[math, strformat]
import builtin/native/eut_native
import audio_inspect
import spectrum

const
  Sr = 48000.0f
  N = 96000
  Fft = 1024
  Block = 256

proc renderOne(note: int; vel: float32; mono: var seq[float32]) =
  var g = newDrums(16, Sr)
  drumsSet(addr g, 1.0f, 1.0f, 1.0f, 0.5f, 0.15f, 0.0f, 0.85f)
  drumsNoteOn(addr g, note, vel)
  mono = newSeq[float32](N)
  var l, r: array[Block, float32]
  var pos = 0
  while pos < N:
    let n = min(Block, N - pos)
    for i in 0 ..< n:
      l[i] = 0.0f
      r[i] = 0.0f
    drumsProcess(addr g, addr l[0], addr r[0], 1, n)
    for i in 0 ..< n:
      mono[pos + i] = l[i]
    pos += n
  freeDrums(addr g)

proc peakOf(a: openArray[float32]): float32 =
  for x in a:
    result = max(result, abs(x))

proc rmsOf(a: openArray[float32]): float32 =
  var s = 0.0
  for x in a:
    s += float64(x) * float64(x)
  if a.len == 0: 0.0f else: float32(sqrt(s / float64(a.len)))

proc centroidAt(mono: openArray[float32]; pos, fft: int): float32 =
  ## Центроид спектра (взвешивание по мощности) в окне fft сэмплов.
  ## Окно задаётся на фазу удара: крек живёт ~4 мс, и длинное окно его
  ## «размывает» до неузнаваемости.
  if pos + fft > mono.len: return 0.0f
  var mag: seq[float32] = newSeq[float32](fft div 2 + 1)
  var frame = newSeq[float32](fft)
  for i in 0 ..< fft:
    frame[i] = mono[pos + i] * hannWindow(i, fft)
  magnitudeSpectrum(frame, mag)
  var num = 0.0
  var den = 0.0
  let hz = float64(hzPerBin(Sr, fft))
  for b in 0 ..< mag.len:
    let p = float64(mag[b]) * float64(mag[b])
    num += (hz * float64(b)) * p
    den += p
  if den <= 0.0: 0.0f else: float32(num / den)

proc t40(mono: openArray[float32]): float32 =
  ## Время от пика RMS-огибающей (окно 128) до падения на 40 дБ.
  const W = 128
  var env: seq[float32]
  var i = 0
  while i + W <= mono.len:
    env.add rmsOf(mono.toOpenArray(i, i + W - 1))
    i += W
  if env.len == 0: return 0.0f
  var peakIdx = 0
  for k in 0 ..< env.len:
    if env[k] > env[peakIdx]: peakIdx = k
  let thr = env[peakIdx] * 0.01f
  var k = peakIdx
  while k < env.len and env[k] > thr: inc k
  float32(k - peakIdx) * float32(W) / Sr

proc bursts(mono: openArray[float32]): int =
  ## Число всплесков огибающей в первых 80 мс (для клэпа должно быть ≥ 3).
  const W = 48     # 1 мс
  var env: seq[float32]
  var i = 0
  let limit = min(mono.len, int(0.08f * Sr))
  while i + W <= limit:
    env.add rmsOf(mono.toOpenArray(i, i + W - 1))
    i += W
  var mx = 0.0f
  for x in env: mx = max(mx, x)
  if mx <= 0.0f: return 0
  let thr = mx * 0.30f
  var rising = false
  for x in env:
    if not rising and x > thr:
      rising = true
      inc result
    elif rising and x < thr * 0.5f:
      rising = false

proc show(name: string; note: int; vel: float32) =
  var mono: seq[float32]
  renderOne(note, vel, mono)
  let p = peakOf(mono)
  let r = rmsOf(mono)
  # Фазы удара: крек (0-5 мс), ранняя (6-49 мс), тело (30-73 мс),
  # хвост (150-193 мс), самый хвост (450-493 мс).
  let c0 = centroidAt(mono, 0, 256)
  let c1 = centroidAt(mono, int(0.006f * Sr), 2048)
  let c2 = centroidAt(mono, int(0.030f * Sr), 2048)
  let c3 = centroidAt(mono, int(0.150f * Sr), 2048)
  let c4 = centroidAt(mono, int(0.450f * Sr), 2048)
  let d = t40(mono)
  let b = bursts(mono)
  echo fmt"{name:6} n={note:3} v={vel:4.2f} peak={p:6.3f} rms={r:6.4f} " &
       fmt"cent={c0:5.0f}/{c1:5.0f}/{c2:5.0f}/{c3:5.0f}/{c4:5.0f}Hz t40={d:5.3f}s bursts={b}"
  let rep = inspectMono(mono, Sr)
  for dfc in rep.defects:
    echo fmt"        {severityName(dfc.severity):5} {defectKindName(dfc.kind):10} @{dfc.startSec:6.3f}s {dfc.detail}"

const Pieces = [
  ("kick", 36), ("snare", 38), ("rim", 37), ("clap", 39),
  ("tomL", 41), ("tomM", 45), ("tomH", 48),
  ("hatC", 42), ("hatP", 44), ("hatO", 46), ("crash", 49), ("ride", 51)
]

echo "=== сильный удар (velocity 0.95) ==="
for (name, note) in Pieces:
  show(name, note, 0.95f)

echo "=== слабый удар (velocity 0.25) ==="
for (name, note) in Pieces:
  show(name, note, 0.25f)
