/* ===========================================================================
 * eut_dsp.h — native DSP kernels for EUTERPIA builtin nodes
 * ===========================================================================
 *
 * Контракт этого слоя (MANIFEST §46, §47):
 *
 *  1. Все *_process / *_apply функции:
 *       - не аллоцируют память;
 *       - не делают I/O;
 *       - не используют глобальное состояние;
 *       - безопасны для realtime-потока.
 *
 *  2. Состояние (*_t) — POD. Его аллоцирует и инициализирует холодная
 *     сторона (Nim), audio thread только читает/пишет поля состояния.
 *     Никаких malloc внутри ядер.
 *
 *  3. Состояние ноды и её descriptor — разные вещи (MANIFEST §47).
 *     Descriptor описывает порты/параметры, состояние — только DSP-переменные.
 *
 *  4. in == out разрешено там, где это не противоречит алгоритму.
 *
 *  5. -ffast-math не используется (см. config.nims): NaN/Inf обязаны
 *     корректно проходить через ядро, иначе отказ одной ноды убивает
 *     весь микс.
 * ========================================================================= */

#ifndef EUT_DSP_H
#define EUT_DSP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * Переносимость и SIMD-диспетчеризация
 *
 * target_clones собирает несколько версий функции (avx2 + скалярную) и
 * выбирает лучшую один раз за процесс через IFUNC. В audio thread это
 * не стоит ничего, зато не нужно ни -march=native (ломает переносимость),
 * ни ручного dispatch в каждом process().
 * ------------------------------------------------------------------------ */
/*
 * target_clones раскрывается в IFUNC-резолвер, а его поддерживают только
 * ELF-платформы. На Windows (PE/COFF, MinGW) GCC отвечает ошибкой
 * «the call requires 'ifunc', which is not supported by this target»,
 * а на macOS (Mach-O) тот же признак отсутствует. Признак __ELF__
 * выставлен ровно там, где IFUNC реально работает (Linux/BSD).
 */
#if (defined(__x86_64__) || defined(_M_X64)) && defined(__ELF__) && \
    (defined(__GNUC__) || defined(__clang__))
  #define EUT_TARGET_CLONES __attribute__((target_clones("avx2", "default")))
  #define EUT_HAS_SIMD_DISPATCH 1
#else
  #define EUT_TARGET_CLONES
  #define EUT_HAS_SIMD_DISPATCH 0
#endif

#define EUT_PI_F       3.14159265358979323846f
#define EUT_TWO_PI_F   6.28318530717958647692f

/* Пределы Core (signal_types.nim): нода не должна выходить за контракт. */
#define EUT_MAX_CHANNELS 8
#define EUT_MAX_BLOCK    4096

/* Gain curve компрессора живёт в состоянии: 1024 фрейма достаточно
   для любого разумного block size. */
#define EUT_COMP_MAX_BLOCK 1024

/* ---------------------------------------------------------------------------
 * Базовые утилиты состояния
 * ------------------------------------------------------------------------ */

/* Убирает subnormals. Рекурсивные фильтры и feedback-задержки ими
   наполняются экспоненциальным хвостом; subnormal-операции на некоторых
   CPU стоят сотни циклов и проваливают дедлайн аудиоблока. */
static inline float eut_flush(float x) {
  float a = x < 0.0f ? -x : x;
  return (a < 1e-25f) ? 0.0f : x;
}

static inline float eut_clampf(float v, float lo, float hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}

/* Жёсткий потолок обратной связи: защита от самовозбуждения,
   из-за которого процесс уходит в +inf и «съедает» весь микс. */
static inline float eut_safety_clip(float x) {
  return eut_clampf(x, -8.0f, 8.0f);
}

static inline float eut_db_to_lin(float db) {
  /* exp2 быстрее и стабильнее, чем powf(10, x/20). */
  return (float)__builtin_exp2f(db * (1.0f / 6.0205999132796239f));
}

static inline float eut_lin_to_db(float lin) {
  if (lin <= 1e-9f) return -180.0f;
  return 6.0205999132796239f * (float)__builtin_log2f(lin);
}


/* ===========================================================================
 * Biquad (TDF-II): одно состояние на канал аудио
 * ========================================================================= */

typedef enum {
  EUT_BIQUAD_LOWPASS  = 0,
  EUT_BIQUAD_HIGHPASS = 1,
  EUT_BIQUAD_BANDPASS = 2,   /* пиковое усиление 0 dB */
  EUT_BIQUAD_NOTCH    = 3,
  EUT_BIQUAD_PEAK     = 4,
  EUT_BIQUAD_LOWSHELF = 5,
  EUT_BIQUAD_HIGHSHELF = 6,
  EUT_BIQUAD_COUNT
} EutBiquadKind;

