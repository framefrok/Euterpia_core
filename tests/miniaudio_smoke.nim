# tests/miniaudio_smoke.nim
#
# Smoke-тест miniaudio-адаптера (issue #31).
#
# В отличие от unit-набора, здесь реально СОБИРАЕТСЯ и ЛИНКУЕТСЯ TU
# miniaudio (adapters/miniaudio/miniaudio_impl.c). Это единственное место,
# где проверяется, что C-шим компилируется и что адаптер не роняется на
# старте без звуковой подсистемы.
#
# Тест НЕ требует наличия устройства: если backend/устройство недоступны,
# печатается SKIP и процесс завершается с кодом 0 — но при этом
# обязательно проверяется, что мы получили КОД ОШИБКИ, а не падение.
#
# Запуск: nimble miniaudioSmoke

import std/[os, atomics, monotimes, times]
import audio_backend_api
import audio_backend_miniaudio

var blocksRendered: Atomic[int]
var renderedSamples: Atomic[int]

proc smokeRender(
  engineCtx: pointer;
  driverIn: ptr UncheckedArray[float32];
  driverOut: ptr UncheckedArray[float32];
  frames: int32;
  inputChannels: int32;
  outputChannels: int32
) {.cdecl, raises: [].} =
  ## Аудио-поток: без аллокаций и локов.
  if driverOut.isNil or outputChannels <= 0:
    return
  let total = int(frames) * int(outputChannels)
  var i = 0
  while i < total:
    driverOut[i] = 0.0f
    inc i
  discard blocksRendered.fetchAdd(1, moRelaxed)
  discard renderedSamples.fetchAdd(total, moRelaxed)
  discard driverIn
  discard inputChannels

proc busyWaitMs(ms: int) {.inline.} =
  ## Занят-ожидание: sleep() может бросать, а callback обязан быть
  ## raises: []. Для проверки перегрузки этого достаточно.
  let t0 = getMonoTime()
  let budget = initDuration(milliseconds = ms)
  while getMonoTime() - t0 < budget:
    discard

proc overloadRender(
  engineCtx: pointer;
  driverIn: ptr UncheckedArray[float32];
  driverOut: ptr UncheckedArray[float32];
  frames: int32;
  inputChannels: int32;
  outputChannels: int32
) {.cdecl, raises: [].} =
  ## Намеренно не укладывается в длительность блока (25 мс против ~10.7 мс
  ## при 512 кадрах и 48 кГц) — так проверяется критерий приёмки #31.
  busyWaitMs(25)
  if driverOut.isNil or outputChannels <= 0:
    return
  let total = int(frames) * int(outputChannels)
  var i = 0
  while i < total:
    driverOut[i] = 0.0f
    inc i
  discard blocksRendered.fetchAdd(1, moRelaxed)
  discard driverIn
  discard inputChannels


proc fail(msg: string) {.noreturn.} =
  echo "FAIL: ", msg
  quit(1)

proc main() =
  let api = createMiniaudioBackend()
  if api.isNil:
    fail("createMiniaudioBackend вернул nil")

  let ierr = backendInit(api, nil)
  if ierr != abeOk:
    # Отсутствие звуковой подсистемы — не падение и не провал теста.
    echo "SKIP: miniaudio init -> ", ierr, " (нет backend'а на этом хосте)"
    destroyMiniaudioBackend(api)
    return

  let nOut = backendDeviceCount(api, false)
  echo "miniaudio: выходных устройств: ", nOut

  var info: AudioDeviceInfo
  for i in 0 ..< nOut:
    if backendDeviceInfo(api, i, false, info):
      echo "  [", info.id, "] ", info.name,
           " (", info.maxOutputChannels, " ch, ",
           info.defaultSampleRate, " Hz",
           if info.isDefault: ", default" else: "", ")"

  if nOut <= 0:
    echo "SKIP: нет выходных устройств"
    # Контракт: без устройства open обязан вернуть код ошибки, а не упасть.
    let cfg = AudioStreamConfig(
      sampleRate: 48000.0, blockSize: 128,
      inputChannels: 0, outputChannels: 2,
      inputDevice: DefaultDeviceIndex, outputDevice: DefaultDeviceIndex)
    let oerr = backendOpen(api, cfg, smokeRender, nil)
    if oerr == abeOk:
      fail("open без устройств неожиданно вернул abeOk")
    echo "  open без устройства -> ", oerr, " (ожидаемый код ошибки)"
    destroyMiniaudioBackend(api)
    return

  let cfg = AudioStreamConfig(
    sampleRate: 48000.0, blockSize: 128,
    inputChannels: 0, outputChannels: 2,
    inputDevice: DefaultDeviceIndex, outputDevice: DefaultDeviceIndex)

  let oerr = backendOpen(api, cfg, smokeRender, nil)
  if oerr != abeOk:
    echo "SKIP: open -> ", oerr
    destroyMiniaudioBackend(api)
    return

  if backendLatencyFrames(api) != 128:
    fail("latencyFrames != 128 (blockSize)")

  if backendStart(api) != abeOk:
    fail("start не удался после успешного open")

  if not backendIsRunning(api):
    fail("isRunning == false после start")

  sleep(300)

  let blocks = blocksRendered.load(moRelaxed)
  echo "обработано блоков: ", blocks,
       ", сэмплов: ", renderedSamples.load(moRelaxed),
       ", xruns: ", backendXrunCount(api)
  if blocks <= 0:
    fail("audio callback ни разу не сработал")

  if backendStop(api) != abeOk:
    fail("stop не удался")
  if backendIsRunning(api):
    fail("isRunning == true после stop")

  backendClose(api)

  # --- критерий приёмки #31: искусственная перегрузка -> xruns растёт ---
  let overloadCfg = AudioStreamConfig(
    sampleRate: 48000.0, blockSize: 512,
    inputChannels: 0, outputChannels: 2,
    inputDevice: DefaultDeviceIndex, outputDevice: DefaultDeviceIndex)

  if backendOpen(api, overloadCfg, overloadRender, nil) != abeOk:
    echo "SKIP: open для фазы перегрузки не удался"
    destroyMiniaudioBackend(api)
    return

  if backendStart(api) != abeOk:
    fail("start не удался в фазе перегрузки")

  sleep(400)
  let xruns = backendXrunCount(api)
  echo "xruns после искусственной перегрузки: ", xruns
  discard backendStop(api)
  backendClose(api)
  destroyMiniaudioBackend(api)

  if xruns == 0:
    fail("xrunCount не вырос при перегрузке блока")

  echo "miniaudio smoke OK"

main()
