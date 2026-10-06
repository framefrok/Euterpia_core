# tests/asan_probe_allocshared.nim
#
# Зонд для issue #364: доказывает, что ASan-джоб ловит переполнения памяти,
# выделенной через allocShared0.
#
# Зачем отдельный файл и почему он НЕ входит в tests/unit/:
#   * зонд обязан УПАСТЬ под ASan — держать его в общем наборе нельзя,
#     иначе `nimble asan` всегда красный;
#   * он проверяет не ядро, а САМ ИНСТРУМЕНТ: инструментирован ли
#     allocShared. Без `-d:useMalloc` Nim кладёт эту память в собственную
#     mmap-кучу мимо libasan, и переполнение молчит; с флагом — падает
#     `AddressSanitizer: heap-buffer-overflow`.
#
# Запуск (ожидается НЕНУЛЕВОЙ код возврата, иначе флаг не действует):
#   nimble asanProbe

const
  BufferBytes = 256
  SamplesToWrite = 10_000   # 40 000 байт в 256-байтовый буфер

proc main() =
  # 256 байт = 64 float32. Пишем 10 000 — далеко за границу аллокации.
  let p = cast[ptr UncheckedArray[float32]](allocShared0(BufferBytes))
  for i in 0 ..< SamplesToWrite:
    p[i] = 1.0'f32
  deallocShared(cast[pointer](p))
  echo "probe: переполнение не поймано (ASan выключен или useMalloc не действует)"

main()