typedef struct {
  float b0, b1, b2;
  float a1, a2;
  float z1, z2;
} EutBiquadState;

/* Пересчёт коэффициентов по RBJ Audio EQ Cookbook.
   Частота и Q зажимаются внутрь устойчивой области, поэтому «дикий»
   параметр от пользователя не может сделать фильтр неустойчивым. */
void eut_biquad_design(EutBiquadState *st, int kind,
                       float sampleRate, float freq, float q, float gainDb);
void eut_biquad_reset(EutBiquadState *st);
void eut_biquad_process(EutBiquadState *st, const float *in, float *out, int n);

/* Один сэмпл: нужен нодам для interleaved-буферов, где нельзя передать
   в C непрерывный указатель на канал. Основной путь — eut_biquad_process. */
float eut_biquad_process_one(EutBiquadState *st, float x);

/* ===========================================================================
 * SVF (state variable filter, TPT/Zavalishin), 12 dB на октаву
 * ========================================================================= */

typedef enum {
  EUT_SVF_LOWPASS  = 0,
  EUT_SVF_HIGHPASS = 1,
  EUT_SVF_BANDPASS = 2,
  EUT_SVF_NOTCH    = 3,
  EUT_SVF_COUNT
} EutSvfKind;

typedef struct {
  float ic1, ic2;   /* состояние Topology Preserving Transform */
  float g, k;
  float a1, a2, a3;
} EutSvfState;

void eut_svf_design(EutSvfState *st, int kind,
                    float sampleRate, float cutoff, float resonance);
void eut_svf_reset(EutSvfState *st);
void eut_svf_process(EutSvfState *st, int kind,
                     const float *in, float *out, int n);

/* Один сэмпл — см. eut_biquad_process_one. */
float eut_svf_process_one(EutSvfState *st, int kind, float x);

/* ===========================================================================
 * Осцилляторы (band-limited через polyBLEP)
 * ========================================================================= */

typedef enum {
  EUT_OSC_SINE     = 0,
  EUT_OSC_SAW      = 1,
  EUT_OSC_SQUARE   = 2,
  EUT_OSC_TRIANGLE = 3,
  EUT_OSC_COUNT
} EutOscKind;

typedef struct {
  float phase;       /* [0, 1) */
  float inc;         /* приращение фазы на сэмпл */
  float pulseWidth;  /* [0.05, 0.95] */
} EutOscState;

void eut_osc_init(EutOscState *st, float sampleRate, float freq);
void eut_osc_set_freq(EutOscState *st, float sampleRate, float freq);
void eut_osc_set_pulse_width(EutOscState *st, float width);
void eut_osc_reset(EutOscState *st);

/* Моно-рендер в out[0..n). */
void eut_osc_render(EutOscState *st, int kind, float *out, int n, float gain);

/* Стерео-рендер с расстройкой детюна в центах: два независимых инкремента
   фазы, левый и правый каналы не коррелированы. */
void eut_osc_render_stereo(EutOscState *st, int kind,
                           float *outL, float *outR, int n,
                           float gain, float detuneCents);
/* ===========================================================================
 * Микс: gain, pan, bus
 * ========================================================================= */

/* Mono gain. in == out разрешено. */
EUT_TARGET_CLONES
void eut_gain_apply(const float *in, float *out, int n, float gain);

/* Interleaved gain: n — количество float-семплов (frames * channels). */
EUT_TARGET_CLONES
void eut_gain_apply_interleaved(const float *in, float *out, int n, float gain);

/* Constant-power pan. pan: -1 (left) .. 0 (center) .. +1 (right). */
void eut_pan_gains(float pan, float *gainL, float *gainR);

EUT_TARGET_CLONES
void eut_pan_apply(const float *inL, const float *inR,
                   float *outL, float *outR, int n, float gainL, float gainR);

/* Суммирование шин в dst. numSources <= EUT_MAX_CHANNELS,
   каждый src — interleaved, channels одинаковы у всех. */
EUT_TARGET_CLONES
void eut_mix_bus(const float *const *srcs, int numSources,
                 float *dst, int frames, int channels);

/* ===========================================================================
 * Компрессор (feed-forward: детектор + gain computer)
 *
 * Детектор и применение разделены намеренно: так хост сам решает
 * вопрос stereo link, а C-ядро остаётся одноканальным и тривиальным.
 * ========================================================================= */

