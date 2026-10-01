# audio_params.nim

const
  MaxParamSlots* = 4096
  InvalidParamSlot* = uint32.high

type
  ParamGeneration* = uint32

  ParamSlotRT* = object
    target*: float32
    current*: float32
    smoothCoef*: float32
    generation*: ParamGeneration

  ParamBinding* = object
    slot*: uint32
    generation*: ParamGeneration


proc defaultParamSlot*(): ParamSlotRT {.inline.} =
  ParamSlotRT(
    target: 0.0f,
    current: 0.0f,
    smoothCoef: 1.0f,
    generation: 0
  )


proc isValid*(b: ParamBinding): bool {.inline.} =
  b.slot != InvalidParamSlot