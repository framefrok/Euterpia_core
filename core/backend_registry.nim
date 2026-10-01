# backend_registry.nim
#
# Реестр аудио-бэкендов Core (issue #32).
#
#   Core -> audio_backend_api      (контракт)
#   хост -> backend_registry       (регистрирует то, что собрал сам)
#
# Зачем отдельный модуль:
#   до него выбор бэкенда отсутствовал вовсе: хост собирал один конкретный
#   адаптер и «прибивал» его к движку. Форматы аудио-бэкендов перечислены в
#   MANIFEST §8 как ЗАМЕНЯЕМЫЕ, поэтому Core должен уметь выбирать по имени,
#   а не знать библиотеку.
#
# Границы:
#   * Core знает только СТРОКОВЫЕ имена и фабрики, зарегистрированные хостом;
#   * имён и символов библиотек в этом модуле нет вообще — ни в коде, ни в
#     прозе: guard-джоб `architecture` в CI проверяет это механически;
#   * реестр — ЯВНЫЙ объект с владельцем, а не глобальный синглтон
#     (MANIFEST §72, §74);
#   * все операции — control-path: audio-поток реестр не читает.

import audio_backend_api

{.push raises: [].}

# Контракт фабрики намеренно маленький: адаптер умеет ровно «создать себя»
# и «уничтожить себя» — этого достаточно и для выбора, и для hot-swap.
type
  BackendFactory* = proc(log: Logger): ptr AudioBackendApi
    {.closure, raises: [].}
    ## Создаёт адаптер или возвращает nil, если библиотека недоступна.
    ## Control-path: создание/инициализация никогда не вызываются из
    ## audio-потока.

  BackendDestroyer* = proc(api: ptr AudioBackendApi) {.closure, raises: [].}
    ## Парная операция к BackendFactory: освобождает адаптер целиком.

  RegistryError* = enum
    reOk = 0,
    reUnknownBackend,      ## имени нет в реестре
    reAlreadyRegistered,   ## имя уже занято
    reUnavailable          ## фабрика не смогла создать адаптер

  BackendRegistry* = object
    ## Явный объект с владельцем. Копирование допустимо (это control-path
    ## значение), но владельцем считается тот, кто его создал.
    names: seq[string]
    creates: seq[BackendFactory]
    destroys: seq[BackendDestroyer]

proc initBackendRegistry*(): BackendRegistry =
  ## Пустой реестр. Хост наполняет его теми адаптерами, которые сам собрал.
  BackendRegistry(names: @[], creates: @[], destroys: @[])

proc backendCount*(r: BackendRegistry): int =
  r.names.len

proc backendNameAt*(r: BackendRegistry; index: int): string =
  ## Имя по индексу регистрации; пустая строка — индекс вне диапазона.
  if index < 0 or index >= r.names.len:
    return ""
  r.names[index]

proc backendNames*(r: BackendRegistry): seq[string] =
  ## Список имён в порядке регистрации. Control-path (UI/CLI).
  result = newSeq[string](r.names.len)
  for i in 0 ..< r.names.len:
    result[i] = r.names[i]

proc indexOf*(r: BackendRegistry; name: string): int =
  ## Индекс имени или -1. Сравнение точное: имена бэкендов —
  ## идентификаторы, а не пользовательский текст.
  for i in 0 ..< r.names.len:
    if r.names[i] == name:
      return i
  -1

proc hasBackend*(r: BackendRegistry; name: string): bool =
  r.indexOf(name) >= 0

proc registerBackend*(
  r: var BackendRegistry;
  name: string;
  create: BackendFactory;
  destroy: BackendDestroyer
): RegistryError =
  ## Регистрирует адаптер. Повторная регистрация того же имени отвергается:
  ## молчаливая перезапись сделала бы выбор бэкенда недетерминированным.
  if name.len == 0 or create.isNil or destroy.isNil:
    return reUnknownBackend
  if r.hasBackend(name):
    return reAlreadyRegistered
  r.names.add(name)
  r.creates.add(create)
  r.destroys.add(destroy)
  reOk

proc createBackend*(
  r: BackendRegistry;
  name: string;
  log: Logger = silentLogger()
): tuple[api: ptr AudioBackendApi, error: RegistryError] =
  ## Создаёт адаптер по имени. Недоступная библиотека — это `reUnavailable`
  ## и nil, а не исключение: один сломанный адаптер не должен мешать
  ## выбрать другой (issue #32).
  let i = r.indexOf(name)
  if i < 0:
    return (nil, reUnknownBackend)
  if r.creates[i].isNil:
    return (nil, reUnavailable)
  let api = r.creates[i](log)
  if api.isNil:
    return (nil, reUnavailable)
  (api, reOk)

proc destroyBackend*(r: BackendRegistry; name: string;
                     api: ptr AudioBackendApi): bool =
  ## Освобождает адаптер тем деструктором, что зарегистрирован вместе с
  ## фабрикой. false — имени нет или адаптер уже nil.
  if api.isNil:
    return false
  let i = r.indexOf(name)
  if i < 0 or r.destroys[i].isNil:
    return false
  r.destroys[i](api)
  true

proc pickBackend*(
  r: BackendRegistry;
  preferred: openArray[string];
  log: Logger = silentLogger()
): tuple[name: string, api: ptr AudioBackendApi, error: RegistryError] =
  ## Политика выбора (issue #32): явный приоритет → первый доступный.
  ##
  ## Порядок в `preferred` — это приоритет хоста/платформы. Недоступный
  ## адаптер из списка пропускается, а не прерывает выбор. Если ни один из
  ## приоритетных не подошёл, берётся первый зарегистрированный, который
  ## вообще смог создаться.
  for name in preferred:
    let (api, err) = r.createBackend(name, log)
    if err == reOk and not api.isNil:
      return (name, api, reOk)

  for i in 0 ..< r.names.len:
    let (api, err) = r.createBackend(r.names[i], log)
    if err == reOk and not api.isNil:
      return (r.names[i], api, reOk)

  if r.names.len == 0:
    return ("", nil, reUnknownBackend)
  ("", nil, reUnavailable)

{.pop.}
