# adapters/lazy_dynlib.nim
#
# Ленивая загрузка внешней библиотеки адаптера (issue #267).
#
# Почему не `{.pragma: ..., dynlib: "libfoo.so".}`:
#   такая прагма резолвит символы в ИНИЦИАЛИЗАЦИИ МОДУЛЯ. Если библиотеки
#   нет, процесс падает до `main()` — CLI не может ни перечислить бэкенды,
#   ни вернуть «адаптер недоступен». Проверено на adapters/rtmidi без
#   librtmidi: `could not load: librtmidi.so` и ни одной строки кода.
#
# Здесь библиотека грузится явно и ТОЛЬКО при первом обращении адаптера
# (`backendInit`/`midiInit`), а отсутствие библиотеки — данные (`false`),
# которые адаптер превращает в `abeUnavailable`/`meUnavailable`.
#
# Имя библиотеки можно переопределить переменной окружения. Это не
# «настройка ради настройки»: без переопределения нельзя проверить ветку
# «библиотеки нет» на машине, где она установлена (тест #267).

import std/[dynlib, os]

const
  LazyNameMax* = 256

type
  LazyLibrary* = object
    ## Состояние одной внешней библиотеки адаптера.
    ##
    ## Строки — фиксированные буферы, а не `string`: адаптер вызывает
    ## загрузку из `gcsafe`-метода таблицы (`backendInit`/`midiInit`), а
    ## обращение к глобальной GC-памяти в таком методе запрещено
    ## компилятором (issue #267).
    handle*: LibHandle
    name*: array[LazyNameMax, char]
    error*: array[LazyNameMax, char]

proc setFixed(dst: var array[LazyNameMax, char]; value: string) =
  let n = min(value.len, LazyNameMax - 1)
  for i in 0 ..< n:
    dst[i] = value[i]
  dst[n] = '\0'

proc getFixed(src: array[LazyNameMax, char]): string =
  result = ""
  var i = 0
  while i < LazyNameMax and src[i] != '\0':
    result.add src[i]
    inc i

proc resolveLibraryName*(envVar, defaultName: string): string =
  ## Имя библиотеки: переменная окружения сильнее платформенного умолчания.
  ## Вызывается на control-path ДО gcsafe-методов (create*), поэтому
  ## `getEnv` здесь допустим.
  let override = getEnv(envVar)
  if override.len > 0: override else: defaultName

proc setLibraryName*(lib: var LazyLibrary; name: string) =
  setFixed(lib.name, name)

proc libraryName*(lib: LazyLibrary): string =
  getFixed(lib.name)

proc libraryError*(lib: LazyLibrary): string =
  getFixed(lib.error)

proc openLibrary*(lib: var LazyLibrary): bool =
  ## Загружает библиотеку по имени, заданному `setLibraryName`.
  ## Повторный вызов после успеха — no-op; после ошибки — новая попытка.
  if not lib.handle.isNil:
    return true
  if lib.name[0] == '\0':
    setFixed(lib.error, "имя библиотеки не задано")
    return false
  lib.handle = loadLib(libraryName(lib))
  if lib.handle.isNil:
    setFixed(lib.error, "не удалось загрузить библиотеку: " & libraryName(lib))
    return false
  lib.error[0] = '\0'
  true

proc symPtr*[T](lib: var LazyLibrary; symbol: cstring; dst: var T): bool =
  ## Резолвит символ. `T` — тип `proc {.cdecl.}`, `dst` — указатель на него.
  ##
  ## Возвращает false, если библиотека не загружена или символа нет; в
  ## `lib.error` остаётся имя символа — диагностика без исключений.
  if lib.handle.isNil:
    return false
  dst = cast[T](symAddr(lib.handle, symbol))
  if dst.isNil:
    setFixed(lib.error, "нет символа " & $symbol & " в " & libraryName(lib))
    return false
  true
