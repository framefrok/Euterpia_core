# libs/compose/engine.nim
#
# Рендер проекта ПРЯМО ИЗ КОДА (issue #300): собрать сцену и посчитать WAV,
# не прибегая к `build.sh` и CLI. Это те же шаги, что делает `cli/cmd_render`:
#   `loadScene` (nodes/builtin/scene_loader) → `renderToWav` (core/offline_render).
#
# Почему это в библиотеке, а не в CLI: композиция — это программа на Nim;
# ей естественно и строить проект, и получать звук одной командой
# (`nim r generate.nim` → `.eut` + `.notes` + `.wav`). CLI остаётся для
# ручной работы и CI.
#
# Слой: верхний (libs), поверх Core и Nodes.

import std/sequtils

import project
import sdk/node_registry
import builtin/builtin_registry
import builtin/scene_loader
import offline_render
import compose/song
import compose/progress
import compose/song

type
  RenderResult* = object
    ok*: bool
    error*: string
    path*: string
    seconds*: float64
    warnings*: seq[string]
      ## Предупреждения проверки раскладки: пустые партии, «в раскладке
      ## нет ни одной партии». Рендер при этом честно считает тишину, но
      ## сказать об этом обязан (#311).

proc renderProject*(proj: ProjectFormat; wavPath: string; tempo: float64;
                    tailSeconds: float64 = 2.0; blockSize: int32 = 512;
                    bits: int32 = 16;
                    onProgress: RenderProgressProc = nil): RenderResult =
  ## Считает проект в WAV. Пайплайн собирается заново и освобождается здесь —
  ## вызывающему остаётся только файл и отчёт.
  ##
  ## `onProgress == nil` — прогресс включается сам, если stderr терминал
  ## (issue #310). Явный колбэк имеет приоритет и работает всегда.
  var reg = initNodeRegistry()
  discard registerBuiltinNodes(reg)

  let sr = if proj.metadata.sampleRate > 0.0f32: proj.metadata.sampleRate
           else: 48000.0f32
  var scene = loadScene(reg, proj, -1, int32(sr))
  if not scene.ok:
    result.error = scene.error
    return
  defer: destroyScene(scene)

  let scoreSeconds = sceneSeconds(scene, tempo)
  var opts = defaultRenderOptions(int32(sr), blockSize, scoreSeconds + tailSeconds)
  opts.bitsPerSample = bits
  opts.tempo = tempo
  opts.automation = scene.automation
  let totalSeconds = float64(opts.totalFrames) / float64(sr)
  let printer =
    if onProgress != nil: onProgress
    else: autoProgress(totalSeconds, int32(sr))

  # Владение пайплайном переходит рендеру: движок внутри `renderToWav`
  # забирает граф себе и освобождает его вместе с движком. Без этой
  # «забывчивости» `destroyScene` ниже освободил бы тот же пайплайн второй
  # раз — двойное освобождение, которое портит кучу.
  let pipeline = detachPipeline(scene)
  opts.onProgress = printer
  let rep = renderToWav(wavPath, pipeline, opts)
  result.ok = rep.ok
  result.error = rep.error
  result.path = rep.path
  result.seconds = rep.seconds

proc render*(arr: Arrangement; wavPath: string; tailSeconds: float64 = 2.0;
             blockSize: int32 = 512; bits: int32 = 16;
             onProgress: RenderProgressProc = nil): RenderResult =
  ## Рендер раскладки из `compose/song`.
  ##
  ## Проверка ДО сборки (#311): неизвестный тип ноды или опечатка в имени
  ## параметра возвращаются как `ok = false` с текстом, а не падают и не
  ## теряются молча.
  let problems = validate(arr)
  if hasErrors(problems):
    result.error = problemBlock(problems)
    # Печатаем, а не только возвращаем: скрипт вправе не смотреть в
    # `rr.error` (многие только печатают `ok = false`), а молчаливая
    # ошибка — ровно то, что чиним (#311). Дублирование с собственным
    # `echo rr.error` безобидно: это stderr, а не отчёт команды.
    toStderr(problemBlock(problems))
    return
  warnComposition(problems)
  result.warnings = problems.filterIt(not isError(it))
  renderProject(buildProject(arr), wavPath, float64(arr.tempo), tailSeconds,
                blockSize, bits, onProgress)
