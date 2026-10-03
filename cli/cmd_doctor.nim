# cli/cmd_doctor.nim
#
# `euterpia doctor` — самодиагностика окружения (issue #105).
#
# Как устроены проверки и почему именно так:
# - ядро/компилятор/платформа — из констант сборки, без запуска процессов;
# - аудио-бэкенды — через `backend_registry` и РЕАЛЬНО созданный адаптер
#   miniaudio: он линкуется в бинарник статически (внешней библиотеки нет),
#   поэтому проверка не может уронить CLI на машине без звука;
# - PortAudio и RtMidi в CLI НЕ линкуются, и это не лень, а требование
#   безопасности процесса: `{.dynlib.}` резолвит символы внешней библиотеки
#   в инициализации модуля, то есть ОТСУТСТВИЕ библиотеки роняет процесс ДО
#   `main()`, и обработать это нельзя (проверено: `import
#   adapters/rtmidi/midi_backend_rtmidi` без librtmidi печатает
#   "could not load: librtmidi.so" и выходит, не дойдя до первой строки
#   кода). Поэтому доступность их библиотек проверяется пробой `dlopen`
#   (std/dynlib, ловится `LibraryError`), а не импортом адаптера;
# - плагины — инвентаризация каталогов поиска (сколько `.clap` видно):
#   загрузка контракта — задача `plugin scan` (#95), doctor её не подменяет;
# - файловая система — реальная запись пробного файла (в `--dry-run`
#   проверка не выполняется, чтобы doctor ничего не создавал);
# - C-ядра — значение `EUT_HAS_SIMD_DISPATCH` берётся из самого заголовка
#   нод (`emit` + `#include`), а не дублируется константой Nim: иначе
#   doctor показывал бы не то, что реально собрано.
#
# Критерий кода возврата (#105): 0 — критичное на месте, 2 — критичное
# недоступно. «Критичное» — это звук (устройства) и права на запись;
# отсутствие MIDI/плагинов/SIMD — предупреждение, а не отказ.

import std/[json, os, strutils, dynlib]

import audio_backend_api
import backend_registry
import logger
import audio_backend_miniaudio

import context

# =============================================================================
# SIMD-дисплей C-ядер
# =============================================================================

{.passC: "-Inodes/builtin/csrc".}

{.emit: """
#include "eut_dsp.h"
int eut_cli_simd_dispatch(void) { return EUT_HAS_SIMD_DISPATCH; }
""".}

proc eutCliSimdDispatch(): cint {.importc: "eut_cli_simd_dispatch", nodecl.}

# =============================================================================
# Модель отчёта
# =============================================================================

const
  MaxDevicesReported = 8
    ## Сколько имён устройств печатать. Список — диагностика, а не UI.

  BuildKind =
    when defined(danger): "danger"
    elif defined(release): "release"
    else: "debug"

  MemoryManager =
    when defined(gcOrc): "orc"
    elif defined(gcArc): "arc"
    else: "refc"

type
  CheckStatus* = enum
    csOk, csWarn, csFail

  Check* = object
    id*: string
    title*: string
    status*: CheckStatus
    lines*: seq[string]
    advice*: string
    body*: JsonNode

  Section* = object
    id*: string
    title*: string
    checks*: seq[Check]

proc statusName*(s: CheckStatus): string =
  case s
  of csOk: "ok"
  of csWarn: "warn"
  of csFail: "fail"

proc worst*(a, b: CheckStatus): CheckStatus =
  if ord(a) >= ord(b): a else: b

proc sectionStatus*(s: Section): CheckStatus =
  result = csOk
  for c in s.checks:
    result = worst(result, c.status)

proc mkCheck(
  id, title: string;
  status: CheckStatus;
  lines: seq[string] = @[];
  advice: string = "";
  body: JsonNode = nil
): Check =
  Check(id: id, title: title, status: status, lines: lines,
        advice: advice, body: body)

# =============================================================================
# Пробы внешних библиотек
# =============================================================================

const
  PortAudioLibs* =
    when defined(windows): ["portaudio_x64.dll"]
    elif defined(macosx): ["libportaudio.dylib"]
    else: ["libportaudio.so", "libportaudio.so.2"]

  RtMidiLibs* =
    when defined(windows): ["rtmidi.dll"]
    elif defined(macosx): ["librtmidi.dylib"]
    else: ["librtmidi.so", "librtmidi.so.7", "librtmidi.so.6", "librtmidi.so.5"]

