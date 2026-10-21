# libs/diff.nim
#
# Сравнение проектов и рендеров (issues #337, #338, линия v0.3.8).
#
# Зачем отдельная библиотека:
#   «что изменилось» — это вопрос, на который человек отвечает глазами, а
#   машина (CI, агент, сценарий) ответить не может: проект — JSON с
#   произвольным порядком ключей, рендер — WAV, где «почти то же» нужно уметь
#   объяснить числом. Здесь оба ответа получаются данными: список различий с
#   АДРЕСОМ сущности, а не с индексом массива.
#
# Границы (§20, §27):
#   ЗДЕСЬ — модель различия (`DiffItem`), структурное сравнение двух
#   документов проекта по каноническому JSON формата, измерение рендера
#   (метрики и сэмплы) и сравнение измерений.
#   НЕ ЗДЕСЬ — разбор argv, печать, коды возврата и выбор файлов: это дело
#   клиента. Библиотека не пишет на диск и ничего не мутирует.
#
# Почему сравнение идёт по `toJson(ProjectFormat)`, а не по сырым файлам:
#   * канонический JSON формата уже сортирует ключи параметров (#390), поэтому
#     перестановка ключей не считается различием по построению, а не по
#     договорённости;
#   * неизвестные поля, которые ядро не читает, не становятся «различием»:
#     сравнивается ДОКУМЕНТ, а не текст файла;
#   * адрес сущности берётся из её `id` (устойчивый идентификатор, §35), а не
#     из позиции в массиве: вставили ноду в начало — адреса остальных не
#     сдвинулись.
#
# Адреса (продолжение #143, но без handle-таблицы):
#   `node:2`                        — нода целиком;
#   `node:2.parameters.freq`        — параметр ноды;
#   `connection:1.a0->2.a0`         — связь (a = audio, c = control, e = event);
#   `track:1/clip:2.startTick`      — поле клипа внутри дорожки;
#   `track:1/clip:2/note:480:60:0`  — нота в клипе;
#   `lane:2:11/point:0.value`       — точка автоматизации;
#   `pluginState:2.state`           — состояние плагина;
#   `resource:3.path`               — аудиоресурс.
#   Handle-таблица (#143) для сравнения не годится: у двух файлов разные
#   документы (`docId`), а поколения слотов живут в сессии, а не в файле.

import std/[algorithm, json, math, sha1, strutils, tables]

import project
import audio_file_io
import spectrum

const
  DiffFormatName* = "euterpia.diff"
    ## Имя формата машинного отчёта: тот же принцип, что у сценария
    ## (`euterpia.script`) — тип отчёта узнаётся по содержимому.
  DiffFormatVersion* = 1
    ## Версия формы отчёта. Поднимается только при несовместимом изменении
    ## полей `projectDiffJson`/`renderDiffJson`.
  SampleTolerance* = 1e-6
    ## Абсолютный допуск сравнения сэмплов. Рендер офлайн-детерминирован,
    ## поэтому допуск нужен только на округление при записи WAV, а не «на
    ## глаз»: 1e-6 меньше шага 24-битного квантования.
  MetricTolerance* = 1e-6
    ## Допуск сравнения метрик (пик, RMS, доли полос).
  SpectralFftSize* = 2048
    ## Кадр БПФ для спектральной сводки. Фиксирован: два файла разной длины
    ## обязаны сравниваться с одинаковым разрешением по частоте.
  SpectralWindows* = 128
    ## Сколько кадров усредняется. Потолок нужен, чтобы сравнение
    ## многочасового микса не превращалось в анализ «на весь файл».
  BandLowHz* = 250.0
  BandHighHz* = 4000.0
    ## Границы трёх полос сводки: низ / середина / верх. Не «музыкальные»
    ## диапазоны, а грубая, но устойчивая подпись спектра.

