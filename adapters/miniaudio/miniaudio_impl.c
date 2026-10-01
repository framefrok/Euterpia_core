/*
 * adapters/miniaudio/miniaudio_impl.c
 *
 * Единый TU: реализация miniaudio (MINIAUDIO_IMPLEMENTATION) + плоский
 * C-ABI-шим для адаптера core/audio_backend_api (issue #31).
 *
 * Версия miniaudio зафиксирована вендорингом (см. miniaudio.h:
 * MA_VERSION_MAJOR.MINOR.REVISION = 0.11.25). Обновление версии —
 * отдельная задача с прогоном CI-джоба `miniaudio backend`.
 *
 * C-only: без C++. Компилируется как TU адаптера — см.
 * adapters/miniaudio/audio_backend_miniaudio.nim ({.compile.}).
 */

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <stdlib.h>
#include <string.h>

#include "miniaudio_shim.h"

#if defined(_WIN32)
  #include <windows.h>
  static double eut_ma_now_seconds(void)
  {
      LARGE_INTEGER freq;
      LARGE_INTEGER counter;
      if (QueryPerformanceFrequency(&freq) == 0 || freq.QuadPart == 0) {
          return 0.0;
      }
      QueryPerformanceCounter(&counter);
      return (double)counter.QuadPart / (double)freq.QuadPart;
  }
#else
  #include <time.h>
  static double eut_ma_now_seconds(void)
  {
      struct timespec ts;
      if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
          return 0.0;
      }
      return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
  }
#endif

struct eut_ma_ctx {
    ma_context      context;
    ma_device_info* playback;
    ma_uint32       playbackCount;
    ma_device_info* capture;
    ma_uint32       captureCount;
};

struct eut_ma_dev {
    ma_device          device;
    eut_ma_render_proc render;
    void*              engineCtx;
    int                inputChannels;
    int                outputChannels;
    int                latencyFrames;
    double             sampleRate;

    /* Диагностика: пишется из audio-потока, читается с control-path.
     *
     * У miniaudio 0.11.25 нет публичного API статуса драйвера
     * (underflow/overflow) и счётчика xrun: backend восстанавливается
     * после xrun сам. Поэтому xrun здесь — это (а) вызов render, не
     * уложившийся в длительность блока, и (б) notification
     * interruption_began. Счётчик монотонный, один писатель. */
    volatile long long xruns;
    volatile int       lastFlag;
};

/* ---------------------------------------------------------------------------
 * Audio callbacks (audio thread: без аллокаций, локов и I/O)
 * ------------------------------------------------------------------------ */

static void eut_ma_data_callback(ma_device* pDevice, void* pOutput,
                                 const void* pInput, ma_uint32 frameCount)
{
    eut_ma_dev* d = (eut_ma_dev*)pDevice->pUserData;

    if (d == NULL || d->render == NULL) {
        return;
    }

    const double t0 = eut_ma_now_seconds();

    d->render(d->engineCtx,
              (float*)pInput,   /* контракт render принимает не-константный указатель */
              (float*)pOutput,
              (int)frameCount,
              d->inputChannels,
              d->outputChannels);

    if (d->sampleRate > 0.0) {
        const double elapsed = eut_ma_now_seconds() - t0;
        const double budget  = (double)frameCount / d->sampleRate;
        if (elapsed > budget) {
            d->xruns += 1;
            d->lastFlag = (d->outputChannels > 0)
                        ? EUT_MA_FLAG_OUTPUT_UNDERFLOW
                        : EUT_MA_FLAG_INPUT_OVERFLOW;
        }
    }
}

static void eut_ma_notification_callback(const ma_device_notification* pNotification)
{
    eut_ma_dev* d;

    if (pNotification == NULL || pNotification->pDevice == NULL) {
        return;
    }

    d = (eut_ma_dev*)pNotification->pDevice->pUserData;
    if (d == NULL) {
        return;
    }

    if (pNotification->type == ma_device_notification_type_interruption_began) {
        d->xruns += 1;
        d->lastFlag = EUT_MA_FLAG_OUTPUT_UNDERFLOW;
    }
}

