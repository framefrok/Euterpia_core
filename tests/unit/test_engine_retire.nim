# tests/unit/test_engine_retire.nim
#
# Утилизация пайплайнов в движке (issues #73, #385).
#
# #73: указатель на утилизируемый пайплайн нельзя терять.
# #385: при этом сам audio-поток НЕ должен освобождать память (MANIFEST §9/§10).
#
# Оба требования закрывает backpressure: `postGraphUpdate` не публикует больше
# `MaxRetireBacklog` незакрытых смен графа, поэтому хранилище утилизации
# (SPSC + localRetire) никогда не переполняется, а `retirePipelineRT` освобождает
# память только на control-path (`pollReclamation`) — в RT лишь кладёт указатель.

import std/unittest
import audio_engine
import compiled_pipeline

proc mkPipeline(): ptr CompiledPipeline =
  ## Реальный пайплайн (createShared + свежая версия), как из compileGraph.
  result = newCompiledPipeline()
  check not result.isNil

suite "audio_engine: утилизация пайплайнов (#73, #385)":
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

  test "backpressure: смена графа без pollReclamation не переполняет утилизацию (#385)":
    ## Публикуем граф за графом, применяем командой (один блок), но НЕ зовём
    ## `pollReclamation`. Раньше это за ~2000 смен переполняло оба уровня и
    ## заставляло RT освобождать пайплайны. Теперь `postGraphUpdate` отклоняет
    ## публикации по достижении порога: dropped == 0 всегда, в RT нет free.
    let engine = createAudioEngine(sampleRate = 48000.0f, blockSize = 128)
    check engine != nil
    defer: destroyAudioEngine(engine)

    var driverOut: array[256, float32]
    let pout = cast[ptr UncheckedArray[float32]](addr driverOut[0])

    var accepted = 0
    var rejected = 0
    let attempts = int(MaxRetireBacklog) + 64

    for i in 0 ..< attempts:
      let p = mkPipeline()
      if engine.postGraphUpdate(p):
        inc accepted
        # Применяем команду: один блок. pollReclamation НЕ зовём.
        engine.renderBlock(nil, 0'i32, pout)
      else:
        inc rejected
        # Публикация не состоялась — владелец освобождает пайплайн сам.
        destroyPipeline(p)

    # Порог достигнут: часть публикаций отклонена (это и есть backpressure).
    check rejected > 0
    check accepted <= int(MaxRetireBacklog) + 1
    # Ни один пайплайн не пришлось освобождать в audio-потоке.
    check engine.droppedRetirementsCount() == 0'u32
    check engine.retirementBacklog() <= MaxRetireBacklog

    # После разбора очереди всё утилизированное освобождается на control-path.
    engine.pollReclamation()
    check engine.droppedRetirementsCount() == 0'u32

  test "pollReclamation на пустом движке безопасен":
    let engine = createAudioEngine(sampleRate = 48000.0f, blockSize = 128)
    check engine != nil
    defer: destroyAudioEngine(engine)
    engine.pollReclamation()
    engine.pollReclamation()
    check engine.droppedRetirementsCount() == 0'u32
    check engine.retirementBacklog() == 0'i32
