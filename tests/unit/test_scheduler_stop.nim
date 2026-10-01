# tests/unit/test_scheduler_stop.nim
#
# Планировщик: запрос остановки не должен превращать `renderBlock`
# в вечный spin-loop (issue #74).
#
# Раньше ожидание прогресса воркеров не проверяло `stopFlag`: после
# `deinitScheduler` воркеры выходят и прогресс уже не публикуют, поэтому
# главный поток зависал навсегда. Достижимость: `initScheduler` первой
# строкой вызывает `deinitScheduler`, то есть повторная инициализация на
# живом планировщике — ровно этот сценарий.
#
# Тест намеренно детерминированный: остановка запрашивается ДО рендера, так
# что на исправленной версии ожидания вообще не происходит (ранний выход).

import std/unittest
import node_interface
import dsp_scheduler

proc noopTask(ctx: ptr NodeProcessContext, audio: ptr NodeAudioPorts,
              ctrl: ptr NodeControlPorts, events: ptr NodeEventPorts,
              userData: pointer) {.cdecl, raises: [], gcsafe.} =
  discard ctx
  discard audio
  discard ctrl
  discard events
  discard userData

proc buildDescs(tasks: int): seq[TaskDesc] =
  ## Цепочка задач: у каждой свой ресурс, поэтому планировщик получает
  ## несколько уровней, а воркеры — реальные задачи.
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

suite "dsp_scheduler: остановка не вешает рендер (issue #74)":
  test "renderBlock прерывается по stopFlag вместо бесконечного ожидания":
    let descs = buildDescs(3)
    var sched: DspScheduler
    check initScheduler(sched, descs, workerCount = 1)
    check sched.inRenderCount() == 0'i32
    check sched.abortedBlocks() == 0'u64

    var ctx = NodeProcessContext(sampleRate: 48000.0f, blockSize: 128)

    # Штатный блок проходит полностью.
    sched.renderBlock(addr ctx)
    check sched.abortedBlocks() == 0'u64
    # Счётчик рендеров обязан вернуться в 0 (инвариант для deinit).
    check sched.inRenderCount() == 0'i32

    # Просим остановку. Воркеры выходят и прогресс больше НЕ публикуют:
    # без проверки флага следующий вызов завис бы здесь навсегда.
    sched.requestStop()
    sched.renderBlock(addr ctx)
    check sched.abortedBlocks() >= 1'u64
    check sched.inRenderCount() == 0'i32

    # Повторный блок после остановки тоже не виснет.
    let before = sched.abortedBlocks()
    sched.renderBlock(addr ctx)
    check sched.abortedBlocks() >= before

    deinitScheduler(sched)

  test "повторный init на остановленном планировщике безопасен":
    let descs = buildDescs(2)
    var sched: DspScheduler
    check initScheduler(sched, descs, workerCount = 1)

    var ctx = NodeProcessContext(sampleRate: 48000.0f, blockSize: 64)
    sched.renderBlock(addr ctx)
    check sched.abortedBlocks() == 0'u64

    # initScheduler начинается с deinitScheduler — на исправленной версии
    # следующий блок просто работает на новом расписании.
    check initScheduler(sched, descs, workerCount = 1)
    sched.renderBlock(addr ctx)
    check sched.inRenderCount() == 0'i32
    deinitScheduler(sched)

  test "deinit на неинициализированном планировщике — no-op":
    var sched: DspScheduler
    check sched.inRenderCount() == 0'i32
    check sched.abortedBlocks() == 0'u64
    deinitScheduler(sched)
    check sched.inRenderCount() == 0'i32