proc dynlibProbe*(names: openArray[string]): tuple[found: bool; name: string] =
  ## Пробует загрузить библиотеку по имени и сразу выгружает её.
  ##
  ## `dlopen` — ровно то, что делает загрузчик перед `main()` для
  ## dynlib-адаптеров, поэтому проба честно отвечает на вопрос «смог бы
  ## CLI использовать этот бэкенд». Библиотека не инициализируется и не
  ## открывает устройств: загрузили — выгрузили.
  for name in names:
    try:
      let handle = loadLib(name)
      if not handle.isNil:
        unloadLib(handle)
        return (true, name)
    except LibraryError:
      discard
  (false, "")

# =============================================================================
# Секция: сборка
# =============================================================================

proc buildSection*(): Section =
  result.id = "build"
  result.title = "build: версия CLI и ядра"

  var facts = newJObject()
  facts["version"] = %EuterpiaVersion
  facts["schema"] = %CliSchema
  facts["nim"] = %NimVersion
  facts["os"] = %hostOS
  facts["arch"] = %hostCPU
  facts["build"] = %BuildKind
  facts["threads"] = %compileOption("threads")
  facts["mm"] = %MemoryManager

  result.checks.add mkCheck("version", "версия и компилятор", csOk, lines = @[
    CliName & " " & EuterpiaVersion & " (схема JSON " & $CliSchema & ")",
    "Nim " & NimVersion & "; " & hostOS & "/" & hostCPU,
    "сборка: " & BuildKind & "; потоки: " &
      (if compileOption("threads"): "on" else: "off") & "; менеджер памяти: " & MemoryManager
  ], body = facts)

  if BuildKind == "debug":
    result.checks.add mkCheck("buildKind", "тип сборки", csWarn,
      lines = @["debug: проверки включены, производительность не показательна"],
      advice = "для поставки соберите release-бинарь (#113)",
      body = %*{"build": BuildKind})

# =============================================================================
# Секция: аудио-бэкенды
# =============================================================================

# Фабрики miniaudio приведены к типу реестра явно: у `createMiniaudioBackend`
# есть значение по умолчанию, и неявное преобразование в `BackendFactory`
# зависело бы от тонкостей вывода типов.
proc miniaudioFactory(log: Logger): ptr AudioBackendApi =
  createMiniaudioBackend(log)

proc miniaudioDestroy(api: ptr AudioBackendApi) =
  destroyMiniaudioBackend(api)

proc audioSection*(log: Logger): Section =
  result.id = "audio"
  result.title = "audio: бэкенды и устройства"

  var reg = initBackendRegistry()
  let regErr = registerBackend(reg, "miniaudio", miniaudioFactory, miniaudioDestroy)
  if regErr != reOk:
    result.checks.add mkCheck("registry", "реестр бэкендов", csFail,
      lines = @["регистрация miniaudio не удалась: " & $regErr],
      advice = "это баг CLI (#88): пересоберите `nimble cli`",
      body = %*{"error": $regErr})

  var logRef = log
  let (api, createErr) = reg.createBackend("miniaudio", log)
  if api.isNil:
    result.checks.add mkCheck("miniaudio", "miniaudio: создание адаптера", csFail,
      lines = @["адаптер не создан: " & $createErr],
      advice = "пересоберите CLI: `nimble cli` (#31)",
      body = %*{"error": $createErr})
  else:
    let initErr = backendInit(api, addr logRef)
    if initErr != abeOk:
      result.checks.add mkCheck("miniaudio", "miniaudio: инициализация", csFail,
        lines = @["init → " & $initErr & ": звуковой подсистемы нет"],
        advice = "оффлайн-рендер работает и без устройств; для живого звука нужны " &
                 "ALSA/PulseAudio (Linux), CoreAudio (macOS), WASAPI (Windows) (#92)",
        body = %*{"initError": $initErr})
    else:
      let outs = int(backendDeviceCount(api, false))
      let ins = int(backendDeviceCount(api, true))
      var devices: seq[string] = @[]
      let shown = min(outs, MaxDevicesReported)
      for i in 0 ..< shown:
        var info: AudioDeviceInfo
        if backendDeviceInfo(api, int32(i), false, info):
          devices.add info.name & (if info.isDefault: " (по умолчанию)" else: "")
      let facts = %*{
        "initError": "abeOk",
        "outputs": outs,
        "inputs": ins,
        "devices": %devices,
      }
      if outs == 0:
        result.checks.add mkCheck("devices", "устройства вывода", csFail,
          lines = @["устройств вывода: 0; устройств ввода: " & $ins],
          advice = "подключите аудиоустройство или включите звуковую подсистему (#92)",
          body = facts)
      else:
        var lines = @["устройств вывода: " & $outs & "; устройств ввода: " & $ins]
        for d in devices:
          lines.add "  " & d
        result.checks.add mkCheck("devices", "устройства вывода", csOk,
          lines = lines, body = facts)

    # Адаптер освобождается всегда: критерий приёмки #105 — «все созданные
    # адаптеры освобождены (ASan)».
    discard reg.destroyBackend("miniaudio", api)

  let pa = dynlibProbe(PortAudioLibs)
  var paLines: seq[string] = @[]
  let paAdvice =
    if pa.found:
      "для живого воспроизведения и записи нужен CLI, собранный с этим адаптером (#92, #52)"
    else:
      "установите portaudio (apt: libportaudio2, dnf: portaudio) — иначе " &
      "воспроизведение и запись недоступны"
  paLines.add if pa.found: "библиотека: " & pa.name
             else: "библиотека не найдена: " & PortAudioLibs.join(", ")
  paLines.add "адаптер в CLI не залинкован: dynlib-символы резолвятся при старте " &
              "процесса, поэтому импорт уронил бы CLI на машине без библиотеки"
  result.checks.add mkCheck("portaudio", "portaudio: библиотека",
    if pa.found: csOk else: csWarn, lines = paLines, advice = paAdvice,
    body = %*{"available": pa.found, "library": pa.name, "linked": false})

