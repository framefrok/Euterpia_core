# aligned_mem.nim
#
# Назначение:
#   - shared-память, выровненная сильнее, чем даёт аллокатор по умолчанию;
#   - один код выравнивания на всё ядро (пулы `memory_pool`, арены компилятора);
#   - явная пара alloc/free: `alignedSharedDealloc` принимает ровно то, что
#     вернул `alignedSharedAlloc0`.
#
# Почему одного `allocShared0` мало:
#   Nim гарантирует выравнивание по `MemAlign` (16 байт). Типы ядра просят
#   больше: у `EventQueue` поле `events` помечено `{.align: 64.}` — строка
#   кэша, чтобы события блока не делили её с чужими данными. Пока память
#   выдаёт аллокатор Nim'а целыми страницами, 64 байта получаются «сами
#   собой», и ошибку не видно. С `-d:useMalloc` (санитайзер-цели #364,
#   встраивание #213) память идёт из libc `malloc` с выравниванием 16 байт —
#   и обращение к полю становится UB:
#
#   ```
#   runtime error: member access within misaligned address 0x… for type
#   'struct tyObject_EventQueue…', which requires 64 byte alignment
#   ```
#
#   Поэтому выравнивание — обязанность вызывающего, а не удача аллокатора.
#
# Устройство (как в пулах, issue #57/#80):
#
#   [сырой указатель][padding][выровненная область ...]
#
# Заголовок лежит на `sizeof(pointer)` байт перед выровненным адресом, поэтому
# он всегда внутри выделенного блока, а освобождение возвращает аллокатору
# ровно `allocShared0`-указатель.

{.push raises: [].}

const
  DefaultSharedAlignment* = 64
    ## Строка кэша: столько просят типы ядра (`{.align: 64.}`) и пулы
    ## (`PoolAlignment`).

proc isPowerOfTwoShared(x: int): bool {.inline.} =
  x > 0 and (x and (x - 1)) == 0

proc alignmentPad(raw, header: uint; alignment: uint): uint {.inline.} =
  ## Сколько байт прибавить к `raw`, чтобы после заголовка получить адрес,
  ## кратный `alignment`.
  let base = raw + header
  let misalign = base and (alignment - 1)
  if misalign == 0'u: 0'u else: alignment - misalign

proc isAlignedShared*(p: pointer; alignment: int = DefaultSharedAlignment): bool =
  ## Выровнен ли адрес по `alignment`.
  ##
  ## Нужен тестам и дешёвым проверкам на холодной стороне — там, где ошибка
  ## выравнивания ещё не UB, а просто неверный указатель.
  if p == nil or not isPowerOfTwoShared(alignment):
    return false
  (cast[uint](p) and uint(alignment - 1)) == 0'u

proc alignedSharedAlloc0*(size: int;
                          alignment: int = DefaultSharedAlignment): pointer =
  ## Shared-память под `size` байт, выровненная по `alignment` и обнулённая.
  ##
  ## Возвращает nil, если `size <= 0`, `alignment` не степень двойки или
  ## память не выделилась. Освобождать — только `alignedSharedDealloc`.
  if size <= 0 or not isPowerOfTwoShared(alignment):
    return nil

  let header = uint(sizeof(pointer))
  let total = uint(size) + uint(alignment) + header

  if total > uint(high(int)):
    return nil

  let raw = allocShared0(int(total))
  if raw == nil:
    return nil

  let rawAddr = cast[uint](raw)
  # Заголовок лежит сразу перед выровненной областью: alignedAddr - header == raw + pad.
  let alignedAddr = rawAddr + header + alignmentPad(rawAddr, header, uint(alignment))

  cast[ptr pointer](alignedAddr - header)[] = raw

  return cast[pointer](alignedAddr)

proc alignedSharedDealloc*(p: pointer) =
  ## Освобождает ровно то, что вернул `alignedSharedAlloc0`.
  ##
  ## Принимает ТОЛЬКО результат `alignedSharedAlloc0`: заголовок с сырым
  ## указателем лежит на `sizeof(pointer)` байт перед `p`. Чужой указатель
  ## вернёт мусорный заголовок — это UB. Дешёвая проверка (issue #80) ловит
  ## только пустой заголовок, то есть «освобождать нечего» (`nil` или уже
  ## обнулённый блок).
  if p == nil:
    return

  let header = uint(sizeof(pointer))
  let headerPtr = cast[ptr pointer](cast[uint](p) - header)
  if headerPtr[] == nil:
    return
  deallocShared(headerPtr[])