type
  DiffKind* = enum
    dkAdded = "added"
    dkRemoved = "removed"
    dkChanged = "changed"

  DiffItem* = object
    ## Одно различие. `address` — адрес сущности (#143, см. шапку модуля),
    ## `field` — имя поля внутри сущности (пусто, если различие — вся
    ## сущность: добавили ноду целиком).
    section*: string
      ## Раздел документа: `format`, `metadata`, `graph`, `sequencer`,
      ## `pluginStates`, `resources` или `render`.
    address*: string
    kind*: DiffKind
    field*: string
    label*: string
      ## Что это за сущность словами («нода euterpia.osc «osc»»). Нужен
      ## человеческому отчёту; машине достаточно `address`.
    before*, after*: string
      ## Значения словами. Строки — без кавычек, объекты и массивы — их
      ## компактным JSON: отчёт должен быть читаемым и детерминированным.

  ProjectDiff* = object
    identical*: bool
    items*: seq[DiffItem]

  BandEnergy* = object
    ## Доли энергии трёх полос; сумма близка к 1 (тишина — все нули).
    low*, mid*, high*: float

  RenderMetrics* = object
    ## Измерения готового файла. Всё, что можно сравнить числом, считается
    ## один раз при чтении: сравнение не должно зависеть от того, сколько
    ## раз файл прочитали.
    path*: string
    frames*: int
    channels*: int
    sampleRate*: int
    bits*: int
    peak*, rms*, dc*: float
      ## Пик, RMS и постоянная составляющая по всем каналам.
    centroidHz*: float
      ## Спектральный центроид: «яркость» микса одним числом.
    bands*: BandEnergy
    fileSha1*, samplesSha1*: string
      ## SHA-1 байтов файла и декодированных сэмплов (по десятичному тексту,
      ## как в эталоне сценария #335: не зависит от порядка байтов платформы).

  RenderDiff* = object
    ## Результат сравнения двух рендеров. `ok == false` — файл не прочитан;
    ## это не «различие», а отказ, и клиент обязан вернуть код среды.
    ok*: bool
    error*: string
    a*, b*: RenderMetrics
    identical*: bool
    items*: seq[DiffItem]
    differingSamples*: int
    totalSamples*: int
    maxDelta*: float
    firstSample*: int
      ## Индекс первого расходящегося сэмпла в interleaved-потоке; -1 — нет.
    firstFrame*: int
      ## Кадр первого расхождения; -1 — нет.

# =============================================================================
# Значения и адреса
# =============================================================================

proc valueText*(node: JsonNode): string =
  ## Значение различия словами. `nil` — «поля не было» (пустая строка, чтобы
  ## отчёт не путал отсутствие с пустым значением — это разные вещи, и JSON
  ## отличает их через `null`).
  if node == nil:
    return ""
  case node.kind
  of JString: node.str
  of JInt: $node.num
  of JFloat: $node.fnum
  of JBool: (if node.bval: "true" else: "false")
  of JNull: "null"
  else: $node

proc intField(node: JsonNode; key: string): int64 =
  ## Целое поле элемента массива; отсутствующее — 0. Формат проекта уже
  ## проверен ядром при чтении, поэтому здесь не валидатор, а извлечение
  ## идентификатора для адреса.
  if node == nil or node.kind != JObject:
    return 0
  let value = node{key}
  if value == nil:
    return 0
  case value.kind
  of JInt: value.num
  of JFloat: int64(value.fnum)
  else: 0

proc strField(node: JsonNode; key: string): string =
  if node == nil or node.kind != JObject:
    return ""
  let value = node{key}
  if value != nil and value.kind == JString: value.str else: ""

proc sigLetter(sigType: int64): string =
  ## Вид сигнала в адресе связи: одна буква вместо числа — адрес читается
  ## человеком, а не только машиной.
  case sigType
  of 0: "a"
  of 1: "c"
  of 2: "e"
  else: "?" & $sigType

proc connectionText(element: JsonNode): string =
  ## `1.a0->2.a0`: источник (нода, вид, порт) → приёмник (то же).
  let kind = sigLetter(intField(element, "sigType"))
  $intField(element, "srcNodeId") & "." & kind & $intField(element, "srcPortIdx") &
    "->" & $intField(element, "dstNodeId") & "." & kind &
    $intField(element, "dstPortIdx")

type
  ArrayFamily = object
    ## Как опознаётся элемент массива. Пустое `name` — у массива нет
    ## устойчивого идентификатора, элементы сравниваются по позиции.
    name: string
    keys: seq[string]
      ## Поля, составляющие идентификатор. При сравнении совпавшего элемента
      ## они пропускаются: различие в них означало бы «другая сущность».

