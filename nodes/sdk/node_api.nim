# nodes/sdk/node_api.nim
#
# Контракты для авторов нод. Стабильнее самих нод (MANIFEST §57).
#
# Что здесь и почему:
#
#   NodeDesc — ОПИСАТЕЛЬ ноды: id, имя, порты, параметры, задержка.
#              Читается только холодной стороной (CLI/Editor/загрузчик
#              проекта). Никогда не попадает в audio thread.
#
#   NodeState — СОСТОЯНИЕ ноды: только DSP-переменные, POD, без строк,
#              таблиц и владения памятью. Именно его получает process().
#
# Жёсткое правило (MANIFEST §47): descriptor и state — разные объекты.
# Никаких `object` со string внутри state: строки в audio thread означают
# аллокации, а аллокации в audio thread — xrun.
#
# Версионирование: NodeApiVersion. Версия формата проекта, Node API,
# plugin ABI и версия ядра НЕ смешиваются (MANIFEST §58).

import
  node_interface,
  graph_compiler

const
  NodeApiVersion* = 1'u32

  NodeMaxIdChars*    = 32
  NodeMaxNameChars*  = 32
  NodeMaxParamChars* = 24
  NodeMaxParams*     = 16

# -----------------------------------------------------------------------------
# Параметры
# -----------------------------------------------------------------------------

type
  NodeParamFlag* = enum
    ## Флаги параметра — БИТОВАЯ МАСКА, а не порядковые номера.
    ##
    ## `flags` в описателе — это `uint32` с установленными битами, и весь код
    ## проверяет их через `(flags and uint32(flag)) != 0`. Если объявить
    ## значения порядковыми (1,2,3,4,5), проверка «и» читает ЧУЖИЕ биты:
    ## пара `automatable|modulatable` = 0|1 = 1 ложно срабатывала как
    ## `modulatable|choice`, из-за чего `param set` считал дробные параметры
    ## «целочисленными» и отвергал любое значение с точкой. Явные степени
    ## двойки делают запись и проверку согласованными.
    npfAutomatable = 1     # 0b00001 — можно вести автоматизацией
    npfModulatable = 2     # 0b00010 — принимает модуляцию (LFO, MIDI CC)
    npfInteger     = 4     # 0b00100 — целочисленный (шаг >= 1)
    npfChoice      = 8     # 0b01000 — дискретный набор значений
    npfHidden      = 16    # 0b10000 — не показывать в UI

const
  NodeParamFlagOrder* = [npfAutomatable, npfModulatable, npfInteger,
                         npfChoice, npfHidden]
    ## Порядок флагов для показа и разбора. Отдельный список нужен потому,
    ## что enum с явными значениями-битами («дырки») в Nim не итерируется.

type
  NodeParamDesc* {.bycopy.} = object
    id*: uint32
    name*: array[NodeMaxParamChars, char]
    flags*: uint32
    minValue*: float32
    maxValue*: float32
    defaultValue*: float32
    ## Для npfChoice — шаг перебора значений, иначе минимальный шаг
    ## пользователя при автоматизации.
    step*: float32

# -----------------------------------------------------------------------------
# Descriptor
# -----------------------------------------------------------------------------

type
  NodeDesc* {.bycopy.} = object
    structSize*: uint32
    apiVersion*: uint32

    id*: array[NodeMaxIdChars, char]
    name*: array[NodeMaxNameChars, char]
    category*: array[NodeMaxNameChars, char]

    audioInCount*: int32
    audioOutCount*: int32
    ctrlInCount*: int32
    ctrlOutCount*: int32
    eventInCount*: int32
    eventOutCount*: int32

    ## Внутренняя задержка ноды в кадрах. Компенсируется на уровне
    ## графа (processDelayComp в graph_compiler), поэтому сама нода
    ## не занимается выравниванием фаз с соседями.
    latencyFrames*: int32
    maxChannels*: int32

    params*: array[NodeMaxParams, NodeParamDesc]
    paramCount*: int32

# -----------------------------------------------------------------------------
# Фабрика
#
# Все procs — cdecl + raises: [], gcsafe: это часть ABI и одновременно
# проверка компилятором: нода не сможет бросить исключение в audio thread,
# потому что такая подпись просто не скомпилируется.
# -----------------------------------------------------------------------------

type
  NodeCreateProc* = proc(desc: ptr NodeDesc; userData: pointer): pointer
      {.cdecl, raises: [], gcsafe.}

  NodeDestroyProc* = proc(state: pointer) {.cdecl, raises: [], gcsafe.}

  ## Сигнатура совпадает с core/node_interface.ProcessProc намеренно:
  ## нода подставляется в PipelineStep без единой обёртки и без
  ## дополнительной аллокации на горячей стороне.
  NodeProcessProc* = proc(
    ctx: ptr NodeProcessContext;
    audio: ptr NodeAudioPorts;
    ctrl: ptr NodeControlPorts;
    events: ptr NodeEventPorts;
    userData: pointer
  ) {.cdecl, raises: [], gcsafe.}

  NodeSetParamProc* = proc(state: pointer; paramId: uint32;
                           value: float32; normalized: bool)
      {.cdecl, raises: [], gcsafe.}

  NodeGetParamProc* = proc(state: pointer; paramId: uint32;
                           outValue: ptr float32): bool
      {.cdecl, raises: [], gcsafe.}

  NodeResetProc* = proc(state: pointer) {.cdecl, raises: [], gcsafe.}

  ## Фабрика типа ноды. Указатель на неё статичен: столько же,
  ## сколько живёт сам тип ноды в реестре.
  NodeFactory* {.bycopy.} = object
    create*: NodeCreateProc
    destroy*: NodeDestroyProc
    process*: NodeProcessProc
    setParam*: NodeSetParamProc
    getParam*: NodeGetParamProc
    reset*: NodeResetProc

