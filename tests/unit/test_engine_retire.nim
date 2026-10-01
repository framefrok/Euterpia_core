# tests/unit/test_engine_retire.nim
#
# Утилизация пайплайнов в движке (issue #73).
#
# Раньше при переполнении ОБОИХ уровней (SPSC-очередь + локальный overflow)
# указатель на пайплайн просто терялся: `destroyPipeline` не вызывался
# никогда, а `droppedRetirements` рос. Утечка была неограниченной и тихой.
#
# Теперь пайплайн освобождается аварийно, а факт виден control-plane через
# `droppedRetirementsCount()`. Тест проверяет и штатный путь, и переполнение
# (которое достижимо только при ~2000 смен графа без `pollReclamation`).

import std/unittest
import audio_engine
import compiled_pipeline

proc mkPipeline(): ptr CompiledPipeline =
  ## Реальный пайплайн (createShared + свежая версия), как из compileGraph.
  result = newCompiledPipeline()
  check not result.isNil

suite "audio_engine: утилизация пайплайнов (issue #73)":
  test "штатный путь: утилизация уходит в очередь и не теряется":
    let engine = createAudioEngine(sampleRate = 48000.0f, blockSize = 128)
    check engine != nil
    defer: destroyAudioEngine(engine)

    check engine.droppedRetirementsCount() == 0'u32

    for i in 0 ..< 8:
      engine.retirePipelineRT(mkPipeline())

    # Переполнения не было: всё ушло в SPSC-очередь.
    check engine.droppedRetirementsCount() == 0'u32

    # Control-plane разбирает очередь.
    engine.pollReclamation()
    check engine.droppedRetirementsCount() == 0'u32

    # nil безопасен.
    engine.retirePipelineRT(nil)
    check engine.droppedRetirementsCount() == 0'u32

  test "переполнение обоих уровней: пайплайн освобождается, а не теряется":
    let engine = createAudioEngine(sampleRate = 48000.0f, blockSize = 128)
    check engine != nil
    defer: destroyAudioEngine(engine)

    let capacity = AudioRetireQueueCapacity + LocalRetireCapacity
    let extra = 200
    let total = capacity + extra

    # Утилизируем БЕЗ единого pollReclamation: сначала заполняется очередь,
    # затем локальный overflow, дальше начинаются аварийные освобождения.
    for i in 0 ..< total:
      engine.retirePipelineRT(mkPipeline())

    # Ровно `extra` пайплайнов не поместились и были освобождены на месте.
    check engine.droppedRetirementsCount() == uint32(extra)

    # Ни один из оставшихся не потерян: control-plane забирает очередь и
    # локальный overflow, destroyAudioEngine — всё остальное. Если бы
    # аварийного освобождения не было, эти `extra` пайплайнов утекли бы
    # (проверяется прогоном под ASan).
    engine.pollReclamation()

  test "pollReclamation на пустом движке безопасен":
    let engine = createAudioEngine(sampleRate = 48000.0f, blockSize = 128)
    check engine != nil
    defer: destroyAudioEngine(engine)
    engine.pollReclamation()
    engine.pollReclamation()
    check engine.droppedRetirementsCount() == 0'u32
