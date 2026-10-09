#!/usr/bin/env python3
"""Пик/клип-проверка WAV (dev-инструмент, не часть пайплайна)."""
import array
import sys
import wave

path = sys.argv[1]
w = wave.open(path)
n = w.getnframes()
sw = w.getsampwidth()
data = w.readframes(n)
peak = 0.0
clipped = 0
if sw == 2:
    a = array.array("h")
    a.frombytes(data)
    peak = max(abs(x) for x in a) / 32768.0
    clipped = sum(1 for x in a if x in (32767, -32768))
print(
    f"rate={w.getframerate()} ch={w.getnchannels()} frames={n} "
    f"sec={n / w.getframerate():.1f} peak={peak:.4f} "
    f"peak_db={20 * __import__('math').log10(max(peak, 1e-9)):.2f} "
    f"clipped_samples={clipped}"
)
