# Neon Pulse — современный трэп-бит на libs/compose

Тёмный трэп 140 BPM (A minor), целиком описанный кодом: форма, гармония,
партии, филлы и гуманизация — а на выходе партитуры, проект, MIDI и звук.

```bash
nim r compositions/neon-pulse/generate.nim
```

Результат (пишется одной командой):

| файл | что это |
|---|---|
| `*.notes` (drums, bass, pad, bell, arp) | партитуры — нотация ядра, человекочитаема |
| `neon_pulse.eproj` | проект EUTERPIA (граф + секвенсор) |
| `neon_pulse.mid` | Standard MIDI File (формат 1) |
| `neon_pulse.wav` | рендер, ~84 c, 48 kHz стерео |

## Форма

```text
intro 8 → verse 16 → chorus 8 → break 4 → drop 8 → outro 4   (48 тактов)
```

- **break** — хард-кат (COMPOSE-013): ударные и бас молчат три такта,
  в последнем — ролл-разгон (`rollTo`) прямо в дроп;
- **вариации темы** (COMPOSE-033): chorus — вариант 1 (кварта вверх),
  drop — вариант 4 (инверсия-зеркало), outro — вариант 5 (ретрофраза).

## Гармония

```nim
let prog = progression(@["Am", "F", "C", "G"])
let key = minorScale("A")
song.harmony(prog, key)
```

Бас, пад, арп и колокольные метки — мелодии поверх этой гармонии: высоты
считаются при компиляции (`chordTone`/`degree`/`stack`), поэтому смена
прогрессии переписывает все партии разом.

## Дорожки

| голос | нода | роль | что играет |
|---|---|---|---|
| drums | `euterpia.drums` (пресет `trap_drums`) | roleDrums | хэты (intro), киты+филлы (verse/chorus), ролл (break), краш-дроп |
| bass | `euterpia.organ` (пресет `dark_bass`) | roleBass | корень аккорда −2 октавы, входит с verse |
| pad | `euterpia.strings` (пресет `warm_pad`) | rolePad | трезвучие по такту (intro/chorus/break/outro) |
| bell | `euterpia.bell` (пресет `dark_bell`) | roleLead | тема «вопрос–ответ» и её вариации |
| arp | `euterpia.piano` (пресет `clean_piano`) | roleArp | `bassLine(bsArp)` — арпеджио восьмыми (verse, drop) |

Тембры ставятся пресетами (`applyPreset`, COMPOSE-021), партии — генераторами
и мелодиями (`compose/generators/bass`, `compose/melody`), а форм-контроль —
`validate(song)` (замысел) + `validate(arr)` (раскладка). Оба валидатора в этом
примере молчат: проблем нет.

## Детерминизм

Все seed'ы: `humanize` хэтов, `fill(Seed + 13)`, `rollTo` — фиксированы константой
`Seed = 12345`. Один запуск — один бит; `tests/unit/test_compose_musical.nim`
(suite «Compose determinism») гарантирует, что одна и та же генерация даёт
идентичные ноты, тики и velocities.

## Проверка пика

```bash
python3 compositions/neon-pulse/tools/wav_peak.py \
        compositions/neon-pulse/neon_pulse.wav
```

Ожидается `clipped_samples=0` (сейчас peak ≈ −2.3 dBFS: `arr.mixLevel = -6`).

## Что печатает скрипт

- `song.build()` — число нот (та же компиляция, что уходит в клипы Core);
- `analyze(song)` — отчёт (COMPOSE-031): темп, тональность, длина, секции,
  дорожки с ролями и числом нот, плотность, смены гармонии, автоматизация;
- `song.resolve()` — сводка Composition IR (COMPOSE-046/047): сколько тактов,
  дорожек, нот и дорожек автоматизации решено до сборки проекта;
- `validate(song)` и `validate(arr)` — музыкальная и техническая проверки
  (в этом примере обе молчат);
- прогресс рендера — индикатор `compose/progress` в stderr.

## Проверка уровней

`arr.mixLevel = -7.5` плюс автоматизация сумматора (рамп −9.5 → −7.5 к дропу)
дают запас: пик ≈ −2.5 dBFS, клиппинга нет.
