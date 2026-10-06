# examples/embed_lib.nim
#
# Ядро как БИБЛИОТЕКА: сборка static/dynamic и C-ABI-фасад (issue #213).
#
# Зачем отдельный файл: `embed_render.nim` показывает интеграцию на Nim, а
# чужой движок чаще всего написан на C/C++/Rust/Python — и связывается с
# ядром через C-ABI. Здесь этот ABI и объявлен: маленький, POD-only, без
# сборщика мусора на границе (§66: «ядро без GUI, контракты — POD»).
#
# СБОРКА (флаги — часть контракта встраивания, они же в docs/embedding.md):
#
#   # dynamic: libeuterpia_embed.so / .dylib / .dll
#   nim c --app:lib -d:release --hints:off \
#         --out:build/libeuterpia_embed.so examples/embed_lib.nim
#
#   # static: libeuterpia_embed.a (+ .h от --header; Nim кладёт его в nimcache)
#   nim c --app:staticLib -d:release --hints:off \
#         --nimcache:build/nc_embedstatic --header \
#         --out:build/libeuterpia_embed.a examples/embed_lib.nim
#
# Модульные пути (core/, nodes/, …) и флаги потоков/памяти приходят из
# config.nims репозитория — при сборке ИЗ КОРНЯ пакета ничего добавлять не
# нужно; при выносе файла в чужой проект добавьте `--path:<repo>/core`,
# `--path:<repo>/nodes` и `--threads:on`.
#
# Проверка ABI: `nimble embedLib` собирает .so и зовёт фасад из Python через
# ctypes (examples/host_ctypes.py) — то есть библиотека проверяется РЕАЛЬНОЙ
# загрузкой из чужого рантайма, а не только фактом «файл создан».

import std/[math, tables]

import euterpia_version
import signal_types
import graph_compiler
import compiled_pipeline
import audio_engine
import sdk/node_registry
import sdk/pipeline_builder
import builtin/builtin_registry

# ==============================================================================
# Реестр типов нод
#
# Регистрация типов — операция инициализации приложения, а не рантайма:
# делается один раз на процесс и до первого рендера. Типы статичны, поэтому
# указатели на записи реестра живут столько же, сколько библиотека.
# ==============================================================================

var
  gRegistry: NodeRegistry
  gRegistryReady = false

proc ensureRegistry(): bool =
  if gRegistryReady:
    return true
  gRegistry = initNodeRegistry()
  if registerBuiltinNodes(gRegistry) != BuiltinCount:
    return false
  gRegistryReady = true
  true

const
  HostNodeCount = 3

type
  # Полностью POD-структура: ни seq, ни ref. Её видит C-сторона как
  # непрозрачный handle, поэтому в ней не должно быть ничего, чем управляет
  # Nim-рантайм. Ноды — значения (`EditorNode`), состояния — сырые указатели,
  # которыми владеет хост и освобождает он же.
  EutHost = object
    engine: ptr AudioEngine
    nodes: array[HostNodeCount, EditorNode]
    entries: array[HostNodeCount, ptr NodeTypeEntry]
    blockFrames: int32
    live: bool

const HostNodeTypes = ["euterpia.osc", "euterpia.gain", "euterpia.mix"]

# Объявление вперёд: `eutHostCreate` убирает за собой сам при отказе, а тело
# `eutHostDestroy` удобнее держать в конце — рядом с остальным lifecycle.
proc eutHostDestroy(h: pointer) {.exportc, cdecl, dynlib.}

# ==============================================================================
# C-ABI фасад
#
# Правила, которым подчиняется каждая функция ниже:
#   * никаких исключений наружу — только коды возврата (Nim-исключение
#     сквозь C-границу = неопределённое поведение);
#   * никаких аллокаций в audio-пути: `eutHostRenderBlock` только пишет в
#     буфер вызывающего;
#   * NULL-указатель — валидный аргумент, а не повод упасть.
# ==============================================================================

proc eutHostVersion(): cstring {.exportc, cdecl, dynlib.} =
  ## Версия ядра строкой: единственный источник — `euterpia_version.nim`,
  ## тот же модуль, что печатает `euterpia --version`.
  EuterpiaVersion.cstring

