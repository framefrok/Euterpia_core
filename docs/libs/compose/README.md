# libs/compose — как писать музыку кодом

`libs/compose` — наша библиотека «композиция как код» (#285, #300). Ею пьеса
описывается на Nim, а на выход идут партитуры (`.notes`), проект (`.eut`) и
звук (`.wav`) — без Editor и без внешних скриптов.

Документация разбита на две части:

- **этот файл** — как писать (быстрый старт, шаги, примеры, команда компиляции);
- **[instruments.md](instruments.md)** — все инструменты и ноды «из коробки» с
  параметрами, диапазонами и значениями по умолчанию.

## Быстрый старт

Создайте файл `my_song.nim` в любом месте репозитория и запустите:

```nim
import std/os
import compose/score
import compose/song
import compose/engine

let here = parentDir(currentSourcePath())

var arr = arrangement("Моя пьеса", tempo = 96.0f32)

var piano = instrument("euterpia.piano", "Piano", "piano")
var p = part("piano")
p.add bar(90, n(60, 1), n(62, 1), n(64, 1), n(65, 1))
p.add bar(90, n(67, 2), n(65, 2))
arr.add(piano, p)

arr.writeNotes(here)                       # *.notes (человекочитаемо)
arr.writeProject(here / "song.eut")        # проект
discard arr.render(here / "song.wav")      # звук
```

**Команда компиляции и запуска** (из корня репозитория):

```bash
nim r my_song.nim
# или с указанием кэша, если генераторов несколько:
nim c -r --nimcache:build/nc_my_song --out:build/my_song my_song.nim
```

`nim r` компилирует и сразу запускает. Пути `compose/...` работают потому, что
`config.nims` в корне добавляет `libs/` в путь поиска (Nim находит `config.nims`
по родительским каталогам от файла).

## Как это устроено

Четыре модуля, каждый можно использовать отдельно:

| модуль | что делает |
|---|---|
| `compose/score` | музыкальная модель: события, такты, мотивы; вывод в нотацию и в ноты проекта |
| `compose/song` | высокая раскладка: «инструмент + партия», сумматор, запись `.eut`/`.notes` |
| `compose/engine` | рендер проекта в WAV (`loadScene` + `renderToWav`) |
| `compose/builder` | низкоуровневая сборка **произвольного** графа (нестандартные проекты) |

Поток данных: **мотив → партия → раскладка (`Arrangement`) → проект
(`ProjectFormat`) → звук (WAV)**.

## Алгоритм написания (по шагам)

1. **Форма.** Разбейте пьесу на разделы (например, Dawn → March → Charge →
   Finale) и решите, сколько тактов в каждом.
2. **Гармония.** Прогрессия — это список аккордов (нот) по тактам.
   `chordAt(bar)` возвращает ноты текущего такта.
3. **Мотивы.** Мелодия, марш, плач — это `Motif` (последовательность тактов).
   Такты строятся из `n` (нота), `ch` (аккорд), `r` (пауза).
4. **Развитие.** `transpose` (октава/полутоны), `augment` (увеличение),
   `cycle` (повтор до N тактов) — то, из чего делается форма.
5. **Партии и инструменты.** Для каждой партии — `instrument(...)`, параметры
   (`setParam`) и `arr.add(inst, part)`.
6. **Сборка и звук.** `writeNotes` → `writeProject` → `render`.
7. **Проверка.** `euterpia analyze song.wav` — инспектор (#290) найдёт клиппинг,
   щелчки, жужжание и т.п.

## Модель: ноты, такты, мотивы

```nim
# события
n(62, 1)              # нота (d4) длительностью 1 доля (четверть)
ch(@[62, 65, 69], 2)  # аккорд d-f-a длительностью 2 доли
r(1)                  # пауза 1 доля

# такт: события + velocity (1..127)
bar(100, n(62, 1), n(64, 1), n(65, 2))

# мотив: последовательность тактов
let theme = motif(@[
  bar(n(62, 2), n(64, 2)),
  bar(n(65, 3), r(1)),
])
```

Длительности — в **долях** (1 = четверть): `1`, `0.5` (восьмая), `0.25`
(шестнадцатая), `2`, `4`; точки — как `0.75` (восьмая с точкой), `1.5`, `3`.

## Гармония и форма (пример)

```nim
proc chord(name: string): seq[int] =
  case name
  of "Am": @[57, 60, 64]
  of "F":  @[53, 57, 60]
  of "C":  @[60, 64, 67]
  of "G":  @[55, 59, 62]
  else: @[57, 60, 64]

const SECTIONS = [("A", 1, 16), ("B", 17, 32)]

proc sectionOf(b: int): string =
  for s in SECTIONS:
    if b >= s[1] and b <= s[2]: return s[0]
  "A"

proc chordAt(b: int): seq[int] =
  chord(["Am", "F", "C", "G"][(b - 1) mod 4])   # 4-тактовый оборот
```

## Партии и инструменты (пример)

```nim
proc genOrgan(): Part =
  result = part("organ")
  for b in 1 .. 32:
    result.add bar(70, ch(chordAt(b), 4))       # целый аккорд на такт

var organ = instrument("euterpia.organ", "Organ", "organ")
organ.setParam("level", -6.0f32)
organ.setParam("bars", 0.6f32)
arr.add(organ, genOrgan())
```

Идентификаторы нод «из коробки»: `euterpia.organ`, `euterpia.piano`,
`euterpia.guitar`, `euterpia.drums`, `euterpia.flute`, `euterpia.bagpipe`,
`euterpia.mix`; полный список и параметры — в
**[instruments.md](instruments.md)**.

## Развитие материала

```nim
let theme = motif(@[ bar(n(62, 1), n(64, 1), n(65, 2)) ])

theme.transpose(12)          # на октаву выше (кульминация)
theme.augment(2.0)           # длительности ×2 (увеличение)
cycle(theme, 16)             # повторить мотив до 16 тактов
bar(n(62, 4)).sameVel(110)   # такт с другой velocity
```

## Ударные (грув и «разгон»)

```nim
proc genDrums(): Part =
  result = part("drums")
  for b in 1 .. 32:
    var evs: seq[NoteEvent]
    if b <= 16:                # восьмые: бочка/малый + хэт
      for nt in [@[36, 42], @[42], @[38, 42], @[42],
                 @[36, 42], @[42], @[38, 42], @[42]]:
        evs.add ch(nt, 0.5)
    else:                      # шестнадцатые: «ускорение»
      for i in 0 ..< 16:
        let nt = if i mod 4 == 0: @[36] elif i mod 4 == 2: @[38] else: @[42]
        evs.add ch(nt, 0.25)
    result.add bar(104, evs)
```

Ноты ударных — по GM-карте: 36 бочка, 38 малый, 42 закрытый хэт, 46 открытый
хэт, 49 crash, 51 ride, 41/43/45/48 томы.

## Произвольный граф (Builder)

Когда нужен не «набор партий + сумматор», а своя маршрутизация (эффекты, шины),
используйте `compose/builder`:

```nim
import compose/builder

var b = builder("FX chain", tempo = 120.0f32)
let notes = b.addNode("euterpia.notes", "notes")
let synth = b.addNode("euterpia.osc", "osc", [("freq", 220.0f32)])
let echo  = b.addNode("euterpia.delay", "delay", [("mix", 0.4f32)])
let mix   = b.addNode("euterpia.mix", "mix")
b.connect(notes, 0, synth, 0, pkEvent)   # события: ноты → осциллятор
b.connect(synth, 0, echo, 0, pkAudio)    # аудио: осц → delay
b.connect(echo, 0, mix, 0, pkAudio)      # delay → сумматор

var p = part("lead")
p.add bar(100, n(69, 1), n(72, 1), n(76, 2))
b.addTrack("lead", p)
b.writeProject("fx.eut")
```

Виды портов: `pkAudio`, `pkCtrl`, `pkEvent` (порядок совпадает с `SignalType`).
Проект из Builder рендерится через `renderProject(b.build(), "out.wav", tempo)`.

## Компиляция и проверка

```bash
nim r my_song.nim                    # генерация + рендер одной командой

# если генераторов несколько — раздельные кэши (иначе collide по имени)
nim c -r --nimcache:build/nc_my_song --out:build/my_song my_song.nim

build/euterpia analyze song.wav              # отчёт инспектора
build/euterpia analyze song.wav --json       # машинный отчёт
build/euterpia analyze song.wav --fail-on warn
```

Готовые примеры: `compositions/neo-romantic/generate.nim`,
`compositions/dark-fantasy/generate.nim`; задача `nimble compose` собирает одну
из пьес целиком.

## Частые вопросы

- **Откуда берётся `.notes`?** `arr.writeNotes(dir)` пишет партитуры в нотации
  ядра — их видно глазами и можно импортировать через `euterpia notation import`.
- **Почему микс клиппит?** Партии суммируются: держите запас,
  `arr.mixLevel = -8.0f32` (или уровни инструментов ниже).
- **Как добавить свой инструмент?** Так же, как встроенные: C-ядро в
  `nodes/builtin/csrc/eut_inst.c`, нода в `nodes/builtin/instruments/`,
  регистрация в `builtin_registry` (см. #274, #301).
- **Темп меняется по ходу пьесы?** Пока нет: rubato (карта темпа) — задача ядра
  #302. «Разгон» выражают плотностью (восьмые → шестнадцатые).

