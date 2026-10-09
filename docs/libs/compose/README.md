# libs/compose — как писать музыку кодом

`libs/compose` — наша библиотека «композиция как код» (#285, #300). Ею пьеса
описывается на Nim, а на выход идут партитуры (`.notes`), проект (`.eproj`),
MIDI (`.mid`) и звук (`.wav`) — без Editor и без внешних скриптов.

Библиотека двухуровневая:

- **музыкальный слой** — время (`4.bars`), секции формы (`intro`/`verse`/
  `drop`), гармония (`progression(@"Am F C G")`), лады (`minorScale("A")`),
  мелодия поверх аккордов (`chordTone`/`degree`/`stack`), паттерны и ритмы
  (`trapKit`/`fill`/`swing`), вариации темы, детерминированный RNG. Им пьеса
  пишется как партитура;
- **низкий слой** — `score` (события/такты/мотивы), `song` (раскладка и
  проект Core), `builder` (произвольный граф). Он остаётся низкоуровневым:
  музыкальная семантика живёт **выше** (#COMPOSE-045).

Документация разбита на части:

- **этот файл** — как писать (быстрый старт, музыкальный слой, примеры, команды);
- **[instruments.md](instruments.md)** — все инструменты и ноды «из коробки» с
  параметрами, диапазонами и значениями по умолчанию;
- `compositions/neon-pulse/` — живой пример: современный трэп-бит целиком на
  музыкальном слое (форма, гармония, филлы, вариации, экспорт).

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

arr.writeNotes(here)                        # *.notes (человекочитаемо)
arr.writeProject(here / "song.eproj")       # проект
discard arr.render(here / "song.wav")       # звук
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

Модули библиотеки (каждый можно брать отдельно; `compose/compose` собирает
музыкальный слой в один импорт):

| модуль | что делает |
|---|---|
| `compose/time` | музыкальное время: `4.bars`, `barAt`, `secondsAt`, тики ядра |
| `compose/score` | модель: события, такты, мотивы; нотация и `NoteFormat` |
| `compose/scale` | лады и ступени: `minorScale("A")`, `degree(1..7)` |
| `compose/harmony` | аккорды и прогрессии: `chord("Am")`, `progression(...)` |
| `compose/melody` | мелодия поверх гармонии: `chordTone`, `degree`, `stack` |
| `compose/pattern` | ритмические фигуры: `repeat`, `overlay`, `swing`, `humanize` |
| `compose/rhythm` | сетки: `quarter`, `tresillo`, `clave`, `rhythm("x . x .")` |
| `compose/random` | детерминированный RNG: `musicRandom(seed)` |
| `compose/form` | секции песни: intro/verse/chorus/drop/outro |
| `compose/variation` | развитие мотива: инверсия, ретроград, фрагмент, регистр |
| `compose/arrangement` | пьеса: `play`/`during`/`harmony`/`build`/`toArrangement` |
| `compose/generators/drums` | киты и филлы: `trapKit`, `backbeatSnare`, `fill` |
| `compose/song` | раскладка: «инструмент + партия», запись `.eproj`/`.notes` |
| `compose/engine` | рендер проекта в WAV (`loadScene` + `renderToWav`) |
| `compose/midi` | Standard MIDI File: `writeMidi`, `writeMidiTracks` |
| `compose/builder` | низкоуровневая сборка **произвольного** графа |
| `compose/progress` | индикатор прогресса рендера для stderr |

Поток данных: **музыкальный слой → `Piece` → `build`/`toArrangement` →
раскладка (`Arrangement`) → проект (`ProjectFormat`) → звук (WAV/MIDI)**.
`build` даёт абсолютные ноты ещё до сборки проекта — удобно для проверок и
для будущего Compose Compiler (#COMPOSE-046/047).

## Музыкальный слой

### Время и форма

```nim
import compose/compose

var song = piece("Dark Trap", 140.0)     # темп и размер — свойства пьесы
discard song.section("intro", 8.bars)    # такты считает библиотека
discard song.section("verse", 16.bars)
discard song.section("chorus", 8.bars)
discard song.section("break", 4.bars)
discard song.section("drop", 8.bars)
discard song.section("outro", 4.bars)

song.find("chorus").startBar             # 24 — адресация по имени, не по числу
song.endBar                              # 48
```

`4.bars`, `2.beats`, `1.bar`, `0.5.beat` — DSL времени; позиции —
`barAt(8)`, `beatsAt(32)`, `secondsAt(9.0, 60.0)`. Разрешение — то же, что в
ядре (`PpqTicksPerQuarter`), собственного транспорта у Compose нет.

### Гармония и лад

```nim
let prog = progression(@["Am", "F", "C", "G"])   # аккорд на такт
let key = minorScale("A")
song.harmony(prog, key)

chord("G7").notes()        # @[67, 71, 74, 77]
prog.chordAt(5).root       # аккорд пятого такта (с зацикливанием)
key.degree(3)              # ступень лада; сменишь key — мелодия переедет
```

### Мелодия поверх гармонии

Высоты не пишутся руками — они считаются при компиляции по текущему аккорду:

```nim
let theme = melody("theme",
  degree(1, 1.0),        # ступень лада (тоника A)
  degree(5, 0.5),        # квинта
  chordTone(2, 0.5),     # терция текущего аккорда
  chordTone(1, 2.0))     # корень аккорда

let bass = melody("bass",
  chordTone(1, 1.5), rest(0.5), chordTone(1, 1.0), rest(0.5),
  chordTone(1, 0.5)).transpose(-24)   # та же логика, но басом

let pad = melody("pad", stack([1, 3, 5], 4.0))  # трезвучие на такт
```

Ещё роли шагов: `passingTone`, `approachTone`, `rest`. `chordTone(n)` — n-я
нота аккорда (1 корень, 2 терция, 3 квинта, 4 септима); `stack([1,3,5])`
берёт теоретические ступени.

### Паттерны, ритмы, грув

```nim
let hats = rhythm("x . x . | . x . x")     # сетка из символов (x — удар)
let fig  = tresillo().toPattern(Kick)      # готовая латинская фигура

let bass = pattern("bass", n(45, 0.5), r(0.5), n(45, 0.5), n(48, 0.5))
bass.repeat(4)                  # разворот нот (compile-time)
bass.transpose(5).reverse()     # приёмы развития
bass.overlay(other)             # слои: одновременные ноты → аккорд
bar1 & bar2                     # склейка фигур подряд
bass.swing(1.0'f32)             # свинг слабых долей (триольный feel)
bass.humanize(0.01, 8, seed = 42)          # «живость»: время + velocity
bass.groove(0.54, seed = 42)               # свинг + гуманизация
```

Ритмические фигуры: `quarter`, `eighth`, `sixteenth`, `triplet`, `dotted`,
`offbeat`, `tresillo`, `clave`, `trap16`. Барабаны: `kick`, `snare`, `hats`,
`clap`, `backbeatSnare`, `trapKick`, `trapHats`, `trapKit`, `boomBapKit`,
`fill(seed)`, `roll`, `rollTo`.

### Размещение по секциям

```nim
discard song.play("drums", trapKit(seed = 7), roleDrums,
                  nodeType = "euterpia.drums").during("verse", "chorus")
discard song.play("bass", bass, roleBass, nodeType = "euterpia.organ")
              .during("verse", "chorus", "drop")
discard song.play("bell", theme, roleLead, nodeType = "euterpia.bell")
              .during("intro")
discard song.play("bell", theme, roleLead).during("chorus").variant(1)

discard song.setParam("bass", "level", -8.0'f32)
```

- голос создаётся при первом `play` (`nodeType` — тип ноды, роль —
  `TrackRole`); `during` адресует секции, `also` добавляет, `variant(k)` даёт
  независимую вариацию темы для секции (#COMPOSE-033);
- **хард-кат** получается сам: секция, которую голос «не упомянул», — тишина
  (так делается break перед дропом, #COMPOSE-013);
- мелодия внутри секции реплицируется такт за тактом и **каждый раз
  рендерится по аккорду своего такта** — бас идёт по прогрессии сам.

Голоса можно собирать и вручную (`voice(...)` + `v.play(...)` + `c.add v`) —
тогда доступно несколько размещений на голос.

### Детерминизм

```nim
var rng = musicRandom(12345)     # splitmix64: один seed — одна музыка
rng.randomChoice(@["Am", "F"])   # ровно та же нота при каждом запуске
```

`humanize`, `fill`, `rollTo` принимают seed и воспроизводимы; `build`
дважды даёт идентичные ноты (тест `Compose determinism`).

## Алгоритм написания (по шагам)

1. **Форма.** `piece("Name", bpm)` + `section("verse", 16.bars)` — секции идут
   подряд, такты считает библиотека.
2. **Гармония.** `progression(@["Am", "F", "C", "G"])` + `minorScale("A")`;
   `song.harmony(prog, key)` — по ней будут рендериться мелодии.
3. **Партии.** Мелодии — `melody("theme", chordTone(1), degree(5), …)`;
   ритмические фигуры — `pattern(...)` из `n`/`ch`/`r` или готовых ритмов
   (`trapKit`, `tresillo`, `fill`).
4. **Развитие.** `repeat`/`transpose`/`reverse`/`overlay`/`swing`/`humanize` на
   паттернах; `variant(k)` — независимые вариации темы по секциям.
5. **Адресация.** `song.play("bell", theme, roleLead).during("intro")` — кто,
   что и когда; молчащие секции дают хард-каты.
6. **Сборка и звук.** `song.build()` (проверить ноты) → `song.toArrangement()`
   → `writeNotes` → `writeProject` → `writeMidi` → `render`.
7. **Проверка.** `validate(arr)` — до сборки; `euterpia analyze song.wav` —
   инспектор (#290) найдёт клиппинг, щелчки, жужжание и т.п.

## Низкий уровень: score, song, builder

Музыкальный слой компилируется в те же низкоуровневые типы, что были раньше:
`Part` (такты), `Arrangement` (партии + инструменты), `ProjectFormat` (проект
Core). Поэтому низкий уровень всегда доступен — для нестандартной маршрутизации
или полного контроля над тактами.

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

Музыкальный слой делает это одной командой: секции — по именам, гармония —
прогрессией, а `chordAt(bar)`/`notesAt(bar)` доступны мелодиям и генераторам.

```nim
var song = piece("Neon Pulse", 140.0)
discard song.section("intro", 8.bars)
discard song.section("verse", 16.bars)
discard song.section("drop", 8.bars)

let prog = progression(@["Am", "F", "C", "G"])   # 4-тактовый оборот
discard song.harmony(prog, minorScale("A"))

prog.notesAt(0)      # @[69, 72, 76] — ноты Am
prog.rootAt(1)       # 65 — корень F (для баса)
```

Низкий слой никуда не делся — если нужен полный контроль, гармония пишется
тактами вручную (см. раздел «Низкий уровень»).

## Партии и инструменты (пример)

На музыкальном слое партия — это размещение мелодии/паттерна по секциям:

```nim
let pad = melody("pad", stack([1, 3, 5], 4.0))       # трезвучие на такт
discard song.play("pad", pad, rolePad, nodeType = "euterpia.strings")
              .during("intro", "chorus", "outro")
discard song.setParam("pad", "level", -13.0'f32)
```

Вручную дорожка собирается через `instrument(...)` + `arr.add(inst, part)`
(раздел «Низкий уровень»): оба пути дают один и тот же `Arrangement`.

Идентификаторы нод «из коробки» — **все 28** (10 DSP-нод, 17 инструментов
и нотный секвенсор):

- инструменты: `euterpia.organ`, `euterpia.piano`, `euterpia.guitar`,
  `euterpia.drums`, `euterpia.flute`, `euterpia.bagpipe`, `euterpia.strings`,
  `euterpia.bell`, `euterpia.harp`, `euterpia.harpsichord`,
  `euterpia.recorder`, `euterpia.brass`, `euterpia.timpani`, `euterpia.choir`,
  `euterpia.ukulele`, `euterpia.accordion`, `euterpia.harmonica`;
- обработка и суммирование: `euterpia.input`, `euterpia.gain`,
  `euterpia.pan`, `euterpia.mix`, `euterpia.biquad`, `euterpia.svf`,
  `euterpia.delay`, `euterpia.compressor`, `euterpia.osc`, `euterpia.noise`;
- ноты: `euterpia.notes`.

Полный список с параметрами, диапазонами и умолчаниями — в
**[instruments.md](instruments.md)**; список проверяется тестом, поэтому
новый инструмент не может остаться незадокументированным (#309).

## Развитие материала

Два уровня: приёмы над `Motif` (низкий) и над `Pattern` (музыкальный слой).

```nim
let theme = motif(@[ bar(n(62, 1), n(64, 1), n(65, 2)) ])

theme.transpose(12)          # на октаву выше (кульминация)
theme.augment(2.0)           # длительности ×2 (увеличение)
cycle(theme, 16)             # повторить мотив до 16 тактов
bar(n(62, 4)).sameVel(110)   # такт с другой velocity

# Приёмы развития (compose/variation), чистые функции над Motif:
theme.invert()               # зеркало интервалов (вопрос/ответ)
theme.retrograde()           # такты задом наперёд
theme.fragment(0, 1)         # обрывок темы
theme.register(48)           # привести фразу к целевому регистру
theme.diminish(2.0)          # сжать ритм

# Пресеты вариантов по секциям — коротким номером:
song.play("bell", tune).during("chorus").variant(1)   # кварта вверх
```

## Ударные (грув и «разгон»)

Ритм пишется фигурами (`compose/rhythm`) и барабанными генераторами
(`compose/generators/drums`) — GM-ноты подставляются сами:

```nim
let kit = trapKit(seed = 7).humanize(0.01, 10, 7)   # кик + бэкбит + хэты
let bar = (kit.repeat(3) & fill(seed = 20)).repeat(4)  # 3 такта + филл

# одиночные слои, если нужен полный контроль:
kick(tresillo())          # бочка по фигуре
backbeatSnare()           # малый на 2 и 4 (готовая связка)
hats(sixteenth())         # ровные шестнадцатые

# переход в дроп: три такта тишины + ролл-разгон
let roll = @[r(12.0)] & rollTo(Snare, HiMidTom, 16).events
```

Ноты ударных — по GM-карте: 36 бочка, 38 малый, 42 закрытый хэт, 46 открытый
хэт, 49 crash, 51 ride, 41/43/45/48 томы (константы `Kick`…`Ride` в
`compose/generators/drums`).

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
b.writeProject("fx.eproj")
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

Готовые примеры:

- `compositions/neon-pulse/generate.nim` — современный трэп-бит на
  музыкальном слое (форма, гармония, филлы, вариации, экспорт всего разом);
- `compositions/neo-romantic/generate.nim` и
  `compositions/dark-fantasy/generate.nim` — пьесы на низком слое;
- задача `nimble compose` собирает одну из пьес целиком.

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
превращает раскладку в Standard MIDI File тем же путём, что и `.eproj`
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
euterpia midi ensemble.eproj                          # рядом появится ensemble.mid
euterpia midi ensemble.eproj --out build/song.mid     # один файл
euterpia midi ensemble.eproj --split build/midi       # по файлу на инструмент
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
- **Чем `melody` отличается от `pattern`?** `pattern` — фиксированные высоты
  (ритм инструмента), `melody` — ступени и аккордовые тоны, которые считаются
  при компиляции поверх `harmony`. Бас/пад/арп удобнее мелодией: смена
  прогрессии переписывает их сама.
- **Где вариации темы?** `.variant(k)` на размещении (`play(...).during(...)`)
  или `compose/variation` напрямую (`invert`, `retrograde`, `fragment`, …).
- **Как получить один и тот же трек дважды?** Все генераторы принимают seed
  (`humanize(..., seed)`, `fill(seed)`, `musicRandom(seed)`); `build()` без
  seed'ов пересобирается нота-в-ноту.
- **Длинная нота за границей такта?** Не нужно: паттерн кладётся по тактам, а
  такт всегда дополняется до сетки (`beatsPerBar`) — дрейфа нот нет.
- **Сколько тактов в пьесе?** `song.endBar` — сумма секций; клип каждой дорожки
  в проекте покрывает всю форму, поэтому абсолютные `startTick` совпадают с
  `build()`.

