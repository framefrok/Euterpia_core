# examples/embed_render.nim
#
# Минимальная интеграция ядра EUTERPIA в сторонний хост (issue #213).
#
# ЧТО ЭТОТ ФАЙЛ ДОКАЗЫВАЕТ
#   Ровно то, что спрашивает разработчик чужого движка: «смогу ли я встроить
#   ваше ядро и не получить при этом GUI, глобальное состояние и сюрпризы в
#   audio-потоке?» Здесь нет ни CLI, ни Editor, ни файла проекта: только
#   публичные модули Core/Nodes и ~150 строк.
#
#   Хост владеет аудио-callback'ом сам (§66): он вызывает `renderBlock` из
#   своего аудиопотока так же, как это делает адаптер устройства. Никакой
#   скрытой «магии инициализации»: `createAudioEngine` — обычная функция,
#   возвращающая указатель.
#
# ТРИ ШАГА, ИЗ КОТОРЫХ СОСТОИТ ЛЮБОЕ ВСТРАИВАНИЕ
#   1. Собрать граф из нод (Node SDK: реестр типов → состояния → компиляция).
#   2. Отдать граф движку (`postGraphUpdate`) и крутить блоки в своей нити.
#   3. Забрать статистику (`pollMetrics`) и остановиться (`postStop`).
#
# Владение (важно, здесь чаще всего ошибаются):
#   * состояния нод — собственные объекты хоста: их освобождает тот, кто
#     создал (`destroyNodeState`), а НЕ движок;
#   * CompiledPipeline переходит движку вместе с `postGraphUpdate` и
#     освобождается в `destroyAudioEngine`;
#   * `renderToWav` забирает пайплайн так же — поэтому второй граф строится
#     с нуля (см. шаг 3).
#
# Запуск:
#   nimble embedExample        # сборка + прогон (то же делает джоб CI `embed`)
#   nim c -r examples/embed_render.nim

import std/[math, os, strutils, tables]

import signal_types
import graph_compiler
import compiled_pipeline
import audio_engine
import ipc_bus
import wav_codec
import offline_render
import sdk/node_registry
import sdk/pipeline_builder
import builtin/builtin_registry

const
  SampleRate = 48000
  BlockSize = 128
    ## Блок аудио-callback'а. Хост выбирает его сам; ядру важно лишь то,
    ## что 1 <= blockSize <= MaxBlockSize.
  RealtimeBlocks = 400
    ## Сколько блоков «крутит» хост. 400 * 128 / 48000 ≈ 1.07 с звука.
  WavSeconds = 1.0

# ==============================================================================
# Шаг 1. Граф из нод
#
# Тип ноды в графе описан строкой id ("euterpia.osc"), а состояние — сырым
# указателем (`userData`). За соответствие «строка -> дескриптор + фабрика»
# отвечает реестр; Core про реестр не знает (MANIFEST §54).
# ==============================================================================

type
  HostGraph = object
    reg: NodeRegistry
    # Состояния узлов: держим их у себя, чтобы освободить в destroyHostGraph.
    osc: EditorNode
    gain: EditorNode
    mix: EditorNode

proc buildHostGraph(g: var HostGraph) =
  ## osc (#1) → gain (#2) → mix (#3, мастер).
  ## Осциллятор свободно звучит без нотных событий — минимальный хост не
  ## обязан заводить секвенсор, чтобы что-то услышать.
  g.reg = initNodeRegistry()
  doAssert registerBuiltinNodes(g.reg) == BuiltinCount,
    "реестр встроенных нод разошёлся с BuiltinCount"

  doAssert g.reg.instantiateNode("euterpia.osc", 1, g.osc)
  doAssert g.reg.instantiateNode("euterpia.gain", 2, g.gain)
  doAssert g.reg.instantiateNode("euterpia.mix", 3, g.mix)

proc compileHostGraph(g: var HostGraph): ptr CompiledPipeline =
  ## Компиляция: граф связей → шаги пайплайна + привязка мастера.
  ## `3` — id ноды, чей выход идёт в аудиодрайвер.
  var graph: NodeGraph
  graph.nodes[1] = g.osc
  graph.nodes[2] = g.gain
  graph.nodes[3] = g.mix
  graph.connections.add EditorConnection(
    srcNodeId: 1, srcPortIdx: 0, dstNodeId: 2, dstPortIdx: 0,
    sigType: sigAudio
  )
  graph.connections.add EditorConnection(
    srcNodeId: 2, srcPortIdx: 0, dstNodeId: 3, dstPortIdx: 0,
    sigType: sigAudio
  )

  var cr: CompileResult
  var binding: ptr PipelineBinding
  doAssert buildPipeline(g.reg, graph, 3, cr, binding),
    "граф не компилируется"
  doAssert cr.success and not cr.pipeline.isNil
  cr.pipeline

proc destroyHostGraph(g: var HostGraph) =
  ## Состояния нод движку не принадлежат — освобождаем сами.
  for item in [("euterpia.osc", g.osc), ("euterpia.gain", g.gain),
               ("euterpia.mix", g.mix)]:
    let entry = g.reg.findNodeType(item[0])
    if not entry.isNil:
      destroyNodeState(entry, item[1].userData)

