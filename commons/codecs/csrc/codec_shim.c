/*
 * commons/codecs/csrc/codec_shim.c
 *
 * Единый TU: реализации dr_flac / dr_mp3 / stb_vorbis + плоский C-ABI
 * (issue #10). C-only, без C++.
 *
 * Библиотеки лицензионно чистые и без внешних зависимостей:
 *   dr_flac.h / dr_mp3.h — public domain / MIT-0 (mackron/dr_libs);
 *   stb_vorbis.c         — public domain / MIT (nothings/stb).
 */

#include "codec_shim.h"

#include <stdlib.h>
#include <string.h>

#define DR_FLAC_IMPLEMENTATION
/* Ogg-контейнер FLAC нам не нужен: FLAC читаем как raw, Ogg отдан stb_vorbis. */
#define DR_FLAC_NO_OGG
#include "dr_flac.h"

#define DR_MP3_IMPLEMENTATION
#include "dr_mp3.h"

/* stb_vorbis.c сам содержит и объявления, и реализацию. */
#include "stb_vorbis.c"

int eut_codec_ready(int kind)
{
    switch (kind) {
        case EUT_CODEC_FLAC:
        case EUT_CODEC_MP3:
        case EUT_CODEC_VORBIS:
            return 1;
        default:
            return 0;
    }
}

int eut_codec_probe(const char* path, int kind,
                    int* channels, int* sampleRate, long long* frames)
{
    if (path == NULL || channels == NULL || sampleRate == NULL ||
        frames == NULL) {
        return -1;
    }

    if (kind == EUT_CODEC_FLAC) {
        drflac* f = drflac_open_file(path, NULL);
        if (f == NULL) {
            return -2;
        }
        *channels   = (int)f->channels;
        *sampleRate = (int)f->sampleRate;
        *frames     = (long long)f->totalPCMFrameCount;
        drflac_close(f);
        return 0;
    }

    if (kind == EUT_CODEC_MP3) {
        drmp3 mp3;
        if (!drmp3_init_file(&mp3, path, NULL)) {
            return -3;
        }
        *channels   = (int)mp3.channels;
        *sampleRate = (int)mp3.sampleRate;
        *frames     = (long long)drmp3_get_pcm_frame_count(&mp3);
        drmp3_uninit(&mp3);
        return 0;
    }

    if (kind == EUT_CODEC_VORBIS) {
        int error = 0;
        stb_vorbis* v = stb_vorbis_open_filename(path, &error, NULL);
        if (v == NULL) {
            return -4;
        }
        stb_vorbis_info info = stb_vorbis_get_info(v);
        *channels   = info.channels;
        *sampleRate = (int)info.sample_rate;
        /* stream_length_in_samples — сэмплов на канал (это же значение
           используется stb_vorbis для длительности в секундах). */
        *frames     = (long long)stb_vorbis_stream_length_in_samples(v);
        stb_vorbis_close(v);
        return 0;
    }

    return -5;
}

long long eut_codec_decode(const char* path, int kind,
                           float* out, long long maxFrames)
{
    if (path == NULL || out == NULL || maxFrames <= 0) {
        return -1;
    }

    if (kind == EUT_CODEC_FLAC) {
        drflac* f = drflac_open_file(path, NULL);
        if (f == NULL) {
            return -2;
        }
        drflac_uint64 got = drflac_read_pcm_frames_f32(
            f, (drflac_uint64)maxFrames, out);
        drflac_close(f);
        return (long long)got;
    }

    if (kind == EUT_CODEC_MP3) {
        drmp3 mp3;
        if (!drmp3_init_file(&mp3, path, NULL)) {
            return -3;
        }
        drmp3_uint64 got = drmp3_read_pcm_frames_f32(
            &mp3, (drmp3_uint64)maxFrames, out);
        drmp3_uninit(&mp3);
        return (long long)got;
    }

    if (kind == EUT_CODEC_VORBIS) {
        int error = 0;
        stb_vorbis* v = stb_vorbis_open_filename(path, &error, NULL);
        if (v == NULL) {
            return -4;
        }
        stb_vorbis_info info = stb_vorbis_get_info(v);
        /* num_floats — всего сэмплов с учётом каналов; возврат — кадры. */
        long long budget = maxFrames * (long long)info.channels;
        if (budget > 2147483647LL) {
            budget = 2147483647LL;
        }
        int got = stb_vorbis_get_samples_float_interleaved(
            v, info.channels, out, (int)budget);
        stb_vorbis_close(v);
        return (long long)got;
    }

    return -5;
}