proc familyOf(arrayName: string): ArrayFamily =
  ## Семейство по имени массива. Имена взяты из формата проекта
  ## (`core/project.nim`), а не придуманы: новое поле формата попадает сюда
  ## в момент появления, иначе оно сравнивается по позиции — честно, но
  ## менее точно.
  case arrayName
  of "nodes": ArrayFamily(name: "node", keys: @["id"])
  of "connections", "subgraphConnections":
    ArrayFamily(name: "connection",
                keys: @["srcNodeId", "srcPortIdx", "dstNodeId", "dstPortIdx",
                        "sigType"])
  of "subgraphInputs", "subgraphOutputs":
    ArrayFamily(name: "port", keys: @["name", "localNodeId", "localPortIdx"])
  of "tracks": ArrayFamily(name: "track", keys: @["id"])
  of "clips": ArrayFamily(name: "clip", keys: @["id"])
  of "notes": ArrayFamily(name: "note", keys: @["startTick", "pitch", "channel"])
  of "automationLanes":
    ArrayFamily(name: "lane", keys: @["nodeId", "paramId"])
  of "points": ArrayFamily(name: "point", keys: @["tick"])
  of "pluginStates": ArrayFamily(name: "pluginState", keys: @["nodeId"])
  of "resources": ArrayFamily(name: "resource", keys: @["id"])
  else: ArrayFamily(name: "", keys: @[])

proc identityText(family: string; element: JsonNode): string =
  ## Адрес элемента массива. Пусто — элемент не опознан (у семейства нет
  ## идентификатора), тогда вызывающий сравнивает по позиции.
  case family
  of "node": "node:" & $intField(element, "id")
  of "connection": "connection:" & connectionText(element)
  of "port":
    "port:" & strField(element, "name") & "@" &
      $intField(element, "localNodeId") & ":" & $intField(element, "localPortIdx")
  of "track": "track:" & $intField(element, "id")
  of "clip": "clip:" & $intField(element, "id")
  of "note":
    "note:" & $intField(element, "startTick") & ":" &
      $intField(element, "pitch") & ":" & $intField(element, "channel")
  of "lane": "lane:" & $intField(element, "nodeId") & ":" &
              $intField(element, "paramId")
  of "point": "point:" & $intField(element, "tick")
  of "pluginState": "pluginState:" & $intField(element, "nodeId")
  of "resource": "resource:" & $intField(element, "id")
  else: ""

proc elementLabel(family: string; element: JsonNode): string =
  ## Сущность словами — для человеческого отчёта. Машина читает `address` и
  ## `field`; подпись существует, чтобы строка «добавлено» не была пустой.
  case family
  of "node":
    "нода " & strField(element, "nodeType") &
      (if strField(element, "name").len > 0: " «" & strField(element, "name") & "»"
       else: "")
  of "connection": "связь " & connectionText(element)
  of "port": "порт «" & strField(element, "name") & "»"
  of "track":
    "дорожка" & (if strField(element, "name").len > 0:
                   " «" & strField(element, "name") & "»" else: "")
  of "clip":
    "клип" & (if strField(element, "name").len > 0:
                " «" & strField(element, "name") & "»" else: "")
  of "note":
    "нота " & $intField(element, "pitch") & " с тика " &
      $intField(element, "startTick")
  of "lane":
    "линия автоматизации ноды " & $intField(element, "nodeId") &
      " (параметр " & $intField(element, "paramId") & ")"
  of "point": "точка автоматизации на тике " & $intField(element, "tick")
  of "pluginState":
    "состояние плагина «" & strField(element, "pluginId") & "» ноды " &
      $intField(element, "nodeId")
  of "resource": "аудиоресурс «" & strField(element, "path") & "»"
  else: ""

proc lastSegment(path: string): string =
  ## Имя поля или массива в JSON-пути (`graph.nodes` → `nodes`,
  ## `graph.nodes[]` → `nodes`).
  var text = path
  if text.endsWith("[]"):
    text.setLen(text.len - 2)
  let at = text.rfind('.')
  if at < 0: text else: text[at + 1 .. ^1]

proc fieldAddress(parent, field: string): string =
  if parent.len == 0: field else: parent & "." & field

proc childAddress(parent, child: string): string =
  if parent.len == 0: child else: parent & "/" & child


