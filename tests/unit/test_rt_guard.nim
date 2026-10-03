# tests/unit/test_rt_guard.nim
#
# DEBUG_ASSERT_REALTIME_SAFE (issue #11, MANIFEST §45).
#
# Тест доказывает две вещи, и обе — про одинаковый код:
#
#  1. В DEBUG-сборке (`rtGuardEnabled`, её задаёт config.nims) запрещённая
#     операция ВНУТРИ audio-контекста поднимает `Defect` — то есть
#     регрессия «newSeq в renderBlock» больше не доезжает до студии.
#  2. В RELEASE-сборке тот же код молчит и не меняет счётчики: overhead = 0.
#
# Проверка идёт через try/except Defect, а не через `expect`/`raises`:
# doAssert бросает Defect, и unittest не умеет его перехватывать без
# try/except. Само наличие ветки `when defined(rtGuardEnabled)` делает
# тест зелёным в обоих режимах сборки — это и требование issue
# («nimble test зелёный в обоих режимах»).

import std/unittest
import rt_guard

suite "rt_guard: запрещённые операции в audio-потоке (issue #11)":

  test "вне audio-контекста проверки молчат — control-path свободен":
    resetViolations()

    # Control-path (сборка проекта, загрузка, логи) аллоцирует постоянно.
    # Пометки здесь стоять не должны, иначе guard заблокирует всю разработку.
    var scratch = newSeq[float32](64)
    scratch[0] = 1.0f
    rtAssertNoAlloc()
    rtAssertNoLock()
    rtAssertNoIo()

    check scratch.len == 64
    check not inRealtimeContext()
    check realtimeDepth() == 0'i32
    check violationCount() == 0'u64

  test "вложенный rtScope восстанавливает глубину при выходе":
    # Кейс одинаков для debug и release. В release `rtGuardEnabled` выключен,
    # поэтому `rtScope` НЕ ведёт счётчик (это и есть требование «overhead = 0»):
    # проверяется контракт «depth == 0 вне audio-контекста», а не конкретное
    # значение счётчика. Конкретные значения глубины проверяет debug-ветка
    # ниже — там счётчик действительно работает.
    resetViolations()

    # Тело пустое намеренно: внутри scope нельзя ставить rtAssert*, иначе
    # debug-ветка честно уронит процесс (doAssert -> Defect), а этот кейс
    # проверяет не violation, а симметрию входа/выхода.
    rtScope():
      rtScope():
        discard

    # Полный выход: depth строго 0, иначе пометка «залипнет» и следующий
    # control-path вызов увидит себя в audio-потоке.
    check not inRealtimeContext()
    check realtimeDepth() == 0'i32
    check violationCount() == 0'u64

  when defined(rtGuardEnabled):
    test "счётчик глубины растёт и падает вместе со scope (debug)":
      # Счётчик — основа вложенности: renderBlock -> processPipeline -> нода.
      # В release его нет намеренно, поэтому проверка живёт только здесь.
      resetViolations()

      rtScope():
        check realtimeDepth() == 1'i32
        rtScope():
          check realtimeDepth() == 2'i32
          rtScope():
            check realtimeDepth() == 3'i32
          check realtimeDepth() == 2'i32
        check realtimeDepth() == 1'i32
      check realtimeDepth() == 0'i32
      check violationCount() == 0'u64

    test "аллокация в audio-потоке ловится в debug":
      resetViolations()

      var caught = false
      try:
        rtScope():
          # Ровно то, что ломает xrun: буфер под ноду, созданный в process().
          rtAssertNoAlloc()
      except Defect:
        caught = true

      check caught
      check violationCount() == 1'u64
      check lastViolation().kind == rvAlloc

    test "lock в audio-потоке ловится и опознаётся по роду":
      resetViolations()

      var caught = false
      try:
        rtScope():
          rtAssertNoLock()
      except Defect:
        caught = true

      check caught
      check violationCount() == 1'u64
      check lastViolation().kind == rvLock

    test "file I/O в audio-потоке ловится и опознаётся по роду":
      resetViolations()

      var caught = false
      try:
        rtScope():
          rtAssertNoIo()
      except Defect:
        caught = true

      check caught
      check violationCount() == 1'u64
      check lastViolation().kind == rvIo

    test "несколько нарушений считаются, а не теряются":
      resetViolations()

      var caught = 0
      for kind in 0 .. 2:
        try:
          rtScope():
            case kind
            of 0: rtAssertNoAlloc()
            of 1: rtAssertNoLock()
            else: rtAssertNoIo()
        except Defect:
          inc caught

      check caught == 3
      check violationCount() == 3'u64

    test "rtScope корректно выходит при исключении из тела":
      # Реальный сценарий: нода бросает Defect из process(). Если бы depth не
      # сбрасывался, ВЕСЬ поток audio-callback остался бы помеченным и любая
      # последующая control-работа падала бы ложно.
      resetViolations()

      try:
        rtScope():
          check inRealtimeContext()
          raise newException(Defect, "boom from process()")
      except Defect:
        discard

      check not inRealtimeContext()
      check realtimeDepth() == 0'i32
      check violationCount() == 0'u64

    test "depth не уходит в минус при избыточном rtLeave":
      # Асимметрия enter/leave не должна ломать счётчик: иначе последующие
      # rtScope() дали бы depth <= 0 и guard перестал бы работать.
      resetViolations()

      rtLeave()
      rtLeave()
      rtLeave()

      check realtimeDepth() == 0'i32

      rtScope():
        check inRealtimeContext()
        check realtimeDepth() == 1'i32
      check not inRealtimeContext()

    test "глубина сверх MaxRtDepth ловится как rvDepth, а не молчит":
      # maxRtDepth — заявленный порог: глубже он означает ошибку симметрии
      # rtEnter/rtLeave, а не легитимный глубокий путь. Раньше константа была
      # объявлена и не использовалась — лишний вход без выхода не ловился.
      # Если порог изменят, тест обязан быть обновлён вместе с ним.
      check MaxRtDepth == 8

      resetViolations()

      var caught = false
      try:
        rtScope():                 # 1
          rtScope():               # 2
            rtScope():             # 3
              rtScope():           # 4
                rtScope():         # 5
                  rtScope():       # 6
                    rtScope():     # 7
                      rtScope():   # 8 -> tlDepth == MaxRtDepth
                        rtScope(): # 9 -> переполнение -> rvDepth
                          discard
      except Defect:
        caught = true

      check caught
      check violationCount() == 1'u64
      check lastViolation().kind == rvDepth

      # Разворот стека вернул глубину: guard не «залипает», следующий
      # control-path-код снова видит себя вне audio-контекста.
      check not inRealtimeContext()
      check realtimeDepth() == 0'i32

    test "ручной rtEnter тоже упирается в MaxRtDepth":
      resetViolations()

      var caught = false
      try:
        # MaxRtDepth успешных входов, а на следующем — переполнение.
        for _ in 0 .. MaxRtDepth:
          rtEnter()
      except Defect:
        caught = true

      check caught
      check violationCount() == 1'u64
      check lastViolation().kind == rvDepth

      # Избыточные rtLeave безопасны и снимают остаток глубины.
      for _ in 0 .. MaxRtDepth + 1:
        rtLeave()
      check not inRealtimeContext()
      check realtimeDepth() == 0'i32

  else:
    test "release: те же нарушения молчат, счётчики не растут":
      # Критерий приёмки #11: «release-сборка: rtAssert* компилируются
      # в пустоту, overhead = 0». Проверяем наблюдаемый эффект: нарушение
      # внутри audio-контекста НЕ роняет процесс и НЕ тратит счётчики.
      resetViolations()

      rtScope():
        check not inRealtimeContext()
        check realtimeDepth() == 0'i32
        rtAssertNoAlloc()
        rtAssertNoLock()
        rtAssertNoIo()
        # Даже настоящая аллокация не должна падать в release.
        var buf = newSeq[float32](128)
        buf[0] = 0.5f
        check buf.len == 128

      check violationCount() == 0'u64
      check realtimeDepth() == 0'i32

  test "счётчики сбрасываются между кейсами":
    resetViolations()
    check violationCount() == 0'u64
    resetViolations()
    check violationCount() == 0'u64
    check realtimeDepth() == 0'i32