# =============================================================================
# Секция: MIDI
# =============================================================================

proc midiSection*(): Section =
  result.id = "midi"
  result.title = "midi: адаптер и порты"

  let rm = dynlibProbe(RtMidiLibs)
  var lines: seq[string] = @[]
  let advice =
    if rm.found:
      "библиотека на месте; перечисление портов и живая игра — задача #93"
    else:
      "установите rtmidi/libremidi (например, apt: librtmidi2 / dnf: rtmidi) — " &
      "иначе MIDI-команды недоступны (#38)"
  lines.add if rm.found: "библиотека: " & rm.name
             else: "библиотека не найдена: " & RtMidiLibs.join(", ")
  lines.add "порты не перечислялись: адаптер в CLI не залинкован (та же причина, " &
            "что у portaudio) и портов без него не видно"
  result.checks.add mkCheck("rtmidi", "rtmidi: библиотека",
    if rm.found: csOk else: csWarn, lines = lines, advice = advice,
    body = %*{"available": rm.found, "library": rm.name})

# =============================================================================
# Секция: плагины
# =============================================================================

proc pluginDirs*(): seq[string] =
  ## Каталоги поиска CLAP: `CLAP_PATH` (спецификация CLAP) плюс стандартные
  ## каталоги платформы. Порядок фиксирован — вывод должен быть сравнимым.
  for part in getEnv("CLAP_PATH").split(PathSep):
    let dir = part.strip()
    if dir.len > 0:
      result.add dir

  when defined(windows):
    let common = getEnv("COMMONPROGRAMFILES")
    if common.len > 0:
      result.add common / "CLAP"
    let local = getEnv("LOCALAPPDATA")
    if local.len > 0:
      result.add local / "Programs" / "Common" / "CLAP"
  elif defined(macosx):
    result.add "/Library/Audio/Plug-Ins/CLAP"
    result.add getHomeDir() / "Library" / "Audio" / "Plug-Ins" / "CLAP"
  else:
    result.add "/usr/lib/clap"
    result.add "/usr/local/lib/clap"
    result.add getHomeDir() / ".clap"

proc countClapEntries(dir: string): int =
  ## -1 — каталога нет; иначе сколько записей заканчиваются на `.clap`.
  ## Рекурсии нет: по спецификации CLAP каталог — плоский список.
  if not dirExists(dir):
    return -1
  for _, path in walkDir(dir):
    if path.toLowerAscii().endsWith(".clap"):
      inc result

proc pluginsSection*(): Section =
  result.id = "plugins"
  result.title = "plugins: каталоги поиска CLAP"

  var lines: seq[string] = @[]
  var total = 0
  var dirsJson = newJArray()
  for dir in pluginDirs():
    let n = countClapEntries(dir)
    if n < 0:
      lines.add "нет каталога: " & dir
    else:
      total += n
      lines.add $n & " .clap: " & dir
    dirsJson.add %*{"dir": dir, "count": n}

  lines.add "контракт плагинов не загружался: это `plugin scan` (#95), doctor " &
            "только считает файлы"
  result.checks.add mkCheck("clap", "найденные .clap",
    if total > 0: csOk else: csWarn, lines = lines,
    advice = (if total > 0: "детальный разбор — `plugin scan` (#95)"
              else: "установите CLAP-плагины или задайте CLAP_PATH"),
    body = %*{"total": total, "dirs": dirsJson})

# =============================================================================
# Секция: файловая система
# =============================================================================