# =============================================================================
# Сравнение документов проекта
# =============================================================================

proc addItem(items: var seq[DiffItem]; section, address: string;
             kind: DiffKind; field, label: string;
             before, after: JsonNode) =
  items.add DiffItem(section: section, address: address, kind: kind,
                     field: field, label: label,
                     before: valueText(before), after: valueText(after))

proc sameValue(a, b: JsonNode): bool =
  ## Скалярное равенство. Числа сравниваются точно: ключи параметров ядро
  ## пишет из `float32`, и round-trip не меняет значение.
  if a == nil or b == nil:
    return a == b
  if a.kind != b.kind:
    # `1` и `1.0` — одно и то же число в формате проекта: ядро пишет
    # `sampleRate` как float, а руками его часто пишут целым.
    if a.kind in {JInt, JFloat} and b.kind in {JInt, JFloat}:
      return a.getFloat == b.getFloat
    return false
  case a.kind
  of JString: a.str == b.str
  of JInt: a.num == b.num
  of JFloat: a.fnum == b.fnum
  of JBool: a.bval == b.bval
  of JNull: true
  else: false

proc isScalarArray(node: JsonNode): bool =
  ## Массив скаляров (например, байты состояния плагина). Такие массивы
  ## сравниваются ЦЕЛИКОМ: различие в каждом байте — это не список
  ## различий, а один изменённый блоб.
  if node == nil or node.kind != JArray:
    return false
  for element in node:
    if element.kind in {JObject, JArray}:
      return false
  true

proc arrayText(node: JsonNode): string =
  ## Массив скаляров словами. Длинный блоб не вываливается в отчёт целиком:
  ## первые значения плюс число элементов — этого достаточно, чтобы понять
  ## «состояние изменилось», не читая килобайты.
  const Limit = 120
  let text = $node
  if text.len <= Limit:
    return text
  text[0 ..< Limit] & " … (" & $node.len & " элементов)"

proc walk(a, b: JsonNode; path, address, section: string;
          skip: openArray[string]; items: var seq[DiffItem]) =
  ## Рекурсивное сравнение двух узлов JSON. Один вызов на пару «значение A,
  ## значение B»; добавленная и удалённая ветка дают ОДНО различие на
  ## сущность, а не поток различий по каждому полю.
  if a == nil and b == nil:
    return
  if a == nil or b == nil:
    let family = familyOf(lastSegment(path))
    items.addItem(section, address, (if a == nil: dkAdded else: dkRemoved),
                  field = "", label = elementLabel(family.name,
                    (if a == nil: b else: a)),
                  before = a, after = b)
    return
  if a.kind != b.kind:
    items.addItem(section, address, dkChanged, field = lastSegment(path),
                  label = "", before = a, after = b)
    return

  case a.kind
  of JObject:
    var keys: seq[string] = @[]
    for key, _ in a:
      if key notin skip and key notin keys: keys.add key
    for key, _ in b:
      if key notin skip and key notin keys: keys.add key
    keys.sort()
    for key in keys:
      # Массив с устойчивыми идентификаторами адресуется СВОИМИ элементами
      # (`node:2`), поэтому имя массива в адрес не попадает: `graph.nodes`
      # только указывает, что это ноды. Массив без идентификаторов
      # (позиционный) остаётся в адресе как поле — иначе адрес `[0]` не
      # говорил бы, чего это индекс.
      let va = a{key}
      let vb = b{key}
      let identityArray =
        (va != nil and va.kind == JArray and familyOf(key).name.len > 0) or
        (vb != nil and vb.kind == JArray and familyOf(key).name.len > 0)
      walk(va, vb, path & "." & key,
           (if identityArray: address else: fieldAddress(address, key)),
           section, [], items)
  of JArray:
    if a.isScalarArray and b.isScalarArray:
      # Блоб (байты состояния плагина) — одна величина: сравнивать его
      # поэлементно значило бы печатать по различию на байт.
      if $a != $b:
        items.add DiffItem(section: section, address: address, kind: dkChanged,
                           field: lastSegment(path), label: "",
                           before: arrayText(a), after: arrayText(b))
      return
    let arrayName = lastSegment(path)
    let family = familyOf(arrayName)
    if family.name.len > 0:
      # Группировка по идентификатору с сохранением порядка: одинаковые
      # идентификаторы (две ноты с одним тиком, высотой и каналом) не
      # склеиваются в одну сущность, а сравниваются по очереди.
      var groupA = initTable[string, seq[JsonNode]]()
      var groupB = initTable[string, seq[JsonNode]]()
      var order: seq[string] = @[]
      for element in a:
        let id = identityText(family.name, element)
        if id notin groupA: order.add id
        groupA.mgetOrPut(id, @[]).add element
      for element in b:
        let id = identityText(family.name, element)
        if id notin order: order.add id
        groupB.mgetOrPut(id, @[]).add element
      order.sort()
      for id in order:
        let listA = groupA.getOrDefault(id, @[])
        let listB = groupB.getOrDefault(id, @[])
        for index in 0 ..< max(listA.len, listB.len):
          let va = if index < listA.len: listA[index] else: nil
          let vb = if index < listB.len: listB[index] else: nil
          walk(va, vb, path & "[]", childAddress(address, id), section,
               family.keys, items)
    else:
      for index in 0 ..< max(a.len, b.len):
        let va = if index < a.len: a[index] else: nil
        let vb = if index < b.len: b[index] else: nil
        walk(va, vb, path & "[]", address & "[" & $index & "]", section, [],
             items)
  else:
    if not sameValue(a, b):
      items.addItem(section, address, dkChanged, field = lastSegment(path),
                    label = "", before = a, after = b)

