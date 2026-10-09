# libs/compose/random.nim
#
# Детерминированный RNG для генеративной музыки (issue #COMPOSE-015).
#
# Зачем: `std/random` рандомизирует зерно при каждом запуске — значит
# «seed 123 → один и тот же трек» невозможен, баг невоспроизводим, а
# `euterpia generate song.nim --seed 123` бессмысленно. Здесь свой
# детерминированный генератор (splitmix64): одна последовательность из одного
# seed, стабильная между запусками и платформами — фундамент для
# воспроизводимой генерации (#COMPOSE-018/019/032/041).
#
# Никакого состояния кроме `state`, никакого глобального RNG: каждый вызывающий
# держит свою цепочку (`musicRandom(seed)`), поэтому перегенерация одной части
# не трогает остальные (#COMPOSE-032/039 — раздельные seed'ы).

{.push raises: [].}

type
  MusicRandom* = object
    ## Детерминированный генератор. Один seed → одна и та же последовательность
    ## чисел всегда и везде (splitmix64 — стандартная схема без ветвлений).
    state*: uint64

proc musicRandom*(seed: int): MusicRandom =
  ## Генератор из seed: `musicRandom(12345)`. Ноль seed — законный (не
  ## «случайный»): всегда одна и та же последовательность.
  # Начальное смешивание, чтобы seed'ы 0/1/2 не отличались на бите младшего
  # разряда (у splitmix64 слабые входы подряд).
  MusicRandom(state: uint64(seed) * 0x9E3779B97F4A7C15'u64 +
                      0x853C49E6748FEA9B'u64)

proc nextUint*(r: var MusicRandom): uint64 =
  ## Следующее 64-битное число (splitmix64).
  r.state += 0x9E3779B97F4A7C15'u64
  var z = r.state
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc nextFloat*(r: var MusicRandom): float =
  ## Число в [0, 1) с точностью 24 бита (достаточно для музыки).
  float(r.nextUint() shr 40) / float(1'u64 shl 24)

proc randInt*(r: var MusicRandom; lo, hi: int): int =
  ## Целое в [lo, hi] (включительно). При hi < lo возвращается lo.
  if hi <= lo:
    return lo
  let span = uint64(hi - lo + 1)
  lo + int(r.nextUint() mod span)

proc randomChoice*[T](r: var MusicRandom; items: openArray[T]): T =
  ## Случайный элемент списка: `rng.randomChoice(@["Am", "F", "G"])`.
  ## Пустой список — `default(T)` (не падаем: генератор не должен ронять
  ## композицию из-за пустого набора).
  if items.len == 0:
    return default(T)
  items[r.randInt(0, items.len - 1)]

proc randomVelocity*(r: var MusicRandom; base: int = 100;
                     spread: int = 16): int =
  ## Velocity около `base` ± `spread`, всегда в легальном диапазоне 1..127.
  max(1, min(127, base + r.randInt(-spread, spread)))

proc randomOctave*(r: var MusicRandom; center: int = 60;
                   octaves: int = 1): int =
  ## Питч в пределах ±`octaves` октав от `center` (равномерно).
  center + r.randInt(-12 * octaves, 12 * octaves)

proc randomDuration*(r: var MusicRandom;
                     allowed: openArray[float] = [1.0, 0.5, 0.5, 0.25]): float =
  ## Одна из разрешённых длительностей (по умолчанию — четверть/восьмая/
  ## шестнадцатая с весами в пользу коротких).
  r.randomChoice(allowed)

proc randomRhythm*(r: var MusicRandom; steps: int; density: float = 0.5;
                   stepBeats: float = 0.25): seq[bool] =
  ## Ритмическая сетка `steps` шагов: удар с вероятностью `density`
  ## (0..1). Результат детерминирован по seed — из него строится `Rhythm`
  ## (`compose/rhythm`) или список акцентов.
  for _ in 0 ..< max(0, steps):
    result.add r.nextFloat() < density

proc shuffle*[T](r: var MusicRandom; items: var seq[T]) =
  ## Перемешать на месте (Fisher–Yates на своём RNG).
  if items.len < 2:
    return
  for i in countdown(items.len - 1, 1):
    let j = r.randInt(0, i)
    swap items[i], items[j]

{.pop.}
