# rt_guard.nim
#
# DEBUG_ASSERT_REALTIME_SAFE: guard на запрещённые операции в audio-потоке
# (MANIFEST §45, issue #11).
#
# ## Зачем
#
# Регламент «в audio-потоке нет malloc / lock / IO» держался на дисциплине:
# компилятор проверяет `raises: []` и `gcsafe`, но НЕ видит `newSeq`,
# `acquire(lock)` и `readFile`. Регрессия в таком месте проходит компиляцию,
# TSan и UBSan и обнаруживается только на слух — как щелчок или xrun.
#
# ## Как работает
#
# Thread-local счётчик глубины: audio-вход помечает поток как «я сейчас
# внутри audio callback», точки риска спрашивают `inRealtimeContext` и
# падают в debug. В release проверки компилируются в пустоту — overhead = 0.
#
# ## Чего guard НЕ делает
#
# Он не перехватывает malloc и не перехватывает lock. Он ловит нарушение в
# точке, где разработчик сам пометил опасную операцию. Это осознанный
# компромисс: перехват аллокатора потребовал бы подмены глобальных
# new/delete (ломает ABI плагинов и несовместим с TSan-джобой), а молчащая
# подмена lock'а маскировала бы реальные блокировки. Guard даёт явный,
# легко локализуемый сигнал там, где запрет можно нарушить осознанно.
#
# ## Где ставить пометки
#
#   proc nodeProcess(...) {.rt.} =
#     rtScope()                       # весь RT-путь ноды под guard'ом
#     ...
#     var buf = newSeq[float32](64)   # в debug: падение с внятным текстом
#     rtAssertNoAlloc()                # явная пометка без области
#
# Штатно: debug-сборка ловит нарушение, release-сборка молчит.

when not compileOption("threads"):
  {.error: "rt_guard requires --threads:on (thread-local счётчик глубины)".}

import std/atomics

type
  RtViolation* = enum
    ## Категория запрещённой операции. Нужна, чтобы тест и лог отличали
    ## аллокацию от лока от I/O — у них разные причины и разные исправления.
    rvAlloc
    rvLock
    rvIo

  RtGuardInfo* = object
    ## Снимок состояния guard'а. Читается только из control-path.
    depth*: int32          ## текущая глубина вложенности в этом потоке
    violations*: uint64    ## сколько всего нарушений поймано (все потоки)
    lastKind*: RtViolation ## категория последнего нарушения
    lastSite*: int32       ## `line(` в точке нарушения (0 = неизвестно)

const
  ## Максимальная глубина вложенности. Глубже — ошибка в логике вложения,
  ## а не признак глубокого RT-пути: renderBlock -> recorder -> track.
  MaxRtDepth = 8

var
  # Thread-local. `--threads:on` делает глобалы TLS по умолчанию, поэтому
  # audio-поток и control-поток видят РАЗНЫЕ значения: пометка в audio-потоке
  # не запрещает malloc на control-path (и наоборот) — ровно то, что нужно.
  tlDepth: int32
  tlLastSite: int32

  # Счётчики нарушений — общие для всех потоков: control-path читает их,
  # чтобы увидеть, что debug-прогон что-то поймал.
  gViolations: Atomic[uint64]
  gLastKind: Atomic[int32]

# ----------------------------------------------------------------------------
# Состояние
# ----------------------------------------------------------------------------

proc inRealtimeContext*(): bool {.inline, raises: [].} =
  ## Находится ли текущий поток внутри audio callback.
  ##
  ## В release возвращает константу `false`, и компилятор вырезает ветку
  ## целиком: если результат используется только в `if`, условие
  ## оптимизируется до `false` (мёртвая ветка) — никаких чтений TLS.
  when defined(rtGuardEnabled):
    tlDepth > 0
  else:
    false

proc realtimeDepth*(): int32 {.inline, raises: [].} =
  ## Глубина вложенности RT-контекста в этом потоке. Для диагностики.
  when defined(rtGuardEnabled):
    tlDepth
  else:
    0'i32

proc violationCount*(): uint64 {.inline, raises: [].} =
  ## Сколько нарушений поймано суммарно по всем потокам. Control-path.
  gViolations.load(moRelaxed)