proc filesystemSection*(ctx: Ctx): Section =
  result.id = "fs"
  result.title = "fs: каталоги кэша, данных и проекта"

  let targets = [
    ("cache", getCacheDir() / "euterpia"),
    ("data", getDataDir() / "euterpia"),
    ("project", getCurrentDir()),
  ]

  for item in targets:
    let name = item[0]
    let dir = item[1]
    var lines = @["каталог (" & name & "): " & dir]
    var status = csOk
    var advice = ""

    if ctx.dryRun:
      lines.add "--dry-run: запись не проверялась"
    else:
      try:
        createDir(dir)
        let probe = dir / ".euterpia_doctor_probe"
        writeFile(probe, "euterpia")
        removeFile(probe)
        lines.add "запись: разрешена"
      except CatchableError as e:
        status = csFail
        advice = "нет прав на запись: " & e.msg
        lines.add "запись: запрещена"

    result.checks.add mkCheck(name, "каталог " & name, status,
      lines = lines, advice = advice,
      body = %*{"dir": dir, "writable": (status == csOk), "dryRun": ctx.dryRun})

# =============================================================================
# Секция: SIMD-дисплей C-ядер
# =============================================================================

proc csrcSection*(): Section =
  result.id = "csrc"
  result.title = "csrc: SIMD-дисплей C-ядер"

  let simd = int(eutCliSimdDispatch()) != 0
  result.checks.add mkCheck("simd", "EUT_HAS_SIMD_DISPATCH",
    if simd: csOk else: csWarn,
    lines = @[
      "EUT_HAS_SIMD_DISPATCH = " &
        (if simd: "1 (avx2 + скалярная версия)" else: "0 (скалярная)"),
      "источник: nodes/builtin/csrc/eut_dsp.h — тот же заголовок, что у нод",
    ],
    advice = (if simd: ""
              else: "скалярная версия корректна; AVX2-дисплей доступен на x86_64 + ELF + GCC/Clang"),
    body = %*{"hasSimdDispatch": simd})

# =============================================================================
# Отчёт
# =============================================================================

proc renderHuman(sections: seq[Section]; verbose: bool): seq[string] =
  result.add CliName & " doctor — самодиагностика окружения"
  result.add CliName & " " & EuterpiaVersion & "; Nim " & NimVersion & "; " &
             hostOS & "/" & hostCPU & "; сборка: " & BuildKind
  result.add ""
  for s in sections:
    result.add "[" & statusName(sectionStatus(s)) & "] " & s.title
    for c in s.checks:
      result.add "    [" & statusName(c.status) & "] " & c.title
      for line in c.lines:
        result.add "        " & line
      if c.advice.len > 0 and (c.status != csOk or verbose):
        result.add "        рекомендация: " & c.advice

proc runDoctor*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia doctor [--json]`. Аудиоустройство НЕ открывается: адаптер
  ## только перечисляет устройства, поэтому doctor не захватывает звук и
  ## не мешает другим приложениям.
  if args.len > 0:
    return usageError("doctor не принимает аргументов, получено: " & args.join(" "),
                      "например: euterpia doctor --json")

  let log = cliLogger(ctx)
  let sections = @[
    buildSection(),
    audioSection(log),
    midiSection(),
    pluginsSection(),
    filesystemSection(ctx),
    csrcSection(),
  ]

  var okCount, warnCount, failCount = 0
  var sectionsJson = newJArray()
  for s in sections:
    var sectionJson = newJObject()
    sectionJson["id"] = %s.id
    sectionJson["title"] = %s.title
    sectionJson["status"] = %statusName(sectionStatus(s))
    var checksJson = newJArray()
    for c in s.checks:
      case c.status
      of csOk: inc okCount
      of csWarn: inc warnCount
      of csFail: inc failCount
      var checkJson = newJObject()
      checkJson["id"] = %c.id
      checkJson["title"] = %c.title
      checkJson["status"] = %statusName(c.status)
      var details = newJArray()
      for line in c.lines:
        details.add %line
      checkJson["details"] = details
      checkJson["advice"] = %c.advice
      if c.body != nil:
        checkJson["facts"] = c.body
      checksJson.add checkJson
    sectionJson["checks"] = checksJson
    sectionsJson.add sectionJson

  var body = newJObject()
  body["sections"] = sectionsJson
  body["summary"] = %*{"ok": okCount, "warn": warnCount, "fail": failCount}

  var lines = renderHuman(sections, ctx.verbose)
  lines.add ""
  lines.add "Итог: " & $okCount & " ok, " & $warnCount & " warn, " & $failCount & " fail"

  if failCount > 0:
    errReport(exEnv, "env",
      "критичные проверки не пройдены: " & $failCount,
      hint = "устраните рекомендации выше (машинный вид: `euterpia doctor --json`)",
      lines = lines, body = body)
  else:
    okReport(body = body, lines = lines)



