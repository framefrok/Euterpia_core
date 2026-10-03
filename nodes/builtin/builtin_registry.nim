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
  io/input,
  generators/oscillator,
  generators/noise,
  filters/biquad,
  filters/svf,
  mixing/gain,
  mixing/pan,
  mixing/mix,
  dynamics/compressor,
  effects/delay,
  instruments/organ,
  instruments/piano,
  instruments/guitar,
  instruments/drums,
  sequencer/notes

type
  BuiltinNodeId* = enum
    bnInput,
    bnOscillator, bnNoise,
    bnBiquad, bnSvf,
    bnGain, bnPan, bnMix,
    bnCompressor, bnDelay,
    bnOrgan, bnPiano, bnGuitar, bnDrums,
    bnNotes

  ## Порядок ниже совпадает с порядком нод в реестре и используется
  ## инструментами (CLI/Editor) для выборки по индексу.

const
  BuiltinCount* = int(BuiltinNodeId.high) + 1

const
  builtinIds*: array[BuiltinCount, BuiltinNodeId] = [
    bnInput,
    bnOscillator, bnNoise,
    bnBiquad, bnSvf,
    bnGain, bnPan, bnMix,
    bnCompressor, bnDelay,
    bnOrgan, bnPiano, bnGuitar, bnDrums,
    bnNotes
  ]

proc builtinDescriptor*(id: BuiltinNodeId): ptr NodeDesc {.inline.} =
  case id
  of bnInput:       getInputDesc()
  of bnOscillator:  getOscillatorDesc()
  of bnNoise:       getNoiseDesc()
  of bnBiquad:      getBiquadDesc()
  of bnSvf:         getSvfDesc()
  of bnGain:        getGainDesc()
  of bnPan:         getPanDesc()
  of bnMix:         getMixDesc()
  of bnCompressor:  getCompDesc()
  of bnDelay:       getDelayDesc()
  of bnOrgan:       getOrganDesc()
  of bnPiano:       getPianoDesc()
  of bnGuitar:      getGuitarDesc()
  of bnDrums:       getDrumsDesc()
  of bnNotes:       getNotesDesc()

proc builtinFactory*(id: BuiltinNodeId): ptr NodeFactory {.inline.} =
  case id
  of bnInput:       getInputFactory()
  of bnOscillator:  getOscillatorFactory()
  of bnNoise:       getNoiseFactory()
  of bnBiquad:      getBiquadFactory()
  of bnSvf:         getSvfFactory()
  of bnGain:        getGainFactory()
  of bnPan:         getPanFactory()
  of bnMix:         getMixFactory()
  of bnCompressor:  getCompFactory()
  of bnDelay:       getDelayFactory()
  of bnOrgan:       getOrganFactory()
  of bnPiano:       getPianoFactory()
  of bnGuitar:      getGuitarFactory()
  of bnDrums:       getDrumsFactory()
  of bnNotes:       getNotesFactory()

proc registerBuiltinNodes*(reg: var NodeRegistry): int =
  ## Регистрирует все builtin-ноды. Возвращает число зарегистрированных:
  ## расхождение с BuiltinCount означает, что список и реестр разошлись.
  var registered = 0
  for id in builtinIds:
    if reg.registerNodeType(builtinDescriptor(id), builtinFactory(id)):
      inc registered
  registered
