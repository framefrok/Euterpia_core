# tests/unit/test_clap_plugin_extensions.nim
#
# Plugin-side расширения CLAP (issue #49).
#
# Реального плагина здесь нет: тест проверяет ту часть адаптера, которую
# можно проверить без бинаря и которая как раз была сломана в прежнем
# `clap_plugin_host.nim`:
#
#   1. ABI-layout структур — по фактическим смещениям полей, как их
#      разложил бы C-компилятор (это ловит перестановку полей, из-за
#      которой `clap_audio_port_info` читался бы мусором);
#   2. раздельность `clap_istream` (read) и `clap_ostream` (write) —
#      раньше это была одна склеенная структура, и `state.load` ушёл бы
#      по неверному указателю;
#   3. байтовые потоки clap.state: round-trip и переполнение (-1);
#   4. nil-safe получение расширений.

import std/unittest
import clap_host
import clap_plugin_extensions

suite "clap plugin-side extensions (#49)":

  test "ABI: порядок и размер clap_audio_port_info":
    when sizeof(pointer) == 8:
      var ap: ClapAudioPortInfo
      let base = cast[uint](addr ap)
      # C: id(uint32), name[256], flags, channel_count, port_type(ptr), in_place_pair
      check cast[uint](addr ap.flags) - base == uint(4 + ClapNameSize)
      check cast[uint](addr ap.channelCount) - base == uint(4 + ClapNameSize + 4)
      check cast[uint](addr ap.portType) - base == 272'u
      check cast[uint](addr ap.inPlacePair) - base == 280'u
      check sizeof(ClapAudioPortInfo) == 288

  test "ABI: порядок и размер clap_param_info":
    when sizeof(pointer) == 8:
      var pi: ClapParamInfo
      let base = cast[uint](addr pi)
      check cast[uint](addr pi.name) - base == 16'u
      check cast[uint](addr pi.module) - base == uint(16 + ClapNameSize)
      check cast[uint](addr pi.minValue) - base == uint(16 + ClapNameSize + ClapPathSize)
      check sizeof(ClapParamInfo) ==
        16 + ClapNameSize + ClapPathSize + 3 * sizeof(float64)

  test "потоки clap.state: счётчик считает только записанные байты":
    var buf: array[16, byte]
    var cursor: BufferCursor
    var os = initWriteStream(cursor, addr buf[0], buf.len)
    check os.ctx != nil
    check os.write != nil

    let payload = [byte 1, 2, 3, 4, 5]
    check os.write(addr os, cast[pointer](unsafeAddr payload[0]), 5'u64) == 5
    check bytesUsed(cursor) == 5
    check cursor.capacity == 16'u64

    # Переполнение: 12 байт при 11 свободных -> -1, ничего не пишется.
    var big: array[12, byte]
    check os.write(addr os, cast[pointer](addr big[0]), 12'u64) == -1
    check bytesUsed(cursor) == 5

  test "потоки clap.state: round-trip write -> read":
    var data: array[32, byte]
    var wcur: BufferCursor
    var os = initWriteStream(wcur, addr data[0], data.len)

    let a = [byte 10, 20, 30]
    let b = "euterpia"
    check os.write(addr os, cast[pointer](unsafeAddr a[0]), 3'u64) == 3
    check os.write(addr os, cast[pointer](unsafeAddr b[0]), uint64(b.len)) ==
      int64(b.len)
    let total = bytesUsed(wcur)

    var rcur: BufferCursor
    var istr = initReadStream(rcur, addr data[0], total)
    check istr.ctx != nil

    var aBack: array[3, byte]
    check istr.read(addr istr, cast[pointer](addr aBack[0]), 3'u64) == 3
    check aBack[0] == 10'u8
    check aBack[2] == 30'u8

    var bBack: array[8, byte]
    check istr.read(addr istr, cast[pointer](addr bBack[0]), 8'u64) == 8
    check cast[cstring](addr bBack[0]) == cstring"euterpia"

    # Чтение за пределами записанного -> -1.
    var one: array[1, byte]
    check istr.read(addr istr, cast[pointer](addr one[0]), 1'u64) == -1

  test "nil-safe: ни плагина, ни контекста":
    let exts = fetchClapPluginExts(nil)
    check exts.params == nil
    check exts.state == nil
    check exts.latency == nil
    check exts.audioPorts == nil

    # Пустой (нулевой) ClapPlugin не должен ронять fetch.
    var plugin: ClapPlugin
    let exts2 = fetchClapPluginExts(addr plugin)
    check exts2.params == nil

  test "readFixedString обрезает по NUL":
    var buf: array[8, char]
    buf[0] = 'a'
    buf[1] = 'b'
    buf[2] = 'c'
    buf[3] = '\0'
    check readFixedString(buf) == "abc"

    var full: array[3, char]
    full[0] = 'x'
    full[1] = 'y'
    full[2] = 'z'
    check readFixedString(full) == "xyz"