typedef enum {
  EUT_COMP_PEAK = 0,
  EUT_COMP_RMS  = 1,
  EUT_COMP_COUNT
} EutCompDetector;

typedef struct {
  float sampleRate;
  int   detector;        /* EutCompDetector */
  int   channels;

  float attackCoef;      /* one-pole коэффициенты */
  float releaseCoef;
  float avgCoef;         /* усреднение для RMS-детектора */

  float thresholdDb;
  float slope;           /* 1 / ratio */
  float kneeDb;
  float makeupLin;

  float env;             /* текущий уровень детектора, линейный */
  float gainLin;         /* текущая линейная gain (<= 1) */
  float gainDb;          /* gain reduction, <= 0 */

  /* Размер задан литералом, а не макросом EUT_COMP_MAX_BLOCK:
     Nim разбирает скомпилированные .c файлы (вместе с #include этого
     заголовка) и НЕ разворачивает макросы — макрос внутри объявления
     поля ломает разбор структуры и «съедает» имена полей на стороне Nim. */
  float gainCurve[1024];
} EutComp;

void eut_comp_init(EutComp *c, int channels, int detector, float sampleRate);
void eut_comp_set_params(EutComp *c, float thresholdDb, float ratio,
                         float kneeDb, float attackSec, float releaseSec,
                         float makeupDb);
void eut_comp_reset(EutComp *c);

/* Шаг 1: анализ блока, заполнение gainCurve[0..n) (линейная gain). */
void eut_comp_detect(EutComp *c, const float *in, int n);

/* Шаг 2: применение рассчитанной кривой к каналу. in == out разрешено. */
EUT_TARGET_CLONES
void eut_comp_apply(const float *gainCurve, const float *in, float *out, int n);

float eut_comp_gain_db(const EutComp *c);

/* Значение кривой gain в конкретном сэмпле блока.
   Нужно нодам для interleaved-буферов, где нельзя отдать C непрерывный
   указатель на канал и приходится идти по одному сэмплу. */
float eut_comp_gain_at(const EutComp *c, int index);

/* ===========================================================================
 * Задержка (stereo, дробная, интерполяция Catmull-Rom)
 *
 * Память под кольцо выделяет хост (Nim) и передаёт в eut_delay_init:
 * ядро ничего не аллоцирует само.
 * ========================================================================= */

typedef struct {
  float *buf;        /* interleaved stereo, capacity кадров */
  int    capacity;   /* в кадрах */
  int    writePos;

  float delayL;      /* в кадрах, дробное значение допустимо */
  float delayR;
  float feedback;
  float mix;
  int   pingPong;

  float lpStateL, lpStateR; /* сглаживатель в feedback-цепи */
} EutDelay;

void eut_delay_init(EutDelay *d, float *memory, int capacityFrames);
void eut_delay_reset(EutDelay *d);
void eut_delay_set(EutDelay *d, float sampleRate,
                   float timeLeftSec, float timeRightSec,
                   float feedback, float mix, int pingPong);
void eut_delay_process(EutDelay *d, const float *inL, const float *inR,
                       float *outL, float *outR, int n);

/* ===========================================================================
 * Насыщение (soft clip)
 * ========================================================================= */

EUT_TARGET_CLONES
void eut_saturate(float *buf, int n, float drive, float ceiling);

/* ===========================================================================
 * ABI-проверка
 *
 * sizeof C-структуры нельзя получить на стороне Nim без completeStruct,
 * а completeStruct запрещает доступ к полям по имени. Поэтому размеры
 * отдаются наружу явными функциями и сверяются в тестах.
 * ======================================================================= */
int eut_abi_sizeof_biquad(void);
int eut_abi_sizeof_svf(void);
int eut_abi_sizeof_osc(void);
int eut_abi_sizeof_noise(void);
int eut_abi_sizeof_comp(void);
int eut_abi_sizeof_delay(void);

#ifdef __cplusplus
}
#endif

#endif /* EUT_DSP_H */


/* ===========================================================================
 * Шум
 * ========================================================================= */

typedef enum {
  EUT_NOISE_WHITE = 0,
  EUT_NOISE_PINK  = 1,
  EUT_NOISE_BROWN = 2,
  EUT_NOISE_COUNT
} EutNoiseKind;

typedef struct {
  uint32_t rng;
  float b0, b1, b2, b3, b4, b5, b6;  /* pink: фильтр Paul Kellet */
  float brown;                       /* brown: интегратор с утечкой */
} EutNoiseState;

void eut_noise_init(EutNoiseState *st, uint32_t seed);
void eut_noise_render(EutNoiseState *st, int kind, float *out, int n, float gain);

