# tests/unit/test_mix.nim
#
# Сумматор `euterpia.mix` (#275): несколько аудиовходов → один выход.
# Проверяются три вещи, которые ломаются чаще всего: пустые (не подключённые)
# входы читаются как ноль, сумма верна, уровень применяется.

import std/[math, unittest]
import signal_types
import node_interface
import sdk/node_api
import builtin/mixing/mix

const Block = 256
const Sr = 48000.0f

proc makeBuffer(samples: var seq[float32]; value: float32): AudioBuffer =
  for i in 0 ..< samples.len:
    samples[i] = value
  AudioBuffer(data: cast[ptr UncheckedArray[float32]](addr samples[0]),
              channels: 1, frames: int32(samples.len), stride: int32(samples.len))

suite "mix: сумматор":
  test "складывает подключённые входы, неподключённые молчат":
    let desc = getMixDesc()
    let factory = getMixFactory()
    let state = factory.create(desc, nil)
    check not state.isNil
    # Уровень по умолчанию (0 dB) ставит движок из проекта; в unit-тесте
    # это делаем явно — иначе сглаживатель стоит на нуле и глушит выход.
    factory.setParam(state, MixParamLevel, 0.0f, false)

    var ctx = NodeProcessContext(sampleRate: Sr, blockSize: int32(Block))
    var inA, inB, outS: seq[float32]
    inA = newSeq[float32](Block)
    inB = newSeq[float32](Block)
    outS = newSeq[float32](Block)
    var bufA = makeBuffer(inA, 0.25f)
    var bufB = makeBuffer(inB, -0.10f)
    var bufO = makeBuffer(outS, 0.0f)

    var audio = NodeAudioPorts()
    audio.inputCount = 3
    audio.inputs[0] = addr bufA
    audio.inputs[1] = addr bufB          # 2-й вход не подключён (nil)
    audio.outputCount = 1
    audio.outputs[0] = addr bufO

    factory.process(addr ctx, addr audio, nil, nil, state)
    check abs(outS[0] - 0.15f) < 1.0e-4f
    check abs(outS[Block - 1] - 0.15f) < 1.0e-4f
    factory.destroy(state)

  test "отсутствие выходных данных не роняет ноду":
    let desc = getMixDesc()
    let factory = getMixFactory()
    let state = factory.create(desc, nil)
    var ctx = NodeProcessContext(sampleRate: Sr, blockSize: int32(Block))
    var audio = NodeAudioPorts()
    audio.inputCount = 0
    audio.outputCount = 0
    factory.process(addr ctx, addr audio, nil, nil, state)
    check true
    factory.destroy(state)

  test "каталог нод знает mix":
    check getMixDesc().audioInCount >= 4
    check getMixDesc().audioOutCount == 1
    check getMixDesc().paramCount == 1
