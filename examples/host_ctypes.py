#!/usr/bin/env python3
"""Чужой рантайм: загрузка ядра EUTERPIA как shared-библиотеки (issue #213).

Смысл файла — доказать, что фасад `examples/embed_lib.nim` годен не только
для Nim-хоста: его грузит Python через ctypes, то есть тот же путь, которым
пойдёт игровой движок на C/C++/Rust. Здесь нет ни одного импорта ядра —
только `ctypes.CDLL` и C-ABI из `euterpia_embed.h`.

Запуск (собирает библиотеку nimble-цель `embedLib`):
    python3 examples/host_ctypes.py build/libeuterpia_embed.so

Код возврата: 0 — ABI работает, 1 — нет (в CI это падает).
"""

from __future__ import annotations

import ctypes
import os
import sys

SampleRate = 48000
BlockSize = 128
Blocks = 200
# Разница с 1.0 — допуск на «пик посчитан по блоку», а не по всему сигналу.
MinPeak = 0.01


def fail(message: str) -> int:
    print(f"FAIL: {message}")
    return 1


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: host_ctypes.py <path-to-libeuterpia_embed.so>")
        return 1

    path = sys.argv[1]
    if not os.path.exists(path):
        return fail(f"библиотеки нет: {path}")

    lib = ctypes.CDLL(os.path.abspath(path))

    # Прототипы: без них ctypes считает int32 и портит указатели/float.
    lib.eutHostVersion.restype = ctypes.c_char_p
    lib.eutHostVersion.argtypes = []

    lib.eutHostCreate.restype = ctypes.c_void_p
    lib.eutHostCreate.argtypes = [ctypes.c_int, ctypes.c_int]

    lib.eutHostPlay.restype = ctypes.c_int
    lib.eutHostPlay.argtypes = [ctypes.c_void_p]

    lib.eutHostRenderBlock.restype = ctypes.c_float
    lib.eutHostRenderBlock.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_float),
    ]

    lib.eutHostCurrentFrame.restype = ctypes.c_longlong
    lib.eutHostCurrentFrame.argtypes = [ctypes.c_void_p]

    lib.eutHostStop.restype = ctypes.c_int
    lib.eutHostStop.argtypes = [ctypes.c_void_p]

    lib.eutHostDestroy.restype = None
    lib.eutHostDestroy.argtypes = [ctypes.c_void_p]

    version = lib.eutHostVersion().decode()
    print(f"eutHostVersion() = {version}")
    if not version:
        return fail("версия пуста — модуль euterpia_version не доехал")

    host = lib.eutHostCreate(SampleRate, BlockSize)
    if not host:
        return fail("eutHostCreate вернул NULL")
    print(f"eutHostCreate({SampleRate}, {BlockSize}) -> handle")

    if not lib.eutHostPlay(host):
        return fail("eutHostPlay отвергнут")

    buf = (ctypes.c_float * (BlockSize * 2))()
    peak = 0.0
    for _ in range(Blocks):
        p = lib.eutHostRenderBlock(host, buf)
        if p > peak:
            peak = p

    frame = lib.eutHostCurrentFrame(host)
    print(f"рендер: {Blocks} блоков, пик={peak:.4f}, кадров={frame}")

    if peak <= MinPeak:
        return fail("граф молчит — ABI доехал, а звук нет")
    if frame < Blocks * BlockSize:
        return fail(f"транспорт не продвинулся: кадров {frame}")

    lib.eutHostStop(host)
    lib.eutHostDestroy(host)
    print("ok: ядро загружено как библиотека, ABI проверен")
    return 0


if __name__ == "__main__":
    sys.exit(main())