/* ---------------------------------------------------------------------------
 * Context
 * ------------------------------------------------------------------------ */

eut_ma_ctx* eut_ma_context_create(void)
{
    eut_ma_ctx* c = (eut_ma_ctx*)calloc(1, sizeof(eut_ma_ctx));
    if (c == NULL) {
        return NULL;
    }

    if (ma_context_init(NULL, 0, NULL, &c->context) != MA_SUCCESS) {
        free(c);
        return NULL;
    }

    if (ma_context_get_devices(&c->context,
                               &c->playback, &c->playbackCount,
                               &c->capture,  &c->captureCount) != MA_SUCCESS) {
        c->playback      = NULL;
        c->capture       = NULL;
        c->playbackCount = 0;
        c->captureCount  = 0;
    }

    return c;
}

void eut_ma_context_destroy(eut_ma_ctx* c)
{
    if (c == NULL) {
        return;
    }
    ma_context_uninit(&c->context);
    free(c);
}

/* Разумные значения, когда backend не отдал список нативных форматов. */
static void eut_ma_fill_channels_rate(const ma_device_info* info,
                                      int* maxChannels, double* sampleRate)
{
    ma_uint32 i;

    *maxChannels = 0;
    *sampleRate  = 0.0;

    for (i = 0; i < info->nativeDataFormatCount && i < 64; ++i) {
        if ((int)info->nativeDataFormats[i].channels > *maxChannels) {
            *maxChannels = (int)info->nativeDataFormats[i].channels;
        }
        if ((double)info->nativeDataFormats[i].sampleRate > *sampleRate) {
            *sampleRate = (double)info->nativeDataFormats[i].sampleRate;
        }
    }

    if (*maxChannels <= 0) {
        *maxChannels = 2;
    }
    if (*sampleRate <= 0.0) {
        *sampleRate = 48000.0;
    }
}

int eut_ma_device_count(eut_ma_ctx* c, int wantInput)
{
    if (c == NULL) {
        return 0;
    }
    return (int)(wantInput ? c->captureCount : c->playbackCount);
}

int eut_ma_device_info(eut_ma_ctx* c, int index, int wantInput,
                       char* nameOut, int nameCap,
                       int* isDefault,
                       int* maxInputChannels, int* maxOutputChannels,
                       double* defaultSampleRate,
                       double* defaultLowInputLatency,
                       double* defaultLowOutputLatency)
{
    ma_device_info* infos;
    ma_uint32       count;
    ma_device_info* info;
    int             maxChannels = 0;
    double          sr          = 0.0;

    if (c == NULL || index < 0) {
        return 0;
    }

    if (wantInput) {
        infos = c->capture;
        count = c->captureCount;
    } else {
        infos = c->playback;
        count = c->playbackCount;
    }

    if (infos == NULL || (ma_uint32)index >= count) {
        return 0;
    }

    info = &infos[index];
    eut_ma_fill_channels_rate(info, &maxChannels, &sr);

    if (nameOut != NULL && nameCap > 0) {
        strncpy(nameOut, info->name, (size_t)(nameCap - 1));
        nameOut[nameCap - 1] = '\0';
    }
    if (isDefault != NULL) {
        *isDefault = (info->isDefault != 0) ? 1 : 0;
    }
    if (maxInputChannels != NULL) {
        *maxInputChannels = wantInput ? maxChannels : 0;
    }
    if (maxOutputChannels != NULL) {
        *maxOutputChannels = wantInput ? 0 : maxChannels;
    }
    if (defaultSampleRate != NULL) {
        *defaultSampleRate = sr;
    }
    /* miniaudio не публикует заявленную latency устройства: 0.0 для
     * вызывающего означает "выбери сам". */
    if (defaultLowInputLatency != NULL) {
        *defaultLowInputLatency = 0.0;
    }
    if (defaultLowOutputLatency != NULL) {
        *defaultLowOutputLatency = 0.0;
    }

    return 1;
}

/* ---------------------------------------------------------------------------
 * Device
 * ------------------------------------------------------------------------ */

