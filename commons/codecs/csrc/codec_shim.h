/*
 * commons/codecs/csrc/codec_shim.h
 *
 * Плоский C-ABI над dr_flac / dr_mp3 / stb_vorbis (issue #10).
 *
 * Зачем шим, а не прямые {.importc.} на библиотеки: типы dr_flac/drmp3/
 * stb_vorbis — крупные версионно-зависимые структуры. Шим прячет их layout
 * внутри C, а Nim видит только простые функции и обычные буферы. Тот же
 * приём, что у miniaudio-адаптера (§41, §42).
 *
 * Реализация — в codec_shim.c (единый TU: _IMPLEMENTATION + шим).
 * Ошибки — кодами возврата, а не исключениями: битый/усечённый файл это
 * нормальный исход клиента (#10), а не паника.
 */
#ifndef EUT_CODEC_SHIM_H
#define EUT_CODEC_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

/* Вид кодека. Порядок совпадает с ветвями Nim-обёртки commons/codecs. */
enum {
    EUT_CODEC_FLAC   = 1,
    EUT_CODEC_MP3    = 2,
    EUT_CODEC_VORBIS = 3
};

/* Готов ли кодек к работе (1 — да). Ответ константен: библиотеки вкомпилены. */
int eut_codec_ready(int kind);

/* Метаданные файла. 0 — успех; <0 — ошибка (не открылся/битый/чужой формат).
 * channels/sampleRate — в int, frames — число КАДРОВ (на канал). */
int eut_codec_probe(const char* path, int kind,
                    int* channels, int* sampleRate, long long* frames);

/* Декодирование в interleaved float32. Возвращает прочитанные КАДРЫ (>=0)
 * или <0 при ошибке. Пишет не более maxFrames кадров. */
long long eut_codec_decode(const char* path, int kind,
                           float* out, long long maxFrames);

#ifdef __cplusplus
}
#endif

#endif /* EUT_CODEC_SHIM_H */