proc eutHostCreate(sampleRate, blockSize: cint): pointer
    {.exportc, cdecl, dynlib.} =
  ## Создаёт движок и граф osc -> gain -> mix. nil — отказ.
  if not ensureRegistry():
    return nil

  let engine = createAudioEngine(float32(sampleRate), int32(blockSize))
  if engine.isNil:
    return nil

  let host = cast[ptr EutHost](allocShared0(sizeof(EutHost)))
  if host.isNil:
    destroyAudioEngine(engine)
    return nil

  host.engine = engine
  host.blockFrames = int32(blockSize)

  var graph: NodeGraph
  for i in 0 ..< HostNodeCount:
    host.entries[i] = gRegistry.findNodeType(HostNodeTypes[i])
    if host.entries[i].isNil or
       not instantiateNode(gRegistry, HostNodeTypes[i], i + 1, host.nodes[i]):
      eutHostDestroy(cast[pointer](host))
      return nil
    graph.nodes[i + 1] = host.nodes[i]

  graph.connections.add EditorConnection(
    srcNodeId: 1, srcPortIdx: 0, dstNodeId: 2, dstPortIdx: 0, sigType: sigAudio)
  graph.connections.add EditorConnection(
    srcNodeId: 2, srcPortIdx: 0, dstNodeId: 3, dstPortIdx: 0, sigType: sigAudio)

  var cr: CompileResult
  var binding: ptr PipelineBinding
  if not buildPipeline(gRegistry, graph, 3, cr, binding) or cr.pipeline.isNil:
    eutHostDestroy(cast[pointer](host))
    return nil

  # Пайплайн переходит движку: освободит его `destroyAudioEngine`.
  if not engine.postGraphUpdate(cr.pipeline):
    destroyPipeline(cr.pipeline)
    eutHostDestroy(cast[pointer](host))
    return nil

  host.live = true
  cast[pointer](host)

proc eutHostPlay(h: pointer): cint {.exportc, cdecl, dynlib.} =
  ## «Играть»: команда уходит в очередь и исполняется в audio-потоке.
  let host = cast[ptr EutHost](h)
  if host.isNil or not host.live or host.engine.isNil:
    return 0
  if host.engine.postPlay(): 1 else: 0

proc eutHostStop(h: pointer): cint {.exportc, cdecl, dynlib.} =
  let host = cast[ptr EutHost](h)
  if host.isNil or not host.live or host.engine.isNil:
    return 0
  if host.engine.postStop(): 1 else: 0

proc eutHostRenderBlock(h: pointer;
                        outBuf: ptr UncheckedArray[float32]): cfloat
    {.exportc, cdecl, dynlib.} =
  ## Один блок звука в буфер вызывающего (interleaved stereo,
  ## `blockFrames * 2` float32). Возврат — пик блока: хосту нужен признак,
  ## что граф не молчит, а Core уже посчитал пики для метрик.
  ##
  ## Это и есть audio callback на стороне хоста: без выделений памяти,
  ## без блокировок, без исключений.
  let host = cast[ptr EutHost](h)
  if host.isNil or not host.live or host.engine.isNil or outBuf.isNil:
    return 0.0f

  host.engine.renderBlock(outBuf)

  let count = int(host.blockFrames) * 2
  var peak = 0.0f
  for i in 0 ..< count:
    let a = abs(outBuf[i])
    if a > peak:
      peak = a
  peak

proc eutHostCurrentFrame(h: pointer): clonglong {.exportc, cdecl, dynlib.} =
  ## Позиция транспорта: control-поток читает снапшот, RT его обновляет.
  let host = cast[ptr EutHost](h)
  if host.isNil or host.engine.isNil:
    return 0
  host.engine.currentFrame()

proc eutHostXruns(h: pointer): cuint {.exportc, cdecl, dynlib.} =
  ## Счётчик xrun'ов: хост обязан показывать его пользователю, а не глотать.
  let host = cast[ptr EutHost](h)
  if host.isNil or host.engine.isNil:
    return 0
  host.engine.xrunCount()

proc eutHostDestroy(h: pointer) {.exportc, cdecl, dynlib.} =
  ## Порядок освобождения — часть контракта:
  ##   1. движок (он владеет пайплайном и освобождает его сам);
  ##   2. состояния нод (их создавал хост — `instantiateNode`);
  ##   3. сама структура хоста.
  ## Обратный порядок оставил бы шаги пайплайна с висячими указателями на
  ## состояния.
  let host = cast[ptr EutHost](h)
  if host.isNil:
    return

  host.live = false

  if not host.engine.isNil:
    destroyAudioEngine(host.engine)
    host.engine = nil

  for i in 0 ..< HostNodeCount:
    if not host.entries[i].isNil and not host.nodes[i].userData.isNil:
      destroyNodeState(host.entries[i], host.nodes[i].userData)
    host.nodes[i].userData = nil

  deallocShared(cast[pointer](host))