proc rootSection(key: string): string =
  ## Раздел верхнего уровня. `format`/`version` — подпись документа: «другой
  ## формат» это не «изменённая нода», но и не молчание.
  case key
  of "format", "version": "format"
  else: key

const StructuralSections = ["graph", "sequencer"]
  ## Контейнеры сущностей. В адрес они не попадают: адрес ноды — `node:2`, а
  ## не `graph/node:2`. Раздел при этом не теряется — он лежит в `section`
  ## каждого различия, так что машине видно, откуда пришло изменение.

proc diffProjectJson*(a, b: JsonNode): ProjectDiff =
  ## Сравнение двух документов проекта, уже разобранных в JSON. Ключи
  ## перебираются по алфавиту, поэтому порядок в файле на результат не влияет.
  var items: seq[DiffItem] = @[]
  if a != nil and b != nil and a.kind == JObject and b.kind == JObject:
    var keys: seq[string] = @[]
    for key, _ in a:
      if key notin keys: keys.add key
    for key, _ in b:
      if key notin keys: keys.add key
    keys.sort()
    for key in keys:
      let va = a{key}
      let vb = b{key}
      # Адрес верхнего уровня — имя раздела (`metadata.tempo`), кроме
      # массивов с идентификаторами: их раздел адресуется элементами
      # (`node:2`, `resource:3`), и общий префикс `resources/` был бы шумом.
      let identityArray =
        (va != nil and va.kind == JArray and familyOf(key).name.len > 0) or
        (vb != nil and vb.kind == JArray and familyOf(key).name.len > 0)
      walk(va, vb, key,
           (if identityArray or key in StructuralSections: "" else: key),
           rootSection(key), [], items)
  elif a != nil or b != nil:
    walk(a, b, "", "", "", [], items)
  result = ProjectDiff(identical: items.len == 0, items: items)

proc diffProjects*(a, b: ProjectFormat): ProjectDiff =
  ## Сравнение двух проектов по КАНОНИЧЕСКОМУ JSON формата: перестановка
  ## ключей и параметров не является различием по построению (#390).
  diffProjectJson(toJson(a), toJson(b))


# =============================================================================
# Измерение рендера
# =============================================================================

proc sha1Text(data: string): string =
  ## SHA-1 в том же виде, что у эталона сценария (#335): верхний регистр.
  ## Формат совпадает с `sha1OfText` из `libs/script` без общей зависимости.
  $secureHash(data)

proc sha1FileBytes(path: string): string =
  try:
    sha1Text(readFile(path))
  except CatchableError:
    ""

