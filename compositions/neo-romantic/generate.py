#!/usr/bin/env python3
# compositions/neo-romantic/generate.py
#
# Генератор партитуры «Neo-Romantic Ensemble» (issue #275).
#
# Пьеса — не случайные ноты, а заданная форма. Генератор держит её целиком:
# 64 такта 4/4 при 92 BPM (≈2:47), тональность ля минор с модальными
# отклонениями, пять разделов (интро, A, B, A′, кода) и четыре партии:
#
#   organ  — подложка-пэд (аккорды в целых),
#   piano  — арпеджио восьмыми,
#   guitar — мелодия (16-тактовый период) в A и A′, ответы в B,
#   drums  — грув по разделам.
#
# Выход — четыре файла нотации (формат ядра, `core/notation.nim`). Их
# импортирует CLI (`notation import`), поэтому музыка воспроизводима и
# собирается без Editor — как требует §19 MANIFEST.
#
# Длительности в долях (1 доля = четверть): 4 → /1, 2 → /2, 1 → /4,
# 0.5 → /8, 0.25 → /16; точки — через те же значения (3 → /2., 1.5 → /4.).

import os
import sys

OUT_DIR = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------------------
# Ноты
# ---------------------------------------------------------------------------

NAMES = ['c', 'c#', 'd', 'd#', 'e', 'f', 'f#', 'g', 'g#', 'a', 'a#', 'b']