eut_ma_dev* eut_ma_device_open(eut_ma_ctx* c,
                               double sampleRate,
                               int    blockSize,
                               int    inputChannels,
                               int    outputChannels,
                               int    inputDevice,
                               int    outputDevice,
                               eut_ma_render_proc render,
                               void*  engineCtx)
{
    eut_ma_dev*      d;
    ma_device_config cfg;
    ma_device_type   type;

    if (c == NULL || render == NULL) {
        return NULL;
    }
    if (inputChannels <= 0 && outputChannels <= 0) {
        return NULL;
    }
    if (sampleRate <= 0.0) {
        return NULL;
    }

    if (inputChannels > 0 && outputChannels > 0) {
        type = ma_device_type_duplex;
    } else if (inputChannels > 0) {
        type = ma_device_type_capture;
    } else {
        type = ma_device_type_playback;
    }

    d = (eut_ma_dev*)calloc(1, sizeof(eut_ma_dev));
    if (d == NULL) {
        return NULL;
    }

    d->render         = render;
    d->engineCtx      = engineCtx;
    d->inputChannels  = inputChannels;
    d->outputChannels = outputChannels;
    d->sampleRate     = sampleRate;
    d->latencyFrames  = blockSize;
    d->xruns          = 0;
    d->lastFlag       = EUT_MA_FLAG_NONE;

    cfg = ma_device_config_init(type);
    cfg.sampleRate = (ma_uint32)sampleRate;
    if (blockSize > 0) {
        cfg.periodSizeInFrames = (ma_uint32)blockSize;
    }
    cfg.performanceProfile   = ma_performance_profile_low_latency;
    cfg.dataCallback         = eut_ma_data_callback;
    cfg.notificationCallback = eut_ma_notification_callback;
    cfg.pUserData            = d;

    if (outputChannels > 0) {
        cfg.playback.format   = ma_format_f32;
        cfg.playback.channels = (ma_uint32)outputChannels;
        if (outputDevice >= 0 && (ma_uint32)outputDevice < c->playbackCount) {
            cfg.playback.pDeviceID = &c->playback[outputDevice].id;
        }
    }
    if (inputChannels > 0) {
        cfg.capture.format   = ma_format_f32;
        cfg.capture.channels = (ma_uint32)inputChannels;
        if (inputDevice >= 0 && (ma_uint32)inputDevice < c->captureCount) {
            cfg.capture.pDeviceID = &c->capture[inputDevice].id;
        }
    }

    if (ma_device_init(&c->context, &cfg, &d->device) != MA_SUCCESS) {
        free(d);
        return NULL;
    }

    /* Backend мог выбрать другую частоту — фиксируем фактическую. */
    if (d->device.sampleRate > 0) {
        d->sampleRate = (double)d->device.sampleRate;
    }

    return d;
}

int eut_ma_device_start(eut_ma_dev* d)
{
    if (d == NULL) {
        return -1;
    }
    return (ma_device_start(&d->device) == MA_SUCCESS) ? 0 : -1;
}

void eut_ma_device_stop(eut_ma_dev* d)
{
    if (d == NULL) {
        return;
    }
    ma_device_stop(&d->device);
}

void eut_ma_device_close(eut_ma_dev* d)
{
    if (d == NULL) {
        return;
    }
    ma_device_uninit(&d->device);
    free(d);
}

int eut_ma_device_is_started(eut_ma_dev* d)
{
    if (d == NULL) {
        return 0;
    }
    return (ma_device_is_started(&d->device) != 0) ? 1 : 0;
}

unsigned long long eut_ma_device_xruns(eut_ma_dev* d)
{
    if (d == NULL) {
        return 0ULL;
    }
    return (unsigned long long)d->xruns;
}

int eut_ma_device_last_flag(eut_ma_dev* d)
{
    if (d == NULL) {
        return EUT_MA_FLAG_NONE;
    }
    return d->lastFlag;
}

int eut_ma_device_latency_frames(eut_ma_dev* d)
{
    if (d == NULL) {
        return 0;
    }
    return d->latencyFrames;
}

double eut_ma_device_sample_rate(eut_ma_dev* d)
{
    if (d == NULL) {
        return 0.0;
    }
    return d->sampleRate;
}