proc addSpectralSummary(samples: openArray[float32]; channels, sampleRate: int;
                        metrics: var RenderMetrics) =
  ## Спектральная сводка: центроид и доли трёх полос. Считается по
  ## фиксированному кадру (`SpectralFftSize`) на равномерно выбранных окнах,
  ## поэтому два файла разной длины сравнимы, а стоимость ограничена.
  if channels <= 0 or sampleRate <= 0 or samples.len == 0:
    return
  let frames = samples.len div channels
  if frames <= 0:
    return

  var window = newSeq[float32](SpectralFftSize)
  var mag: seq[float32] = @[]
  var power = newSeq[float64](SpectralFftSize div 2 + 1)
  let step = max(1, frames div SpectralWindows)
  var used = 0
  var frame = 0
  while frame < frames and used < SpectralWindows:
    for i in 0 ..< SpectralFftSize:
      let source = frame + i
      if source < frames:
        var sum = 0.0
        for ch in 0 ..< channels:
          sum += float64(samples[source * channels + ch])
        window[i] = float32(sum / float64(channels) *
                            float64(hannWindow(i, SpectralFftSize)))
      else:
        window[i] = 0.0f
    magnitudeSpectrum(window, mag)
    for bin in 0 ..< min(power.len, mag.len):
      power[bin] += float64(mag[bin]) * float64(mag[bin])
    inc used
    frame += step

  var totalPower = 0.0
  for value in power:
    totalPower += value
  if totalPower <= 0.0:
    return

  let width = float64(hzPerBin(float32(sampleRate), SpectralFftSize))
  var weighted = 0.0
  var low = 0.0
  var mid = 0.0
  var high = 0.0
  for bin in 0 ..< power.len:
    let hz = float64(bin) * width
    weighted += hz * power[bin]
    if hz < BandLowHz:
      low += power[bin]
    elif hz <= BandHighHz:
      mid += power[bin]
    else:
      high += power[bin]
  metrics.centroidHz = weighted / totalPower
  metrics.bands = BandEnergy(low: low / totalPower, mid: mid / totalPower,
                             high: high / totalPower)

proc measureRender*(path: string):
    tuple[ok: bool; metrics: RenderMetrics; error: string] =
  ## Измерения файла: размеры, пик, RMS, DC, спектральная сводка, SHA-1.
  ## Пустой `error` — измерение удалось. Исключения кодека не выходят
  ## наружу: вызывающий должен получить отказ, а не падение CLI.
  var metrics = RenderMetrics(path: path)
  var samples: seq[float32] = @[]
  var info: AudioFileInfo
  try:
    let loaded = readAllAudioFile(path)
    samples = loaded.samples
    info = loaded.info
  except CatchableError as exc:
    return (false, metrics, "не удалось прочитать файл: " & exc.msg)

  metrics.frames = int(info.numFrames)
  metrics.channels = int(info.channels)
  metrics.sampleRate = int(info.sampleRate)
  metrics.bits = int(info.bitsPerSample)
  metrics.fileSha1 = sha1FileBytes(path)

  var peak = 0.0
  var sumSquares = 0.0
  var sum = 0.0
  var digest = ""
  for sample in samples:
    let value = float64(sample)
    let magnitude = abs(value)
    if magnitude > peak:
      peak = magnitude
    sum += value
    sumSquares += value * value
    # Сумма сэмплов — по десятичному тексту, а не по сырым байтам: так она
    # не зависит от порядка байтов платформы (как в эталоне #335).
    digest.add(formatFloat(value, ffDecimal, 7))
    digest.add(',')
  metrics.peak = peak
  metrics.rms = (if samples.len > 0: sqrt(sumSquares / float64(samples.len))
                 else: 0.0)
  metrics.dc = (if samples.len > 0: sum / float64(samples.len) else: 0.0)
  metrics.samplesSha1 = sha1Text(digest)
  addSpectralSummary(samples, metrics.channels, metrics.sampleRate, metrics)

  (true, metrics, "")


# =============================================================================
# Сравнение рендеров
# =============================================================================

proc metricItem(name: string; before, after: float; tolerance: float;
                items: var seq[DiffItem]) =
  if abs(before - after) <= tolerance:
    return
  items.add DiffItem(section: "render", address: "render." & name,
                     kind: dkChanged, field: name, label: "",
                     before: $before, after: $after)

