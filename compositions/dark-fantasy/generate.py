#!/usr/bin/env python3
# compositions/dark-fantasy/generate.py
#
# «Cathedral of Ash» — симфоническая пьеса в жанре medieval dark fantasy
# (issue #295). Проект-витрина: показывает и звук инструментов, и CLI-сборку.
#
# Форма (76 тактов 4/4 при 76 BPM ≈ 4:00), ре минор с модальными красками
# (Aeolian + фригийская секунда Eb в катастрофе), органум-параллелизм
# (средневековая квинта/октава), церковные плагальные кадансы:
#
#   I.  Пролог      1–12   органный бурдон, хоральный напев (лютня)
#   II. Марш       13–32   боевые барабаны, маршевая тема, орган-хор
#   III. Плач      33–48   высокий печальный напев, редкие удары-«сердце»
#   IV. Катаклизм  49–64   напев в увеличении, полная звучность, татаны
#   V.  Эпилог     65–76   распад на бурдон, каданс в ре
#
# Партии: organ (соборный хор + бурдон), guitar (лютня, напевы),
# piano (арфа/колокольчики), drums (боевые барабаны, томы, тарелки).
#
# Всё детерминировано: форма, мотивы и развитие живут здесь, а `.notes`
# пишутся для CLI (`notation import`), как требует MANIFEST §19.

import os
import sys

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
BARS = 76

NAMES = ['c', 'c#', 'd', 'd#', 'e', 'f', 'f#', 'g', 'g#', 'a', 'a#', 'b']
DUR = {
    4: '1', 3: '2.', 2: '2', 1.5: '4.', 1: '4', 0.75: '8.', 0.5: '8',
    0.375: '16.', 0.25: '16', 0.125: '32',
}