def pname(midi):
    return NAMES[midi % 12] + str(midi // 12 - 1)


DUR = {
    4: '1', 3: '2.', 2: '2', 1.5: '4.', 1: '4', 0.75: '8.',
    0.5: '8', 0.375: '16.', 0.25: '16', 0.125: '32',
}


def token(item):
    """(midi | list[midi] | 'r', beats) -> строка нотации."""
    pitch, beats = item
    if beats not in DUR:
        raise ValueError(f"нет длительности для {beats} долей")
    suffix = '/' + DUR[beats]
    if pitch == 'r':
        return 'r' + suffix
    if isinstance(pitch, (list, tuple)):
        return '(' + ' '.join(pname(p) for p in pitch) + ')' + suffix
    return pname(pitch) + suffix


def bar(items, vel):
    toks = [token(i) for i in items]
    # velocity вешаем на первый НЕ-паузу элемент: так значение действует на
    # весь такт, а строка остаётся корректной (пауза с :V не нужна).
    target = 0
    for k, it in enumerate(items):
        if it[0] != 'r':
            target = k
            break
    toks[target] = toks[target] + ':%d' % vel
    return ' '.join(toks) + ' |'


# ---------------------------------------------------------------------------
# Гармония
# ---------------------------------------------------------------------------

# Четырёхтактовый оборот A/кода и оборот B (подъём).
PROG_A = [
    ('Am', [57, 60, 64]),
    ('F',  [53, 57, 60]),
    ('C',  [60, 64, 67]),
    ('G',  [55, 59, 62]),
]
PROG_B = [
    ('Dm', [62, 65, 69]),
    ('Bb', [58, 62, 65]),
    ('F',  [53, 57, 60]),
    ('C',  [60, 64, 67]),
]

# 64 такта: (номер раздела, диапазон 1-based, прогрессия).
SECTIONS = [
    ('intro', 1, 8,  PROG_A),
    ('A',     9, 24, PROG_A),
    ('B',     25, 40, PROG_B),
    ('A2',    41, 56, PROG_A),
    ('coda',  57, 64, PROG_A),
]


def chord_at(bar_no):
    for name, lo, hi, prog in SECTIONS:
        if lo <= bar_no <= hi:
            return prog[(bar_no - lo) % len(prog)]
    return PROG_A[0]


def section_of(bar_no):
    for name, lo, hi, _ in SECTIONS:
        if lo <= bar_no <= hi:
            return name
    return 'A'


def section_start(name):
    for n, lo, _, _ in SECTIONS:
        if n == name:
            return lo
    return 1


BARS = 64

# ---------------------------------------------------------------------------
# Мелодия (16-тактовый период, ля минор)
# ---------------------------------------------------------------------------

MELODY = [
    [(64, 0.5), (69, 0.5), (72, 1), (71, 0.5), (69, 0.5), (67, 1)],
    [(65, 1), (69, 0.5), (67, 0.5), (65, 0.5), (64, 0.5), (62, 1)],
    [(64, 0.5), (67, 0.5), (64, 1), (60, 1), (64, 1)],
    [(62, 2), (67, 1), ('r', 1)],
    [(69, 1), (72, 0.5), (71, 0.5), (69, 0.5), (67, 0.5), (69, 1)],
    [(65, 0.5), (69, 0.5), (72, 2), (71, 1)],
    [(67, 0.5), (64, 0.5), (60, 0.5), (64, 0.5), (67, 1), (64, 1)],
    [('r', 2), (62, 1), (64, 1)],
    [(64, 0.5), (69, 0.5), (72, 1), (74, 0.5), (72, 0.5), (71, 1)],
    [(69, 1), (67, 0.5), (65, 0.5), (64, 0.5), (62, 0.5), (64, 1)],
    [(67, 0.5), (72, 0.5), (67, 1), (64, 1), (60, 1)],
    [(62, 2), ('r', 2)],
    [(64, 1), (69, 1), (72, 0.5), (71, 0.5), (69, 0.5), (67, 0.5)],
    [(65, 0.5), (69, 0.5), (72, 1), (69, 1), (65, 1)],
    [(67, 1), (71, 1), (74, 1), (76, 1)],
    [(69, 3), ('r', 1)],
]

# Раздел B: гитара отвечает длинными нотами по гармонии.
B_MOTIF = [
    [(62, 2), (65, 2)],
    [(58, 4)],
    [(65, 2), (69, 2)],
    [(67, 3), ('r', 1)],
]

# ---------------------------------------------------------------------------
# Партии
# ---------------------------------------------------------------------------


def gen_organ():
    out = []
    for b in range(1, BARS + 1):
        _, tones = chord_at(b)
        vel = 60 if section_of(b) == 'intro' else 72
        out.append(bar([(list(tones), 4)], vel))
    return out


def gen_piano():
    out = []
    for b in range(1, BARS + 1):
        _, tones = chord_at(b)
        sec = section_of(b)
        if sec == 'intro' and b <= 4:
            out.append(bar([('r', 4)], 70))
            continue
        octave = tones[0] + 12
        pool = list(tones) + [octave]
        order = [0, 1, 2, 3, 2, 1, 0, 2]
        items = [([pool[order[k]]], 0.5) for k in range(8)]
        vel = 66 if sec == 'intro' else 80
        out.append(bar(items, vel))
    return out


def gen_guitar():
    out = []
    for b in range(1, BARS + 1):
        sec = section_of(b)
        if sec == 'intro':
            out.append(bar([('r', 4)], 90))
        elif sec in ('A', 'A2'):
            idx = (b - section_start(sec)) % len(MELODY)
            out.append(bar(MELODY[idx], 100))
        elif sec == 'B':
            idx = (b - section_start('B')) % len(B_MOTIF)
            out.append(bar(B_MOTIF[idx], 92))
        else:  # coda
            if b == section_start('coda'):
                out.append(bar([(69, 4)], 96))
            else:
                out.append(bar([('r', 4)], 90))
    return out


# Ударные: наборы нот на восьмые доли такта (GM: 36 kick, 38 snare,
# 42 закрытый хэт, 46 открытый хэт, 49/57 crash, 51 ride).
GROOVE_HAT = [
    [36, 42], [42], [38, 42], [42], [36, 42], [42], [38, 42], [42],
]
GROOVE_RIDE = [
    [36, 51], [51], [38, 51], [51], [36, 51], [51], [38, 51], [46],
]
CODA_SPARSE = [
    [36], None, [42], None, [36], None, [42, 38], None,
]


def dn(n):
    """Набор нот ударных на долю: одна нота — число, иначе список."""
    return n[0] if len(n) == 1 else list(n)


def gen_drums():
    out = []
    for b in range(1, BARS + 1):
        sec = section_of(b)
        if sec == 'intro':
            out.append(bar([('r', 4)], 100))
        elif sec == 'A':
            out.append(bar([(dn(n), 0.5) for n in GROOVE_HAT], 104))
        elif sec == 'B':
            out.append(bar([(dn(n), 0.5) for n in GROOVE_RIDE], 100))
        elif sec == 'A2':
            if b == section_start('A2'):
                pat = [[36, 49]] + GROOVE_RIDE[1:]
            else:
                pat = GROOVE_RIDE
            out.append(bar([(dn(n), 0.5) for n in pat], 104))
        else:  # coda
            if b == section_start('coda'):
                out.append(bar([([36, 49], 0.5), (49, 0.5), (42, 1),
                                (38, 1), (42, 1)], 108))
            elif b == BARS:
                out.append(bar([([36, 49], 4)], 110))
            else:
                rest_or = lambda n: ('r', 0.5) if n is None else (dn(n), 0.5)
                out.append(bar([rest_or(n) for n in CODA_SPARSE], 100))
    return out


def write_part(name, lines):
    path = os.path.join(OUT_DIR, name + '.notes')
    with open(path, 'w', encoding='utf-8') as f:
        f.write('# %s — Neo-Romantic Ensemble (generated)\n' % name)
        for i, line in enumerate(lines, start=1):
            f.write(line + '\n')
    print('wrote', path)


def main():
    write_part('organ', gen_organ())
    write_part('piano', gen_piano())
    write_part('guitar', gen_guitar())
    write_part('drums', gen_drums())


if __name__ == '__main__':
    sys.exit(main())

