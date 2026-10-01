# nodes/builtin/builtin_registry.nim
#
# Список официальных нод EUTERPIA.
#
# Core о существовании этого списка не знает (MANIFEST §54): ядро
# работает с любым графом, который ему дали, а перечень нод — свойство
# верхнего слоя. Поэтому добавление новой ноды в ядро не требует
# изменений ни в Core, ни в формате проекта.
#
# Регистрация выполняется один раз при старте приложения и только на
# control plane.

import
  ../sdk/node_api,
  ../sdk/node_registry,
  generators/oscillator,
  generators/noise,
  filters/biquad,
  filters/svf,
  mixing/gain,
  mixing/pan,
  dynamics/compressor,
  effects/delay

type
  BuiltinNodeId* = enum
    bnOscillator, bnNoise,
    bnBiquad, bnSvf,
    bnGain, bnPan,
    bnCompressor, bnDelay

  ## Порядок ниже совпадает с порядком нод в реестре и используется
  ## инструментами (CLI/Editor) для выборки по индексу.

const
  BuiltinCount* = int(BuiltinNodeId.high) + 1

const
  builtinIds*: array[BuiltinCount, BuiltinNodeId] = [
    bnOscillator, bnNoise,
    bnBiquad, bnSvf,
    bnGain, bnPan,
    bnCompressor, bnDelay
  ]

proc builtinDescriptor*(id: BuiltinNodeId): ptr NodeDesc {.inline.} =
  case id
  of bnOscillator:  getOscillatorDesc()
  of bnNoise:       getNoiseDesc()
  of bnBiquad:      getBiquadDesc()
  of bnSvf:         getSvfDesc()
  of bnGain:        getGainDesc()
  of bnPan:         getPanDesc()
  of bnCompressor:  getCompDesc()
  of bnDelay:       getDelayDesc()

proc builtinFactory*(id: BuiltinNodeId): ptr NodeFactory {.inline.} =
  case id
  of bnOscillator:  getOscillatorFactory()
  of bnNoise:       getNoiseFactory()
  of bnBiquad:      getBiquadFactory()
  of bnSvf:         getSvfFactory()
  of bnGain:        getGainFactory()
  of bnPan:         getPanFactory()
  of bnCompressor:  getCompFactory()
  of bnDelay:       getDelayFactory()

proc registerBuiltinNodes*(reg: var NodeRegistry): int =
  ## Регистрирует все builtin-ноды. Возвращает число зарегистрированных:
  ## расхождение с BuiltinCount означает, что список и реестр разошлись.
  var registered = 0
  for id in builtinIds:
    if reg.registerNodeType(builtinDescriptor(id), builtinFactory(id)):
      inc registered
  registered