# ==============================================================================
# Работа с фиксированными строками descriptor'а
#
# Внутри descriptor'ов строки — фиксированные массивы char, а не string:
# descriptor копируется в проект и обратно, а string внутри POD означал бы
# скрытое владение памятью и нестабильный ABI.
# ==============================================================================

proc setFixed*[N: static[int]](dst: var array[N, char]; src: string) =
  ## Записывает строку в фиксированный буфер.
  ## Обрезание идёт по границе символа, чтобы не порвать многобайтовый UTF-8.
  var i = 0
  while i < N - 1 and i < src.len:
    dst[i] = src[i]
    inc i
  # откатываемся назад, если последний записанный байт — продолжение
  # многобайтовой последовательности (старший байт UTF-8: 11xxxxxx)
  while i > 0 and (ord(dst[i - 1]) and 0xC0) == 0x80:
    dec i
  dst[i] = '\0'

proc readFixed*[N: static[int]](src: array[N, char]): string =
  var i = 0
  while i < N and src[i] != '\0':
    inc i
  result = newString(i)
  if i > 0:
    copyMem(addr result[0], unsafeAddr src[0], i)

# Готовые конструкторы для полей descriptor'а: фиксированный буфер
# нужной длины заполняется прямо в месте использования.
proc fixedId*(s: string): array[NodeMaxIdChars, char] =
  setFixed(result, s)

proc fixedName*(s: string): array[NodeMaxNameChars, char] =
  setFixed(result, s)

proc fixedParamName*(s: string): array[NodeMaxParamChars, char] =
  setFixed(result, s)

template nodeIdOf*(d: NodeDesc): string = readFixed(d.id)
template nodeNameOf*(d: NodeDesc): string = readFixed(d.name)
template nodeCategoryOf*(d: NodeDesc): string = readFixed(d.category)

proc findParam*(d: NodeDesc; paramId: uint32): int {.inline.} =
  ## Индекс параметра или -1. Ищется только на холодной стороне.
  for i in 0 ..< int(d.paramCount):
    if d.params[i].id == paramId:
      return i
  return -1

proc paramRange*(d: NodeDesc; paramId: uint32): tuple[lo, hi: float32] {.inline.} =
  let idx = findParam(d, paramId)
  if idx < 0:
    return (-1.0f, 1.0f)
  (d.params[idx].minValue, d.params[idx].maxValue)

proc clampParam*(d: NodeDesc; paramId: uint32; value: float32): float32 {.inline.} =
  let idx = findParam(d, paramId)
  if idx < 0:
    return value
  let p = addr d.params[idx]
  clamp(value, p.minValue, p.maxValue)

proc paramToNormalized*(d: NodeDesc; paramId: uint32; value: float32): float32 {.inline.} =
  ## [min..max] -> [0..1]. Нужно UI, автоматизации и параметрам CLAP.
  let idx = findParam(d, paramId)
  if idx < 0:
    return 0.0f
  let p = addr d.params[idx]
  let span = p.maxValue - p.minValue
  if span <= 0.0f:
    return 0.0f
  clamp((value - p.minValue) / span, 0.0f, 1.0f)

proc paramFromNormalized*(d: NodeDesc; paramId: uint32; n: float32): float32 {.inline.} =
  ## [0..1] -> [min..max]
  let idx = findParam(d, paramId)
  if idx < 0:
    return 0.0f
  let p = addr d.params[idx]
  let span = p.maxValue - p.minValue
  p.minValue + clamp(n, 0.0f, 1.0f) * span

# ==============================================================================
# Инстанцирование
# ==============================================================================

proc makeEditorNode*(desc: ptr NodeDesc; factory: ptr NodeFactory;
                     nodeId: int; state: pointer): EditorNode {.inline.} =
  ## Собирает редакторное описание ноды из descriptor'а и состояния.
  ##
  ## Никаких обёрток и дополнительных аллокаций: processProc ноды
  ## подставляется в PipelineStep как есть, userData — указатель
  ## на состояние. Владение состоянием остаётся у вызывающего.
  EditorNode(
    id: nodeId,
    name: readFixed(desc.name),
    nodeType: readFixed(desc.id),
    processProc: factory.process,
    userData: state,
    audioInCount: desc.audioInCount,
    audioOutCount: desc.audioOutCount,
    ctrlInCount: desc.ctrlInCount,
    ctrlOutCount: desc.ctrlOutCount,
    eventInCount: desc.eventInCount,
    eventOutCount: desc.eventOutCount,
    latency: LatencyProfile(
      reported: uint32(max(0, int(desc.latencyFrames)))
    )
  )

