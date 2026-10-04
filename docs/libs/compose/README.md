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
import compose/compose   # score + song + engine + progress одной строкой

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

**Прогресс рендера.** Часовая пьеса считается за пару минут, и без
обратной связи «идёт быстро» и «зависло» выглядят одинаково. Поэтому
`arr.render(...)` сам показывает в stderr индикатор, если stderr — терминал:

```text
⠸ рендер 98% · 59:27 / 59:55 · прошло 2:03 · осталось 0:01 · ×28.9
```

В пайпе и CI он молчит (вывод остаётся детерминированным), а свой
колбэк можно передать последним аргументом:

```nim
discard arr.render(here / "song.wav",
                   onProgress = callback(myProgress))
```

Формат тот же, что у `euterpia render`: одна реализация
(`compose/progress`) вместо двух почти одинаковых.

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
| `compose/progress` | индикатор прогресса рендера для stderr (тот же, что в CLI) |

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

Идентификаторы нод «из коробки» — **все 25** (10 DSP-нод, 14 инструментов
и нотный секвенсор):

- инструменты: `euterpia.organ`, `euterpia.piano`, `euterpia.guitar`,
  `euterpia.drums`, `euterpia.flute`, `euterpia.bagpipe`, `euterpia.strings`,
  `euterpia.bell`, `euterpia.harp`, `euterpia.harpsichord`,
  `euterpia.recorder`, `euterpia.brass`, `euterpia.timpani`, `euterpia.choir`;
- обработка и суммирование: `euterpia.input`, `euterpia.gain`,
  `euterpia.pan`, `euterpia.mix`, `euterpia.biquad`, `euterpia.svf`,
  `euterpia.delay`, `euterpia.compressor`, `euterpia.osc`, `euterpia.noise`;
- ноты: `euterpia.notes`.

Полный список с параметрами, диапазонами и умолчаниями — в
**[instruments.md](instruments.md)**; список проверяется тестом, поэтому
новый инструмент не может остаться незадокументированным (#309).

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

## Ошибки и предупреждения

Пьеса проверяется **до** сборки проекта, и ошибки называют, что делать
(issue #311):

```nim
var i = instrument("euterpia.kazoo", "K", "k")   # такого типа нет
i.setParam("blabla", 1.0)                        # такого параметра нет
```

```text
compose: партия 0 («k»): ошибка: неизвестный тип ноды: euterpia.kazoo
       доступные типы: euterpia.bagpipe, euterpia.bell, …
compose: пьеса не собрана, проблем: 1
ok=false
```

Правила:

| текст | что значит | что делать |
|---|---|---|
| `ошибка: неизвестный тип ноды` | нет такого `euterpia.*` | сверить имя со списком в сообщении или с [instruments.md](instruments.md) |
| `ошибка: у ноды … нет параметра` | опечатка в `setParam` | имя из списка «допустимые параметры» |
| `ошибка: имя ноды … уже занято` | две партии с одним именем | имена нод уникальны |
| `внимание: партия без тактов` | партия пустая, будет тишина | добавить такты или убрать партию |
| `внимание: в раскладке нет ни одной партии` | проект пустой | добавить `arr.add(...)` |

- **Ошибка** останавливает сборку: проект не пишется, `render` возвращает
  `ok = false` и текст в `rr.error`. Раньше неизвестный тип ронял скрипт
  `AssertionDefect` со стектреймом, а опечатка в параметре **терялась
  молча** — рендер был «успешным», а музыка звучала не так.
- **Предупреждение** не мешает: печатается в stderr и попадает в
  `rr.warnings`.
- Проверить раскладку самому, не рендеря:

```nim
for problem in validate(arr):
  echo problem
```

- Свой файловый/проектный путь: `writeProjectChecked(arr, path, problems)`
  вернёт `false` и заполнит `problems`, не создав файл.

Забытый импорт — тоже частая причина «Error: attempting to call undeclared
routine: 'render'». Один импорт решает: `import compose/compose`.

## MIDI: проект в файл

Пьесу можно отдать наружу — в DAW, нотатор или секвенсор: `libs/compose/midi`
превращает раскладку в Standard MIDI File тем же путём, что и `.eut`
(через `buildProject`), поэтому MIDI и проект описывают **одну и ту же**
музыку.

```nim
import compose/midi

discard arr.writeMidi(here / "ensemble.mid")     # один файл (формат 1)
discard arr.writeMidiTracks(here / "midi")       # по файлу на инструмент
```

- **Один файл** — формат 1: первая дорожка-«дирижёр» (имя пьесы, темп,
  размер), дальше по дорожке на каждую партию. Так файл открывается в любом
  DAW с правильным темпом и подписанными дорожками.
- **Разбивка** — `writeMidiTracks(dir)`: по файлу на партию, формат 0, имя
  начинается с номера дорожки (`01_choir.mid`, `02_harp.mid`, …), поэтому
  порядок воспроизводится.

Из CLI то же самое, но для любого готового проекта:

```bash
euterpia midi ensemble.eut                            # рядом появится ensemble.mid
euterpia midi ensemble.eut --out build/song.mid       # один файл
euterpia midi ensemble.eut --split build/midi         # по файлу на инструмент
```

Что важно знать про перенос:

- **Тики не пересчитываются.** Разрешение проекта и SMF совпадают
  (`PpqTicksPerQuarter`), поэтому позиции нот в файле ровно те же.
- **Клипы раскрываются как в движке.** Note Off обрезается границей клипа;
  зацикленный клип повторяется до конца песни — то же правило, что в
  `core/sequencer`.
- **Каналы сохраняются** (`toNotes` даёт каждому треку свой канал).
- Пустые дорожки в файл не попадают: тишина ничего не сообщает.
- Обратно прочитать файл можно тем же кодеком: `commons/midi_io.parseSmf`.

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

