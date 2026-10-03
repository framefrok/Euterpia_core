# tests/unit/test_scheduler_pool.nim
#
# Persistent worker pool и двойной буфер расписания (issue #9).
#
# До этого смена графа требовала `initScheduler`, который делает teardown и
# пересоздание воркеров: во время воспроизведения это слышимый разрыв и гонка
# с renderBlock. Теперь смена графа идёт через `swapSchedule` — воркеры
# остаются живыми, а расписание публикуется в неактивный слот.
#
# Ключевая проверка здесь — СТРЕСС: 10 000 свопов подряд во время рендера.
# Именно этот сценарий ловит две разные ошибки, которые на одном-двух свопах
# не проявляются:
#   1. если слот перезаписывается, пока воркер в него читает, — use-after-free
#      на массивах задач (ASan/TSan);
#   2. если главный поток и воркер берут разные слоты — вечное ожидание
#      прогресса (тест висит).
#
# Тест детерминированный: рендер идёт в этом же потоке, а чтение старого
# слота имитируется тем, что между свопами блок успевает завершиться.
# Настоящую гонку потоков проверяет TSan-джоб на общем наборе.

import std/unittest
import std/atomics
import node_interface
import dsp_scheduler

proc noopTask(nodeCtx: ptr NodeProcessContext, audio: ptr NodeAudioPorts,
              ctrl: ptr NodeControlPorts, events: ptr NodeEventPorts,
              userData: pointer) {.cdecl, raises: [], gcsafe.} =
  discard nodeCtx
  discard audio
  discard ctrl
  discard events
  discard userData

