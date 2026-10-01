# param_registry.nim
#
# ВНИМАНИЕ ПО ПОТОКОБЕЗОПАСНОСТИ И REAL-TIME АРХИТЕКТУРЕ:
# 1. ParamRegistry предназначен ИСКЛЮЧИТЕЛЬНО для Control Thread (UI, Worker, Setup).
#    Внутреннее состояние защищено мьютексом `lock` от гонок данных между управляющими потоками.
# 2. Аудиопоток реального времени (RT Audio Thread) НИКОГДА не должен вызывать lookupParam,
#    bindParam или releaseParam, так как захват Lock, динамические аллокации и работа
#    с хеш-таблицей приводят к инверсии приоритетов и выпадению аудио (xrun).
# 3. В RT-контекст передается предвыделенный плоский массив/буфер ParamSlotRT,
#    доступ к которому осуществляется напрямую по числовому индексу ParamBinding.slot.

import
  std/tables,
  std/hashes,
  std/locks,
  audio_params

type
  NodeId* = uint32
  ParamId* = uint32

  ParamKey = object
    nodeId: NodeId
    paramId: ParamId

  ParamRegistry* = object
    bindings: Table[ParamKey, ParamBinding]
    freeSlots: seq[uint32]
    generations: seq[ParamGeneration]
    nextSlot: uint32
    capacity: uint32
    lock: Lock


proc hash*(k: ParamKey): Hash {.raises: [], gcsafe.} =
  var h: Hash = 0
  h = h !& int(k.nodeId).hash
  h = h !& int(k.paramId).hash
  result = !$h


proc initParamRegistry*(
  capacity: uint32 = MaxParamSlots.uint32
): ParamRegistry =
  let cap =
    if capacity == 0:
      MaxParamSlots.uint32
    else:
      min(capacity, MaxParamSlots.uint32)

  result.capacity = cap
  result.bindings = initTable[ParamKey, ParamBinding]()
  result.freeSlots = @[]
  result.generations = newSeq[ParamGeneration](cap.int)
  result.nextSlot = 0
  initLock(result.lock)


proc deinitParamRegistry*(reg: var ParamRegistry) =
  deinitLock(reg.lock)


proc bindParam*(
  reg: var ParamRegistry;
  nodeId: NodeId;
  paramId: ParamId
): ParamBinding =
  acquire(reg.lock)
  try:
    let key = ParamKey(nodeId: nodeId, paramId: paramId)

    if reg.bindings.hasKey(key):
      return reg.bindings[key]

    var slot: uint32

    if reg.freeSlots.len > 0:
      slot = reg.freeSlots.pop()
    else:
      if reg.nextSlot >= reg.capacity:
        return ParamBinding(slot: InvalidParamSlot, generation: 0)

      slot = reg.nextSlot
      inc reg.nextSlot

    inc reg.generations[slot.int]

    result = ParamBinding(
      slot: slot,
      generation: reg.generations[slot.int]
    )

    reg.bindings[key] = result
  finally:
    release(reg.lock)


proc lookupParam*(
  reg: ptr ParamRegistry;
  nodeId: NodeId;
  paramId: ParamId;
  binding: var ParamBinding
): bool =
  if reg == nil:
    return false

  acquire(reg[].lock)
  try:
    let key = ParamKey(nodeId: nodeId, paramId: paramId)

    if reg[].bindings.hasKey(key):
      binding = reg[].bindings[key]
      true
    else:
      false
  finally:
    release(reg[].lock)


proc releaseParam*(
  reg: var ParamRegistry;
  nodeId: NodeId;
  paramId: ParamId
) =
  acquire(reg.lock)
  try:
    let key = ParamKey(nodeId: nodeId, paramId: paramId)

    if not reg.bindings.hasKey(key):
      return

    let b = reg.bindings[key]
    reg.bindings.del(key)

    if b.slot != InvalidParamSlot and b.slot < reg.capacity:
      reg.freeSlots.add(b.slot)
  finally:
    release(reg.lock)