# ==============================================================================
# Шаг 2. Движок: команды и рендер блоков
# ==============================================================================

proc peakOf(buf: ptr UncheckedArray[float32]; count: int): float32 =
  var peak = 0.0f
  for i in 0 ..< count:
    let a = abs(buf[i])
    if a > peak:
      peak = a
  peak

proc renderRealtime(g: var HostGraph) =
  ## Хост владеет аудио-callback'ом: он сам зовёт `renderBlock` из своего
  ## потока. Драйверный буфер — interleaved stereo, `BlockSize * 2` float32.
  echo "-- шаг 2: движок и рендер блоков"
  let engine = createAudioEngine(float32(SampleRate), int32(BlockSize))
  doAssert engine != nil, "createAudioEngine вернул nil"

  # Команды кладутся в очередь и исполняются в audio-потоке (control → RT).
  # `postGraphUpdate` — единственный путь публикации графа в RT (MANIFEST §10).
  doAssert engine.postGraphUpdate(g.compileHostGraph())
  doAssert engine.postSetTempo(100.0)         # демонстрация команды контроля
  doAssert engine.postPlay()

  var outBuf: array[BlockSize * 2, float32]
  var pOut = cast[ptr UncheckedArray[float32]](addr outBuf[0])
  var peak = 0.0f
  for _ in 0 ..< RealtimeBlocks:
    engine.renderBlock(pOut)                   # ← это и есть audio callback
    let p = peakOf(pOut, outBuf.len)
    if p > peak:
      peak = p

  # Метрики читает control-поток: audio-поток в них ничего не пишет напрямую,
  # а кладёт в SPSC-очередь (pollMetrics — неблокирующий pop).
  var m: EngineMetric
  var last: EngineMetric
  while engine.pollMetrics(m):
    last = m
  echo "   блоков: ", RealtimeBlocks, ", blockSize: ", BlockSize,
       ", пик: ", formatFloat(float64(peak), ffDecimal, 4)
  if last.sampleRate > 0.0:
    echo "   метрика: sr=", formatFloat(last.sampleRate, ffDecimal, 0),
         " buffer=", last.bufferSize,
         " voices=", last.activeVoices,
         " xruns=", last.xruns

  doAssert peak > 0.01f, "граф выдал тишину — осциллятор не звучит"
  doAssert engine.postStop()
  destroyAudioEngine(engine)
  echo "   движок остановлен и освобождён"

# ==============================================================================
# Шаг 3. Офлайн-рендер в файл (тот же пайплайн, но без устройства)
#
# `renderToWav` ЗАБИРАЕТ пайплайн: внутри он отдаёт его движку, а движок
# освобождает его вместе с собой. Поэтому второй граф строится с нуля, а
# первый уже освобождён вместе с движком — двойного освобождения нет.
# ==============================================================================

proc renderOfflineToWav(outPath: string) =
  echo "-- шаг 3: офлайн-рендер в WAV"
  var g: HostGraph
  g.buildHostGraph()
  let pipeline = g.compileHostGraph()

  var opts = defaultRenderOptions(int32(SampleRate), int32(BlockSize), WavSeconds)
  opts.tempo = 100.0
  let rep = renderToWav(outPath, pipeline, opts)
  doAssert rep.ok, "рендер не удался: " & rep.error
  echo "   файл: ", rep.path, ", кадров: ", rep.frames,
       ", пик: ", formatFloat(float64(rep.peak), ffDecimal, 4),
       ", тишина: ", rep.silent
  doAssert not rep.silent, "рендер в файл дал тишину"

  # Проверяем не факт «файл есть», а что это настоящий WAV нужного формата.
  var reader = openWavReader(outPath)
  echo "   заголовок: ", reader.info.sampleRate, " Гц, ",
       reader.info.channels, " канала, ",
       reader.info.bitsPerSample, " бит, ",
       reader.info.numFrames, " кадров"
  doAssert reader.info.sampleRate == SampleRate
  doAssert reader.info.channels == 2
  doAssert reader.info.numFrames > 0
  close(reader)

  g.destroyHostGraph()

# ==============================================================================

proc main() =
  # Каталог вывода: пример должен собираться и работать «из коробки»,
  # в том числе когда `build/` ещё нет (чистый клон).
  createDir("build")
  echo "=== EUTERPIA: встраивание в сторонний движок (issue #213) ==="
  echo "-- шаг 1: граф euterpia.osc -> euterpia.gain -> euterpia.mix (мастер)"

  var g: HostGraph
  g.buildHostGraph()
  echo "   зарегистрировано типов нод: ", g.reg.count(), " (BuiltinCount=",
       BuiltinCount, ")"
  g.renderRealtime()
  g.destroyHostGraph()

  renderOfflineToWav("build/embed_example.wav")
  echo "ok: ядро встроено, граф отрендерен, файл проверен"

main()