def pname(midi):
    return NAMES[midi % 12] + str(midi // 12 - 1)


def token(item):
    pitch, beats = item
    if beats not in DUR:
        raise ValueError(f"нет длительности для {beats} долей")
    suffix = '/' + DUR[beats]
    if pitch == 'r':
        return 'r' + suffix
    if isinstance(pitch, (list, tuple)):
        return '(' + ' '.join(pname(p) for p in pitch) + ')' + suffix
    return pname(pitch) + suffix


def bar(items, vel_):
    toks = [token(i) for i in items]
    target = 0
    for k, it in enumerate(items):
        if it[0] != 'r':
            target = k
            break
    toks[target] = toks[target] + ':%d' % vel_
    return ' '.join(toks) + ' |'


def transpose(items, semis):
    out = []
    for pitch, beats in items:
        if pitch == 'r':
            out.append(('r', beats))
        elif isinstance(pitch, (list, tuple)):
            out.append(([p + semis for p in pitch], beats))
        else:
            out.append((pitch + semis, beats))
    return out


def augment(items, factor):
    """Растяжение длительностей (увеличение темы) — для кульминации."""
    return [(p, b * factor) for (p, b) in items]


# ---------------------------------------------------------------------------
# Гармония (модальный ре минор; A = мажорная доминанта как «тревога»)
# ---------------------------------------------------------------------------

CH = {
    'Dm': [50, 53, 57],   # ре-фа-ля
    'Bb': [46, 50, 53],   # си♭-ре-фа
    'F':  [53, 57, 60],   # фа-ля-до
    'Gm': [55, 58, 62],   # соль-си♭-ре
    'C':  [48, 52, 55],   # до-ми-соль
    'A':  [45, 49, 52],   # ля-до#-ми
    'Am': [45, 48, 52],   # ля-до-ми
    'Eb': [51, 55, 58],   # ми♭-соль-си♭ (фригийская краска)
}


def prog(names):
    return [(n, CH[n]) for n in names]


# Разделы: (имя, первый такт, последний такт, прогрессия по тактам).
SECTIONS = [
    ('prologue', 1, 12, prog(
        ['Dm', 'Dm', 'Bb', 'Dm', 'Dm', 'C', 'Dm', 'Dm', 'Bb', 'F', 'C', 'Dm'])),
    ('march', 13, 32, prog(
        ['Dm', 'Bb', 'C', 'Dm', 'Gm', 'Bb', 'C', 'A'])),
    ('lament', 33, 48, prog(
        ['Bb', 'F', 'Gm', 'Dm', 'Bb', 'C', 'Dm', 'Am'])),
    ('cataclysm', 49, 64, prog(
        ['Dm', 'Gm', 'Bb', 'C', 'Dm', 'Eb', 'Gm', 'A'])),
    ('epilogue', 65, 76, prog(
        ['Dm', 'Bb', 'Gm', 'Dm', 'Bb', 'C', 'Dm', 'Dm'])),
]


def section_of(b):
    for name, lo, hi, _ in SECTIONS:
        if lo <= b <= hi:
            return name
    return 'march'


def section_start(name):
    for n, lo, _, _ in SECTIONS:
        if n == name:
            return lo
    return 1


def chord_at(b):
    for name, lo, hi, pr in SECTIONS:
        if lo <= b <= hi:
            return pr[(b - lo) % len(pr)]
    return ('Dm', CH['Dm'])


# Динамика: пролог тихо, катаклизм — кульминация, эпилог затухает.
DYNAMICS = {
    'prologue': 0.80,
    'march': 1.00,
    'lament': 0.85,
    'cataclysm': 1.15,
    'epilogue': 0.75,
}


def vel(b, base):
    v = int(round(base * DYNAMICS.get(section_of(b), 1.0)))
    return max(1, min(127, v))

# ---------------------------------------------------------------------------
# Мотивы (ре минор, MIDI: d4=62, e4=64, f4=65, g4=67, a4=69, bb4=70,
# c5=72, d5=74, eb5=75, e5=76, f5=77, g5=79, a5=81)
# ---------------------------------------------------------------------------

# Хоральный напев — силлабический, поступенный, как григорианский хорал.
CHANT = [
    [(62, 4)],
    [(65, 2), (64, 2)],
    [(62, 4)],
    [(60, 4)],
    [(62, 2), (65, 2)],
    [(67, 4)],
    [(65, 2), (64, 2)],
    [(62, 4)],
    [(69, 4)],
    [(67, 2), (65, 2)],
    [(64, 4)],
    [(62, 4)],
]

# Маршевая тема — пунктирный ритм, волевая, с подъёмом на си♭.
MARCH = [
    [(62, 0.75), (64, 0.25), (65, 1), (69, 1), (67, 1)],
    [(65, 0.75), (64, 0.25), (62, 1), (60, 2)],
    [(69, 0.75), (70, 0.25), (72, 1), (70, 1), (69, 1)],
    [(65, 2), (64, 1), (62, 1)],
]

# Плач — высокий, с широкими скачками, «на разрыв».
LAMENT = [
    [(74, 2), (72, 2)],
    [(70, 2), (69, 2)],
    [(67, 2), (69, 2)],
    [(65, 3), ('r', 1)],
    [(74, 2), (77, 2)],
    [(76, 2), (74, 2)],
    [(72, 2), (70, 2)],
    [(69, 3), ('r', 1)],
]

# Каденция катаклизма после напева: спуск к тонике.
CATACLYSM_CADENCE = [
    [(81, 2), (79, 2)],
    [(77, 2), (76, 2)],
    [(74, 2), (72, 2)],
    [(74, 3), ('r', 1)],
]

# Ударные: восьмые доли такта (GM: 36 kick, 41/43 том низ, 45 том сер,
# 48 том верх, 49 crash).
WAR = [[36], [41], [36, 45], [41], [36], [41], [36, 45], [41]]
HEAVY = [[36, 49], [36], [36, 41], [36, 45],
         [36], [36, 41], [36], [36, 45]]
HEART = [[36], [41], [36], [41]]


# ---------------------------------------------------------------------------
# Партии
# ---------------------------------------------------------------------------


def dn(n):
    """Набор нот ударных на долю: одна нота — число, иначе список."""
    return n[0] if len(n) == 1 else list(n)


def gen_organ():
    """Соборный орган: бурдон в прологе/эпилоге, полные аккорды в марше."""
    out = []
    for b in range(1, BARS + 1):
        _, tones = chord_at(b)
        sec = section_of(b)
        if sec in ('prologue', 'epilogue'):
            # Органум: открытая квинта (средневековая звучность без терции).
            notes = [tones[0], tones[2]]
        else:
            notes = list(tones)
        # Бурдон-педаль в марше и катаклизме: корень октавой ниже.
        if sec in ('march', 'cataclysm'):
            notes = [tones[0] - 12] + notes
        out.append(bar([(notes, 4)], vel(b, 74)))
    return out


def gen_piano():
    """Пиано как арфа/колокольчики: разложенные аккорды по разделам."""
    out = []
    for b in range(1, BARS + 1):
        _, tones = chord_at(b)
        sec = section_of(b)
        pool = list(tones) + [tones[0] + 12]
        if sec == 'prologue':
            if b < 5:
                out.append(bar([('r', 4)], vel(b, 70)))
                continue
            items = [([pool[k]], 1) for k in (0, 1, 2, 3)]
        elif sec == 'lament':
            items = [([pool[k]], 1) for k in (3, 2, 1, 0)]
        elif sec == 'cataclysm':
            items = [([pool[k]], 0.5) for k in (0, 1, 2, 3, 2, 1, 0, 2)]
        elif sec == 'epilogue':
            if b < 70:
                out.append(bar([('r', 4)], vel(b, 70)))
                continue
            items = [([pool[0], pool[1], pool[2]], 4)]
        else:  # march
            items = [([pool[k]], 0.5) for k in (0, 1, 2, 3, 2, 1, 0, 2)]
        out.append(bar(items, vel(b, 80)))
    return out


def gen_guitar():
    """Лютня: хорал → марш → плач → напев в верхней октаве (кульминация)."""
    out = []
    for b in range(1, BARS + 1):
        sec = section_of(b)
        if sec == 'prologue':
            out.append(bar(CHANT[b - 1], vel(b, 96)))
        elif sec == 'march':
            idx = (b - section_start('march')) % len(MARCH)
            out.append(bar(MARCH[idx], vel(b, 102)))
        elif sec == 'lament':
            idx = (b - section_start('lament')) % len(LAMENT)
            out.append(bar(LAMENT[idx], vel(b, 100)))
        elif sec == 'cataclysm':
            k = b - section_start('cataclysm')
            if k < len(CHANT):
                # Развитие: хорал звучит октавой выше — регистровая вершина.
                out.append(bar(transpose(CHANT[k], 12), vel(b, 110)))
            else:
                out.append(bar(CATACLYSM_CADENCE[k - len(CHANT)], vel(b, 108)))
        else:  # epilogue
            k = b - section_start('epilogue')
            if k < 4:
                out.append(bar(CHANT[k], vel(b, 90)))
            else:
                out.append(bar([('r', 4)], vel(b, 88)))
    return out


def gen_drums():
    """Боевые барабаны: тишина в прологе, томы в марше, «сердце» в плаче,
    татаны в катаклизме, удар-точка в эпилоге."""
    out = []
    for b in range(1, BARS + 1):
        sec = section_of(b)
        if sec == 'prologue':
            if b == section_start('march') - 1:
                out.append(bar([([36, 41], 4)], vel(b, 92)))  # раскат в марш
            else:
                out.append(bar([('r', 4)], vel(b, 80)))
        elif sec == 'march':
            items = [(dn(n), 0.5) for n in WAR]
            if b % 4 == 0:  # филл в конце фразы
                items = [(dn(n), 0.5) for n in WAR[:6]] + [(41, 0.5), (45, 0.5)]
            if b == section_start('march'):
                items[0] = ([36, 49], 0.5)   # crash на входе
            out.append(bar(items, vel(b, 100)))
        elif sec == 'lament':
            if b % 2 == 0:
                out.append(bar([(dn(n), 1) for n in HEART], vel(b, 78)))
            else:
                out.append(bar([('r', 4)], vel(b, 78)))
        elif sec == 'cataclysm':
            items = [(dn(n), 0.5) for n in HEAVY]
            if b == section_start('cataclysm'):
                items[0] = ([36, 49], 0.5)
            if b % 8 == 0:  # том-раскат раз в 8 тактов
                items = [(dn(n), 0.5) for n in HEAVY[:4]] + \
                        [(45, 0.5), (41, 0.5), (45, 0.5), (41, 0.5)]
            out.append(bar(items, vel(b, 108)))
        else:  # epilogue
            if b == section_start('epilogue'):
                out.append(bar([([36, 49], 4)], vel(b, 95)))
            else:
                out.append(bar([('r', 4)], vel(b, 80)))
    return out


def write_part(name, lines):
    path = os.path.join(OUT_DIR, name + '.notes')
    with open(path, 'w', encoding='utf-8') as f:
        f.write('# %s — Cathedral of Ash (generated)\n' % name)
        for line in lines:
            f.write(line + '\n')
    print('wrote', path)


def main():
    write_part('organ', gen_organ())
    write_part('piano', gen_piano())
    write_part('guitar', gen_guitar())
    write_part('drums', gen_drums())


if __name__ == '__main__':
    sys.exit(main())