proc lastViolation*(): tuple[kind: RtViolation, site: int32] =
  ## Последнее пойманное нарушение. Control-path (для отчёта в тесте/логе).
  let raw = gLastKind.load(moRelaxed)
  result.site = tlLastSite
  if raw >= 0 and raw <= int32(high(RtViolation)):
    result.kind = RtViolation(raw)
  else:
    result.kind = rvAlloc

proc resetViolations*() {.inline, raises: [].} =
  ## Сбросить счётчики. Control-path: тест вызывает между кейсами.
  gViolations.store(0'u64, moRelaxed)
  gLastKind.store(-1'i32, moRelaxed)
  tlLastSite = 0



# ----------------------------------------------------------------------------
# Регистрация нарушения
# ----------------------------------------------------------------------------

proc noteViolation(kind: RtViolation, site: int32) {.inline, raises: [].} =
  ## Зафиксировать нарушение и упасть в debug.
  ##
  ## Порядок важен: счётчики обновляются ДО падения, иначе тест, поймавший
  ## нарушение через `doAssert`/исключение, увидит нули и не сможет отличить
  ## «поймали» от «не поймали».
  gLastKind.store(int32(kind), moRelaxed)
  discard gViolations.fetchAdd(1'u64, moRelaxed)
  tlLastSite = site

  when defined(rtGuardEnabled):
    case kind
    of rvAlloc:
      doAssert(false, "EUT_RT_GUARD_VIOLATION(rvAlloc): аллокация памяти в audio-потоке " &
        "(renderBlock/processPipeline/recordBlock). " &
        "Вынесите буфер в preallocated-арену или в control-path.")
    of rvLock:
      doAssert(false, "EUT_RT_GUARD_VIOLATION(rvLock): lock в audio-потоке — допустим только " &
        "atomic load/store. Замените на lock-free примитив (ring_buffer, " &
        "memory_pool, Atomic).")
    of rvIo:
      doAssert(false, "EUT_RT_GUARD_VIOLATION(rvIo): file I/O в audio-потоке. Файл читает " &
        "writer-thread (audio_recorder), выдаёт данные через кольцо.")

# ----------------------------------------------------------------------------
# Точки вставки
# ----------------------------------------------------------------------------

template rtAssertNoAlloc*(site: static[string] = "") =
  ## Пометить точку как «здесь нельзя аллоцировать».
  ## `site` попадает в текст падения: без него в стектрейсе видно только
  ## строку rt_guard.
  when defined(rtGuardEnabled):
    if inRealtimeContext():
      noteViolation(rvAlloc, int32(instantiationInfo(-1, true).line))
  else:
    discard site

template rtAssertNoLock*(site: static[string] = "") =
  ## Пометить точку как «здесь нельзя брать lock».
  when defined(rtGuardEnabled):
    if inRealtimeContext():
      noteViolation(rvLock, int32(instantiationInfo(-1, true).line))
  else:
    discard site

template rtAssertNoIo*(site: static[string] = "") =
  ## Пометить точку как «здесь нельзя ходить в файл/сеть».
  when defined(rtGuardEnabled):
    if inRealtimeContext():
      noteViolation(rvIo, int32(instantiationInfo(-1, true).line))
  else:
    discard site

template rtScope*(body: untyped) =
  ## Пометить блок как audio-путь: на всё время `body` текущий поток
  ## считается находящимся внутри audio callback.
  ##
  ## Вложенность поддержана счётчиком, а не флагом: `renderBlock` ->
  ## `processPipeline` -> нода — три уровня, и выход из внутреннего не должен
  ## снимать пометку внешнего.
  when defined(rtGuardEnabled):
    inc tlDepth
    try:
      body
    finally:
      if tlDepth > 0:
        dec tlDepth
  else:
    body

template rtEnter*() =
  ## Ручной вход в RT-контекст (для входных точек, которые не могут обернуть
  ## тело в `rtScope`, например `{.cdecl.}`-callback с ранним `return`).
  when defined(rtGuardEnabled):
    inc tlDepth

template rtLeave*() =
  ## Парный к `rtEnter`. Симметричен, depth не уходит в минус.
  when defined(rtGuardEnabled):
    if tlDepth > 0:
      dec tlDepth
