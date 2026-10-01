/*
 * adapters/miniaudio/miniaudio_shim.h
 *
 * Плоский C-ABI над miniaudio для адаптера audio_backend_api (issue #31).
 *
 * Зачем шим, а не прямые {.importc.} на miniaudio:
 *   ma_context / ma_device / ma_device_config — крупные и версионно-
 *   зависимые структуры. Повторять их layout в Nim — значит ломаться на
 *   каждой смене версии miniaudio. Шим прячет layout внутри C, а Nim
 *   видит только непрозрачные указатели и простые сигнатуры.
 *
 * Здесь и ТОЛЬКО здесь знает о miniaudio (MANIFEST §41, §42). Core видит
 * лишь таблицу методов AudioBackendApi.
 *
 * Realtime-контракт: eut_ma_render_proc вызывается из audio callback
 * miniaudio. Функции, которые могут быть вызваны из audio-потока, не
 * аллоцируют и не блокируют.
 */

#ifndef EUT_MA_SHIM_H
#define EUT_MA_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

/* Соответствует core/audio_backend_api.AudioRenderProc. */
typedef void (*eut_ma_render_proc)(
    void*  engineCtx,
    float* driverIn,      /* interleaved, может быть NULL */
    float* driverOut,     /* interleaved */
    int    frames,
    int    inputChannels,
    int    outputChannels);

/* Значения совпадают с порядком core/audio_backend_api.AudioStreamFlag,
 * чтобы адаптер мог положить lastFlag в lastStatusFlags без таблиц. */
#define EUT_MA_FLAG_INPUT_UNDERFLOW   0
#define EUT_MA_FLAG_INPUT_OVERFLOW    1
#define EUT_MA_FLAG_OUTPUT_UNDERFLOW  2
#define EUT_MA_FLAG_OUTPUT_OVERFLOW   3
#define EUT_MA_FLAG_NONE             (-1)

typedef struct eut_ma_ctx eut_ma_ctx;
typedef struct eut_ma_dev eut_ma_dev;

/* -------------------------------------------------------------------------
 * Context (control-path)
 * ---------------------------------------------------------------------- */

/* NULL, если miniaudio не смог поднять ни один backend. */
eut_ma_ctx* eut_ma_context_create(void);
void        eut_ma_context_destroy(eut_ma_ctx* c);

/* Число устройств. wantInput != 0 — устройства захвата, иначе воспроизведения. */
int eut_ma_device_count(eut_ma_ctx* c, int wantInput);

/* Описание устройства. nameOut — буфер вызывающего (nameCap байт).
 * Возвращает 1 при успехе, 0 если контекст/индекс невалидны. */
int eut_ma_device_info(
    eut_ma_ctx* c,
    int index,
    int wantInput,
    char* nameOut, int nameCap,
    int* isDefault,
    int* maxInputChannels,
    int* maxOutputChannels,
    double* defaultSampleRate,
    double* defaultLowInputLatency,
    double* defaultLowOutputLatency);

/* -------------------------------------------------------------------------
 * Device (control-path: open/start/stop/close)
 * ---------------------------------------------------------------------- */

/* inputDevice / outputDevice: -1 == устройство по умолчанию.
 * NULL при ошибке (нет устройства, контекст не готов, некорректный конфиг). */
eut_ma_dev* eut_ma_device_open(
    eut_ma_ctx* c,
    double sampleRate,
    int    blockSize,
    int    inputChannels,
    int    outputChannels,
    int    inputDevice,
    int    outputDevice,
    eut_ma_render_proc render,
    void*  engineCtx);

int  eut_ma_device_start(eut_ma_dev* d);   /* 0 при успехе */
void eut_ma_device_stop(eut_ma_dev* d);
void eut_ma_device_close(eut_ma_dev* d);
int  eut_ma_device_is_started(eut_ma_dev* d);

/* -------------------------------------------------------------------------
 * Диагностика (растёт в audio-потоке, читается на control-path)
 * ---------------------------------------------------------------------- */

unsigned long long eut_ma_device_xruns(eut_ma_dev* d);
int                eut_ma_device_last_flag(eut_ma_dev* d);
int                eut_ma_device_latency_frames(eut_ma_dev* d);
/* Реальная частота, выбранная backend'ом (может отличаться от запрошенной). */
double             eut_ma_device_sample_rate(eut_ma_dev* d);

#ifdef __cplusplus
}
#endif

#endif /* EUT_MA_SHIM_H */
