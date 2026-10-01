# backend_manager.nim
#
# Владелец текущего аудио-адаптера и hot-swap между бэкендами (issue #32).
#
#   Core -> audio_backend_api   (контракт)
#   хост -> backend_manager     (открыть/переключить/закрыть)
#
# Отдельный модуль от `backend_registry`:
#   * реестр отвечает на вопрос «что вообще есть» (control-path, без
#     жизненного цикла);
#   * менеджер владеет ОДНИМ открытым адаптером и отвечает за переход
#     `stop -> close -> open` при смене бэкенда.
#
# Правила (MANIFEST §72, §74, §75):
#   * никаких глобальных синглтонов — менеджер явный объект с владельцем;
#   * переключение идёт строго на control-path: audio-поток менеджер не
#     читает и не трогает;
#   * сбой одного адаптера (нет библиотеки, не открылся) не оставляет
#     «висящий» поток: закрываем то, что успели открыть, и сообщаем код.

import audio_backend_api
import backend_registry

{.push raises: [].}

type
  BackendManagerError* = enum
    bmOk = 0,
    bmUnknownBackend,     ## имени нет в реестре
    bmUnavailable,        ## ни один адаптер не смог создаться
    bmOpenFailed,         ## init/open/start не удались
    bmAlreadyOpen         ## уже открыт другой бэкенд

  BackendManager* = object
    ## Владелец текущего адаптера. Явный объект с владельцем.
    registry: BackendRegistry
    api: ptr AudioBackendApi
    name: string
    running: bool
    log: Logger

proc initBackendManager*(log: Logger = silentLogger()): BackendManager =
  result.registry = initBackendRegistry()
  result.api = nil
  result.name = ""
  result.running = false
  result.log = log

proc registerBackend*(m: var BackendManager; name: string;
                      create: BackendFactory;
                      destroy: BackendDestroyer): RegistryError =
  ## Регистрация адаптера в реестре менеджера. Хост вызывает это для каждого
  ## собранного им адаптера; Core имён библиотек не знает.
  m.registry.registerBackend(name, create, destroy)

proc backendNames*(m: BackendManager): seq[string] =
  ## Список доступных имён для UI/CLI.
  m.registry.backendNames()

proc hasBackend*(m: BackendManager; name: string): bool =
  m.registry.hasBackend(name)

proc currentName*(m: BackendManager): string =
  ## Имя открытого бэкенда или "" — контрольная точка для UI.
  m.name

proc currentApi*(m: BackendManager): ptr AudioBackendApi =
  ## Указатель на открытый адаптер (владелец — менеджер). nil, если закрыт.
  m.api

proc isOpen*(m: BackendManager): bool =
  not m.api.isNil

proc isRunning*(m: BackendManager): bool =
  m.running

proc closeBackend*(m: var BackendManager) =
  ## `stop -> close -> shutdown -> destroy`. Идемпотентно.
  if m.api.isNil:
    return
  if m.running:
    discard backendStop(m.api)
    m.running = false
  backendClose(m.api)
  backendShutdown(m.api)
  discard m.registry.destroyBackend(m.name, m.api)
  m.api = nil
  m.name = ""

proc openBackend*(m: var BackendManager; name: string;
                  cfg: AudioStreamConfig;
                  render: AudioRenderProc; engineCtx: pointer): BackendManagerError =
  ## Создаёт, инициализирует, открывает и запускает адаптер с этим именем.
  ##
  ## Любой сбой на шаге init/open/start откатывает уже сделанное: адаптер
  ## уничтожается, «висящего» потока не остаётся. Требует закрытого менеджера.
  if not m.api.isNil:
    return bmAlreadyOpen

  let (api, err) = m.registry.createBackend(name, m.log)
  if err == reUnknownBackend:
    return bmUnknownBackend
  if err != reOk or api.isNil:
    return bmUnavailable

  if backendInit(api, addr m.log) != abeOk:
    discard m.registry.destroyBackend(name, api)
    return bmOpenFailed

  if backendOpen(api, cfg, render, engineCtx) != abeOk:
    backendShutdown(api)
    discard m.registry.destroyBackend(name, api)
    return bmOpenFailed

  if backendStart(api) != abeOk:
    backendClose(api)
    backendShutdown(api)
    discard m.registry.destroyBackend(name, api)
    return bmOpenFailed

  m.api = api
  m.name = name
  m.running = true
  bmOk

proc switchBackend*(m: var BackendManager; name: string;
                    cfg: AudioStreamConfig;
                    render: AudioRenderProc;
                    engineCtx: pointer): BackendManagerError =
  ## Hot-swap на control-path: `stop -> close -> open`.
  ##
  ## Переключение на уже открытый и запущенный бэкенд — no-op: перезапуск
  ## потока без причины сам по себе источник xrun'ов. Если открыть новый
  ## бэкенд не удалось, менеджер остаётся ЗАКРЫТЫМ (это и есть безопасное
  ## состояние: вызывающий может переключиться обратно).
  if not m.api.isNil and m.name == name and m.running:
    return bmOk
  m.closeBackend()
  m.openBackend(name, cfg, render, engineCtx)

proc openPreferred*(m: var BackendManager;
                    cfg: AudioStreamConfig;
                    render: AudioRenderProc;
                    engineCtx: pointer;
                    preferred: openArray[string]): BackendManagerError =
  ## Выбор по приоритету: сначала имена из `preferred` в указанном порядке,
  ## затем остальные зарегистрированные. Адаптер, который не создался или не
  ## открылся, ПРОПУСКАЕТСЯ — один сломанный бэкенд не мешает выбрать
  ## рабочий (критерий приёмки #32).
  if not m.api.isNil:
    return bmAlreadyOpen

  var order: seq[string] = @[]
  for name in preferred:
    order.add(name)
  for i in 0 ..< m.registry.backendCount():
    let name = m.registry.backendNameAt(i)
    var seen = false
    for candidate in order:
      if candidate == name:
        seen = true
    if not seen:
      order.add(name)

  for name in order:
    if m.openBackend(name, cfg, render, engineCtx) == bmOk:
      return bmOk

  if order.len == 0:
    return bmUnknownBackend
  bmUnavailable

{.pop.}