proc countingTask(nodeCtx: ptr NodeProcessContext, audio: ptr NodeAudioPorts,
                  ctrl: ptr NodeControlPorts, events: ptr NodeEventPorts,
                  userData: pointer) {.cdecl, raises: [], gcsafe.} =
  ## Считает вызовы в атомарный счётчик из userData.
  ## Позволяет доказать, что после свопа исполняются задачи НОВОГО расписания.
  if userData != nil:
    # `[]` обязателен: fetchAdd принимает `var Atomic`, а userData — указатель.
    let counter = cast[ptr Atomic[int64]](userData)
    discard counter[].fetchAdd(1'i64, moRelaxed)

proc mkDescs(tasks: int): seq[TaskDesc] =
  result = @[]
  for i in 0 ..< tasks:
    var task: DspTask
    task.process = noopTask
    task.nodeId = int32(i)
    var desc = TaskDesc(task: task)
    if i > 0:
      desc.reads.add audioResource(int32(i - 1), 0)
    desc.writes.add audioResource(int32(i), 0)
    result.add desc

proc chainDescs(tasks: int, procRef: DspTaskProc): seq[TaskDesc] =
  ## То же, но с произвольной процедурой задачи — нужно, чтобы отличить
  ## выполнение НОВОГО расписания от старого по счётчику вызовов.
  result = @[]
  for i in 0 ..< tasks:
    var task: DspTask
    task.process = procRef
    task.nodeId = int32(i)
    var desc = TaskDesc(task: task)
    if i > 0:
      desc.reads.add audioResource(int32(i - 1), 0)
    desc.writes.add audioResource(int32(i), 0)
    result.add desc

proc countedDescs(tasks: int, counter: ptr Atomic[int64]): seq[TaskDesc] =
  ## Задачи, считающие вызовы в переданный счётчик.
  result = @[]
  for i in 0 ..< tasks:
    var task: DspTask
    task.process = countingTask
    task.nodeId = int32(i)
    task.userData = cast[pointer](counter)
    var desc = TaskDesc(task: task)
    if i > 0:
      desc.reads.add audioResource(int32(i - 1), 0)
    desc.writes.add audioResource(int32(i), 0)
    result.add desc

suite "dsp_scheduler: горячая смена расписания (issue #9)":
  test "swapSchedule меняет расписание без пересоздания воркеров":
    var sched: DspScheduler
    check initScheduler(sched, mkDescs(3), workerCount = 2)
    check sched.scheduleSwaps() == 0'u64
    check sched.activeTaskCount() == 3

    var pctx = NodeProcessContext(sampleRate: 48000.0f, blockSize: 128)
    sched.renderBlock(addr pctx)
    check sched.abortedBlocks() == 0'u64

    # Смена графа на другое число задач.
    check swapSchedule(sched, mkDescs(6))
    check sched.scheduleSwaps() == 1'u64
    check sched.activeTaskCount() == 6

    # Рендер идёт по НОВОМУ расписанию и не прерывается.
    sched.renderBlock(addr pctx)
    check sched.abortedBlocks() == 0'u64
    check sched.inRenderCount() == 0'i32

    deinitScheduler(sched)

  test "после свопа исполняются задачи нового расписания":
    # Проверяет не только счётчик, но и факт исполнения: старый счётчик
    # перестаёт расти, новый растёт.
    var counter: Atomic[int64]
    counter.store(0'i64, moRelaxed)

    var sched: DspScheduler
    check initScheduler(sched, mkDescs(3), workerCount = 1)

    var pctx = NodeProcessContext(sampleRate: 48000.0f, blockSize: 128)

    check swapSchedule(sched, countedDescs(3, addr counter))
    counter.store(0'i64, moRelaxed)

    for _ in 0 ..< 4:
      sched.renderBlock(addr pctx)

    check counter.load(moRelaxed) > 0'i64

    # Своп на расписание с обычными (не считающими) задачами: счётчик
    # больше не должен расти.
    check swapSchedule(sched, mkDescs(3))
    let before = counter.load(moRelaxed)
    for _ in 0 ..< 4:
      sched.renderBlock(addr pctx)
    check counter.load(moRelaxed) == before

    deinitScheduler(sched)

  test "10 000 свопов во время рендера: без падений и зависаний":
    # Критерий приёмки #9. Каждый своп идёт между блоками, то есть ровно тот
    # сценарий, ради которого всё затевалось: граф меняется НА ХОДУ.
    #
    # `readers` здесь всегда 0 (рендер в этом потоке завершается до свопа),
    # поэтому `reclaimRetired` честно освобождает отставной слот на каждом
    # шаге — проверяется именно путь «освободить → переиспользовать».
    var sched: DspScheduler
    check initScheduler(sched, mkDescs(4), workerCount = 2)

    var pctx = NodeProcessContext(sampleRate: 48000.0f, blockSize: 128)

    let Swaps = 10_000
    for i in 0 ..< Swaps:
      # Меняется только карта задач, число уровней постоянно.
      let n = 4 + (i mod 4)
      check swapSchedule(sched, mkDescs(n))

      # Своп идёт между блоками — так и происходит в движке (команда
      # применяется на границе блока).
      if i mod 8 == 0:
        sched.renderBlock(addr pctx)

    check sched.scheduleSwaps() == uint64(Swaps)
    check sched.abortedBlocks() == 0'u64
    check sched.inRenderCount() == 0'i32

    # После десяти тысяч свопов планировщик обязан остаться рабочим:
    # иначе «тест прошёл», а звук уже мёртв.
    let finalTasks = 4 + ((Swaps - 1) mod 4)
    check sched.activeTaskCount() == finalTasks
    for _ in 0 ..< 16:
      sched.renderBlock(addr pctx)
    check sched.abortedBlocks() == 0'u64

    deinitScheduler(sched)

  test "смена числа уровней не ломает синхронизацию":
    # Своп между расписаниями с РАЗНЫМ числом уровней — самый опасный
    # случай: у сторон разные `stride`, и при рассинхроне ожидание прогресса
    # зависло бы навсегда. Именно это ловит публикация blockSlot главным.
    var sched: DspScheduler
    check initScheduler(sched, mkDescs(2), workerCount = 2)

    var pctx = NodeProcessContext(sampleRate: 48000.0f, blockSize: 128)

    for _ in 0 ..< 50:
      check swapSchedule(sched, mkDescs(2))
      sched.renderBlock(addr pctx)
      check swapSchedule(sched, mkDescs(8))
      sched.renderBlock(addr pctx)
      check swapSchedule(sched, mkDescs(2))
      sched.renderBlock(addr pctx)

    check sched.abortedBlocks() == 0'u64
    check sched.inRenderCount() == 0'i32

    deinitScheduler(sched)

  test "слот переиспользуется, а не течёт":
    # Отставной слот обязан освобождаться на следующем же свопе, иначе
    # десять тысяч смен графа дали бы десять тысяч утечек.
    var sched: DspScheduler
    check initScheduler(sched, mkDescs(3), workerCount = 1)

    var pctx = NodeProcessContext(sampleRate: 48000.0f, blockSize: 128)

    # Свопы подряд без рендера: reclaimRetired обязан освободить слот,
    # иначе второй своп вернул бы false.
    for _ in 0 ..< 100:
      check swapSchedule(sched, mkDescs(3))
    check swapSchedule(sched, mkDescs(3))
    check swapSchedule(sched, mkDescs(3))

    sched.renderBlock(addr pctx)
    check sched.abortedBlocks() == 0'u64

    deinitScheduler(sched)

  test "невозможное расписание отвергается, живое не ломается":
    var sched: DspScheduler
    check initScheduler(sched, mkDescs(3), workerCount = 1)

    var pctx = NodeProcessContext(sampleRate: 48000.0f, blockSize: 128)
    sched.renderBlock(addr pctx)

    # Два писателя одного ресурса — расписание построить нельзя.
    var bad: seq[TaskDesc] = @[]
    for i in 0 ..< 2:
      var task: DspTask
      task.process = noopTask
      task.nodeId = int32(i)
      var desc = TaskDesc(task: task)
      desc.writes.add audioResource(0, 0)
      bad.add desc

    check not swapSchedule(sched, bad)

    # Отказ не должен оставить планировщик в непонятном состоянии:
    # старое расписание продолжает работать.
    check sched.abortedBlocks() == 0'u64
    sched.renderBlock(addr pctx)
    check sched.abortedBlocks() == 0'u64
    check sched.activeTaskCount() == 3

    deinitScheduler(sched)

  test "смена графа после requestStop не вешает рендер":
    # Крайний случай: своп пришёл, когда воркеры уже выходят. Рендер после
    # requestStop обязан прерываться, а не ждать прогресса, которого не будет.
    var sched: DspScheduler
    check initScheduler(sched, mkDescs(3), workerCount = 1)

    var pctx = NodeProcessContext(sampleRate: 48000.0f, blockSize: 128)
    sched.renderBlock(addr pctx)
    check sched.abortedBlocks() == 0'u64

    sched.requestStop()
    # Своп на остановленном планировщике допустим, рендер — нет.
    discard swapSchedule(sched, mkDescs(3))
    sched.renderBlock(addr pctx)
    check sched.abortedBlocks() >= 1'u64
    check sched.inRenderCount() == 0'i32

    deinitScheduler(sched)

  test "swapSchedule на неинициализированном планировщике — no-op":
    var sched: DspScheduler
    check not swapSchedule(sched, mkDescs(3))
    check sched.scheduleSwaps() == 0'u64
    check sched.activeTaskCount() == 0
    deinitScheduler(sched)