proc metricItem(name: string; before, after: int; items: var seq[DiffItem]) =
  ## Размеры файла — факт, а не допуск: разные кадры/каналы/частота значат,
  ## что сравнивать звук бессмысленно, и молчать об этом нельзя.
  if before == after:
    return
  items.add DiffItem(section: "render", address: "render." & name,
                     kind: dkChanged, field: name, label: "",
                     before: $before, after: $after)

proc diffMetrics*(a, b: RenderMetrics;
                  tolerance = MetricTolerance): seq[DiffItem] =
  ## Числовые различия измерений: размеры, пик, RMS, DC, спектральная сводка.
  var items: seq[DiffItem] = @[]
  metricItem("frames", a.frames, b.frames, items)
  metricItem("channels", a.channels, b.channels, items)
  metricItem("sampleRate", a.sampleRate, b.sampleRate, items)
  metricItem("bits", a.bits, b.bits, items)
  metricItem("peak", a.peak, b.peak, tolerance, items)
  metricItem("rms", a.rms, b.rms, tolerance, items)
  metricItem("dc", a.dc, b.dc, tolerance, items)
  # Центроид — герцы, поэтому допуск в герцах: доля от допуска метрик была
  # бы «на глаз», а не единицей измерения.
  metricItem("centroidHz", a.centroidHz, b.centroidHz, 0.5, items)
  metricItem("band.low", a.bands.low, b.bands.low, tolerance, items)
  metricItem("band.mid", a.bands.mid, b.bands.mid, tolerance, items)
  metricItem("band.high", a.bands.high, b.bands.high, tolerance, items)
  items

proc readSamples(path: string; samples: var seq[float32];
                 channels: var int): string =
  ## Сэмплы для поштучного сравнения. Отдельное чтение, потому что
  ## `RenderMetrics` намеренно не носит за собой весь файл: сравнение метрик
  ## не должно требовать памяти под микс.
  try:
    let loaded = readAllAudioFile(path)
    samples = loaded.samples
    channels = int(loaded.info.channels)
    ""
  except CatchableError as exc:
    "не удалось прочитать файл: " & exc.msg


proc diffRenderFiles*(pathA, pathB: string;
                      tolerance = SampleTolerance): RenderDiff =
  ## Сравнение двух готовых рендеров: метрики числом и сэмплы поштучно.
  ## Отказ чтения — `ok == false`; различие звука — `ok == true` и непустой
  ## `items`, чтобы клиент сам решал, какой код возврата дать.
  result = RenderDiff(ok: false, firstSample: -1, firstFrame: -1)

  let measuredA = measureRender(pathA)
  if not measuredA.ok:
    result.error = pathA & ": " & measuredA.error
    return
  let measuredB = measureRender(pathB)
  if not measuredB.ok:
    result.error = pathB & ": " & measuredB.error
    return
  result.a = measuredA.metrics
  result.b = measuredB.metrics

  var samplesA: seq[float32] = @[]
  var samplesB: seq[float32] = @[]
  var channelsA = 0
  var channelsB = 0
  let readA = readSamples(pathA, samplesA, channelsA)
  if readA.len > 0:
    result.error = pathA & ": " & readA
    return
  let readB = readSamples(pathB, samplesB, channelsB)
  if readB.len > 0:
    result.error = pathB & ": " & readB
    return

  result.ok = true
  result.totalSamples = max(samplesA.len, samplesB.len)
  let common = min(samplesA.len, samplesB.len)
  var maxDelta = 0.0
  for index in 0 ..< common:
    let delta = abs(float64(samplesA[index]) - float64(samplesB[index]))
    if delta > tolerance:
      inc result.differingSamples
      if result.firstSample < 0:
        result.firstSample = index
    if delta > maxDelta:
      maxDelta = delta
  # Хвост более длинного файла — тоже расхождение: «файл кончился раньше»
  # это различие, а не отсутствие данных.
  result.differingSamples += abs(samplesA.len - samplesB.len)
  result.maxDelta = maxDelta
  if result.firstSample < 0 and samplesA.len != samplesB.len:
    result.firstSample = common

  if result.firstSample >= 0:
    let channels = max(1, max(channelsA, channelsB))
    result.firstFrame = result.firstSample div channels

  result.items = diffMetrics(result.a, result.b, MetricTolerance)

  if result.differingSamples > 0:
    result.items.add DiffItem(
      section: "render", address: "render.samples", kind: dkChanged,
      field: "samples", label: "сэмплы",
      before: "совпадает: " & $(result.totalSamples - result.differingSamples),
      after: "различий: " & $result.differingSamples)
  if result.a.fileSha1 != result.b.fileSha1:
    result.items.add DiffItem(
      section: "render", address: "render.file", kind: dkChanged,
      field: "file", label: "файл",
      before: result.a.fileSha1, after: result.b.fileSha1)

  result.identical = result.items.len == 0

