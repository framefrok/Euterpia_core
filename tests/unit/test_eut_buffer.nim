# tests/unit/test_eut_buffer.nim
#
# EUT ABI: проброс аудио-буфера Core → `EutAudioBuffer` (аудит, P3).
#
# До фикса адаптер отдавал плагину только канал 0 и `channelCount: 1`,
# поэтому правый канал стерео-буфера не обрабатывался. Здесь проверяется
# раскладка указателей для planar/interleaved и для неполного блока
# (`frames < stride`), где эвристика «stride == frames» ошибалась.

import std/unittest

import signal_types
import eut_plugin
import eut_plugin_backend

proc buf(data: ptr UncheckedArray[float32]; channels, frames, stride: int32;
         layout: AudioLayout): AudioBuffer =
  AudioBuffer(data: data, channels: channels, frames: frames,
              stride: stride, layout: layout)

suite "EUT: стерео-буфер (аудит P3)":
  test "planar: каналы по stride, channelCount = 2":
    var samples: array[16, float32]
    var ptrs: array[MaxAudioChannels, ptr cfloat]
    var desc: EutAudioBuffer
    var b = buf(cast[ptr UncheckedArray[float32]](addr samples[0]),
                2, 4, 4, alPlanar)
    bindEutAudioBuffer(addr b, ptrs, desc, 3)

    check desc.portIndex == 3'u32
    check desc.channelCount == 2'u32
    check desc.structSize == csize_t(sizeof(EutAudioBuffer))
    check cast[pointer](ptrs[0]) == cast[pointer](addr samples[0])
    check cast[pointer](ptrs[1]) == cast[pointer](addr samples[4])
    check desc.data[0] == ptrs[0]
    check desc.data[1] == ptrs[1]

  test "planar на неполном блоке: frames < stride не путается с interleaved":
    var samples: array[16, float32]
    var ptrs: array[MaxAudioChannels, ptr cfloat]
    var desc: EutAudioBuffer
    # Ровно сценарий аудита: blockSize=2, а арена шагает на 4 кадра.
    var b = buf(cast[ptr UncheckedArray[float32]](addr samples[0]),
                2, 2, 4, alPlanar)
    bindEutAudioBuffer(addr b, ptrs, desc, 0)

    check desc.channelCount == 2'u32
    check cast[pointer](ptrs[0]) == cast[pointer](addr samples[0])
    check cast[pointer](ptrs[1]) == cast[pointer](addr samples[4])

  test "interleaved: каналы соседние":
    var samples: array[16, float32]
    var ptrs: array[MaxAudioChannels, ptr cfloat]
    var desc: EutAudioBuffer
    var b = buf(cast[ptr UncheckedArray[float32]](addr samples[0]),
                2, 4, 1, alInterleaved)
    bindEutAudioBuffer(addr b, ptrs, desc, 0)

    check desc.channelCount == 2'u32
    check cast[pointer](ptrs[0]) == cast[pointer](addr samples[0])
    check cast[pointer](ptrs[1]) == cast[pointer](addr samples[1])

  test "моно и пустой буфер не дают лишних каналов":
    var samples: array[8, float32]
    var ptrs: array[MaxAudioChannels, ptr cfloat]
    var desc: EutAudioBuffer
    var mono = buf(cast[ptr UncheckedArray[float32]](addr samples[0]),
                   1, 8, 8, alPlanar)
    bindEutAudioBuffer(addr mono, ptrs, desc, 0)
    check desc.channelCount == 1'u32

    var nilBuf: ptr AudioBuffer = nil
    var emptyDesc: EutAudioBuffer
    bindEutAudioBuffer(nilBuf, ptrs, emptyDesc, 1)
    check emptyDesc.channelCount == 0'u32
    check emptyDesc.portIndex == 1'u32