# =============================================================================
# Машинный отчёт и человеческая строка
# =============================================================================

proc diffItemJson*(item: DiffItem): JsonNode =
  ## Одно различие как данные. Порядок полей фиксирован: повторный прогон
  ## даёт байт-в-байт тот же JSON (#88).
  result = newJObject()
  result["section"] = %item.section
  result["address"] = %item.address
  result["kind"] = %($item.kind)
  result["field"] = %item.field
  result["label"] = %item.label
  result["before"] = %item.before
  result["after"] = %item.after

proc diffItemsJson*(items: seq[DiffItem]): JsonNode =
  result = newJArray()
  for item in items:
    result.add diffItemJson(item)

proc diffLine*(item: DiffItem): string =
  ## Человеческая строка различия. Формат один для проектов и рендеров:
  ## адрес, что случилось, и значения «было → стало». Слова по-русски,
  ## потому что отчёт читает человек, а машина берёт `--json`.
  let what =
    case item.kind
    of dkAdded: "добавлено"
    of dkRemoved: "удалено"
    of dkChanged: "изменено"
  var line = item.address
  if item.field.len > 0:
    line.add " (" & item.field & ")"
  line.add ": " & what
  if item.label.len > 0:
    line.add " — " & item.label
  if item.kind == dkChanged:
    line.add ": «" & item.before & "» → «" & item.after & "»"
  line

proc diffLines*(items: seq[DiffItem]): seq[string] =
  ## Строки отчёта в порядке появления: он детерминирован (ключи и адреса
  ## сортируются), поэтому вывод сравним между запусками.
  for item in items:
    result.add diffLine(item)


proc projectDiffJson*(d: ProjectDiff): JsonNode =
  ## Машинный отчёт сравнения проектов. `count` дублирует `items.len` на
  ## верхнем уровне намеренно: агенту часто нужно только число.
  result = newJObject()
  result["format"] = %DiffFormatName
  result["version"] = %DiffFormatVersion
  result["identical"] = %d.identical
  result["count"] = %d.items.len
  result["items"] = diffItemsJson(d.items)

proc metricsJson*(m: RenderMetrics): JsonNode =
  ## Измерения файла как данные: по ним видно, ЧЕМ файлы различаются, а не
  ## только «разные».
  result = %*{
    "path": m.path,
    "frames": m.frames,
    "channels": m.channels,
    "sampleRate": m.sampleRate,
    "bits": m.bits,
    "peak": m.peak,
    "rms": m.rms,
    "dc": m.dc,
    "centroidHz": m.centroidHz,
    "bandLow": m.bands.low,
    "bandMid": m.bands.mid,
    "bandHigh": m.bands.high,
    "fileSha1": m.fileSha1,
    "samplesSha1": m.samplesSha1,
  }

proc renderDiffJson*(d: RenderDiff): JsonNode =
  ## Машинный отчёт сравнения рендеров. При отказе чтения `identical` —
  ## `false`, но причины разные: отказ назван полем `error`, а не «нет
  ## различий».
  result = newJObject()
  result["format"] = %DiffFormatName
  result["version"] = %DiffFormatVersion
  if not d.ok:
    result["identical"] = %false
    result["count"] = %0
    result["items"] = newJArray()
    result["error"] = %d.error
    return
  result["identical"] = %d.identical
  result["count"] = %d.items.len
  result["items"] = diffItemsJson(d.items)
  result["a"] = metricsJson(d.a)
  result["b"] = metricsJson(d.b)
  result["differingSamples"] = %d.differingSamples
  result["totalSamples"] = %d.totalSamples
  result["maxDelta"] = %d.maxDelta
  result["firstSample"] = %d.firstSample
  result["firstFrame"] = %d.firstFrame

