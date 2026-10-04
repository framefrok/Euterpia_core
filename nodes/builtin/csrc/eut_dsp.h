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
/*
 * Под ThreadSanitizer IFUNC-резолверы исполняются динамическим загрузчиком
 * до готовности рантайма санитайзера, и TSan на них падает SIGSEGV
 * (проверено на прогоне tests/unit/all_tests.nim). Для инструментальных
 * сборок SIMD-диспетчеризацию выключаем: скалярная версия корректна,
 * а цель таких прогонов — гонки, а не скорость.
 */
#if defined(__SANITIZE_THREAD__)
  #define EUT_UNDER_TSAN 1
#elif defined(__has_feature)
  #if __has_feature(thread_sanitizer)
    #define EUT_UNDER_TSAN 1
  #endif
#endif
#ifndef EUT_UNDER_TSAN
  #define EUT_UNDER_TSAN 0
#endif

#if (defined(__x86_64__) || defined(_M_X64)) && defined(__ELF__) && \
    (defined(__GNUC__) || defined(__clang__)) && !EUT_UNDER_TSAN
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

/* Gain curve компрессора живёт в состоянии. Размер обязан покрывать
   ЛЮБОЙ легальный блок (EUT_MAX_BLOCK), иначе применение кривой читает
   память за границей массива: детектор клампит n, а apply/gain_at — нет
   (это был реальный баг: на блоке > 1024 хвост блока глушился). */
#define EUT_COMP_MAX_BLOCK 4096
_Static_assert(EUT_COMP_MAX_BLOCK >= EUT_MAX_BLOCK,
               "EUT_COMP_MAX_BLOCK must cover EUT_MAX_BLOCK");

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
  float phase;       /* [0, 1) — фаза левого канала */
  float inc;         /* приращение фазы на сэмпл */
  float pulseWidth;  /* [0.05, 0.95] */
  float phaseR;      /* [0, 1) — фаза правого канала (detune), непрерывная */
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
  float rmsEnv;          /* усреднённая МОЩНОСТЬ — отдельно от огибающей env */
  float gainLin;         /* текущая линейная gain (<= 1) */
  float gainDb;          /* gain reduction, <= 0 */

  /* Размер задан литералом, а не макросом EUT_COMP_MAX_BLOCK:
     Nim разбирает скомпилированные .c файлы (вместе с #include этого
     заголовка) и НЕ разворачивает макросы — макрос внутри объявления
     поля ломает разбор структуры и «съедает» имена полей на стороне Nim.
     Литерал обязан совпадать с EUT_COMP_MAX_BLOCK и с Nim-зеркалом
     (nodes/builtin/native/eut_native.nim); соответствие проверяется
     compile-time assert'ами здесь и ниже. */
  float gainCurve[4096];
} EutComp;

_Static_assert(sizeof(((EutComp *)0)->gainCurve) ==
               EUT_COMP_MAX_BLOCK * sizeof(float),
               "gainCurve must match EUT_COMP_MAX_BLOCK");

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
 * Инструменты: полифония, ADSR, панорама на голос
 *
 * Четыре ядра:
 *   EutOrgan  — аддитивный орган (тоновые колёса, морфинг регистров);
 *   EutPiano  — двухоператорный FM-«электророяль» + молоточковый шум,
 *               педаль сустейна и две расстроенные «струны» на голос;
 *   EutGuitar — электрогитара на Karplus-Strong с дробным чтением,
 *               palm mute, насыщением усилителя и вибрато;
 *   EutDrums  — синтезированные куски (тон + шум + металлическая группа).
 *
 * Контракт тот же, что у остальных ядер этого файла, плюс три уточнения:
 *
 *   1. Вся память (состояние движка и массив голосов) выделяется хостом
 *      (Nim) на холодной стороне и передаётся в *_init. Ядро не аллоцирует
 *      ничего — ни при init, ни на нотном событии: note_on обязан быть
 *      безопасен для audio thread.
 *
 *   2. *_process ДОБАВЛЯЕТ звук в outL/outR (не перезаписывает): голоса
 *      суммируются в один буфер. Вызывающий обязан очистить буфер до
 *      вызова. `stride` кодирует раскладку: 1 — planar (outL и outR —
 *      непрерывные каналы), 2 — interleaved (outL указывает на левый сэмпл
 *      кадра, outR — на правый). Один и тот же код обслуживает оба случая.
 *
 *   3. ГПСЧ засевается детерминированно (note + номер голоса + счётчик
 *      событий), поэтому один и тот же проект даёт байт-в-байт один и тот
 *      же рендер. Иначе golden-сравнение в CI было бы невозможно.
 * ========================================================================= */

/* Общий голос: огибающая, частота, панорама, ГПСЧ. Все голосовые
   структуры конкретных движков НАЧИНАЮТСЯ с этого поля, поэтому общая
   часть обрабатывается одним кодом (см. inst_voice_step). */
typedef struct {
  int   active;     /* голос звучит */
  int   held;       /* клавиша удержана */
  int   pedal;      /* клавиша отпущена, но удержана педалью */
  int   note;       /* номер MIDI */
  int   seq;        /* порядок запуска: различает голоса при выборе на steal */
  float vel;        /* 0..1 */
  float freq;       /* Гц, без модуляции (бенд и вибрато добавляются позже) */
  float amp;        /* амплитудная огибающая (==1 в пике атаки) */
  float ampInc;     /* прирост огибающей за сэмпл на атаке */
  float ampCoef;    /* множитель затухания до sustain за сэмпл */
  float sustain;    /* уровень удержания 0..1 */
  float relCoef;    /* множитель release за сэмпл */
  float amp2;       /* вторая огибающая: щипок, молоточек, шум куска */
  float amp2Inc;
  float amp2Coef;
  float gainL, gainR;
  uint32_t rng;
} EutInstVoice;

#define EUT_INST_ORGAN_PARTIALS 8
#define EUT_INST_DRUM_METAL     6

/* --- орган ----------------------------------------------------------------- */

typedef struct {
  EutInstVoice v;
  float ph[EUT_INST_ORGAN_PARTIALS];   /* фазы частичных (регистров) */
  float dph[EUT_INST_ORGAN_PARTIALS];
  float clickLp;                       /* сглаживание щелчка клавиши */
} EutOrganVoice;

typedef struct {
  EutOrganVoice *voices;
  int   voiceCount;
  float sampleRate;
  float bars;        /* морфинг регистров: 0 — флейта, 1 — все регистры */
  float tone;        /* яркость: приглушает верхние регистры */
  float clickLevel;  /* уровень щелчка клавиши */
  float vibrato;     /* глубина вибрато, центы */
  float pan;
  float level;
  float lfoPhase, lfoInc;
  float reg[EUT_INST_ORGAN_PARTIALS];  /* усиления регистров, считает set() */
  int   seqCounter;  /* счётчик запусков: различает голоса при steal */
  int   active;      /* сколько голосов звучало в прошлом process() */
} EutOrgan;

void eut_organ_init(EutOrgan *g, EutOrganVoice *voices, int voiceCount, float sampleRate);
void eut_organ_reset(EutOrgan *g);
void eut_organ_set(EutOrgan *g, float bars, float tone, float clickLevel,
                   float vibratoCents, float pan, float level);
void eut_organ_note_on(EutOrgan *g, int note, float velocity);
void eut_organ_note_off(EutOrgan *g, int note);
void eut_organ_all_off(EutOrgan *g);
EUT_TARGET_CLONES
void eut_organ_process(EutOrgan *g, float *outL, float *outR, int stride,
                       int n, float bendSemitones, float modCents);

/* --- пианино --------------------------------------------------------------- */

typedef struct {
  EutInstVoice v;
  float phA, dphA, phB, dphB;         /* несущие двух «струн» */
  float modA, dmodA, modB, dmodB;     /* модуляторы: индекс яркости */
  float modIndex;
  float modCoef;                      /* спад индекса модуляции за сэмпл */
  float hammerLp;                     /* сглаживание молоточкового шума */
} EutPianoVoice;

typedef struct {
  EutPianoVoice *voices;
  int   voiceCount;
  float sampleRate;
  float tone;      /* яркость: индекс модуляции и срез молоточка */
  float decay;     /* время затухания струны, с */
  float detune;    /* центы расстройки между «струнами» */
  float hammer;    /* уровень молоточкового шума */
  float release;   /* время отпускания клавиши, с */
  float pan;
  float level;
  int   pedalDown; /* педаль сустейна нажата */
  int   seqCounter;
  int   active;
} EutPiano;

void eut_piano_init(EutPiano *g, EutPianoVoice *voices, int voiceCount, float sampleRate);
void eut_piano_reset(EutPiano *g);
void eut_piano_set(EutPiano *g, float tone, float decay, float detuneCents,
                   float hammer, float release, float pan, float level);
void eut_piano_note_on(EutPiano *g, int note, float velocity);
void eut_piano_note_off(EutPiano *g, int note);
void eut_piano_pedal(EutPiano *g, int down);
void eut_piano_all_off(EutPiano *g);
EUT_TARGET_CLONES
void eut_piano_process(EutPiano *g, float *outL, float *outR, int stride,
                       int n, float bendSemitones, float modCents);

/* --- гитара ---------------------------------------------------------------- */

typedef struct {
  EutInstVoice v;
  int   offset;         /* смещение линии в общей памяти, кадров */
  int   len;            /* длина линии, кадров (меньше — выше тон) */
  float rp;             /* дробный указатель чтения/записи, 0..len */
  float damp;           /* затухание за сэмпл, 0..1 */
  float lp;             /* первый полюс демпфера струны */
  float lp2;            /* второй полюс: мягче спад ВЧ-гармоник */
  float dcIn, dcOut;    /* блокировка постоянной составляющей */
  float bend;           /* текущий изгиб, полутоны */
  float pitchEnv;       /* просадка строя после щипка, доля тона */
  float pitchEnvCoef;   /* скорость возврата к строю за сэмпл */
} EutGuitarVoice;

typedef struct {
  EutGuitarVoice *voices;
  int   voiceCount;
  int   lineCap;        /* вместимость одной линии, кадров */
  float *memory;        /* voiceCount * lineCap; выделяет хост */
  float sampleRate;
  float pick;           /* позиция щипка 0..1 (гребенчатый фильтр) */
  float damping;        /* затухание струны за период */
  float tone;           /* пост-фильтр кабинета 0..1 */
  float drive;          /* насыщение усилителя 0..1 */
  float mute;           /* palm mute 0..1 */
  float release;        /* время отпускания, с */
  float pan;
  float level;
  float toneLpL, toneLpR;
  float bodyLp;         /* тёплый низ: параллельный медленный ФНЧ */
  float bodyCoef;       /* срез тела ~200–320 Гц, зависит от tone */
  float bodyBoost;      /* глубина подмешивания низа, 0..0.5 */
  int   seqCounter;
  int   active;
} EutGuitar;

void eut_guitar_init(EutGuitar *g, EutGuitarVoice *voices, int voiceCount,
                     float *memory, int lineCap, float sampleRate);
void eut_guitar_reset(EutGuitar *g);
void eut_guitar_set(EutGuitar *g, float pick, float damping, float tone,
                    float drive, float mute, float release, float pan, float level);
void eut_guitar_note_on(EutGuitar *g, int note, float velocity);
void eut_guitar_note_off(EutGuitar *g, int note);
void eut_guitar_all_off(EutGuitar *g);
EUT_TARGET_CLONES
void eut_guitar_process(EutGuitar *g, float *outL, float *outR, int stride,
                        int n, float bendSemitones, float modCents);

/* --- барабаны -------------------------------------------------------------- */

enum {
  EUT_DRUM_KICK = 0,
  EUT_DRUM_SNARE,
  EUT_DRUM_RIM,
  EUT_DRUM_CLAP,
  EUT_DRUM_TOM_LOW,
  EUT_DRUM_TOM_MID,
  EUT_DRUM_TOM_HIGH,
  EUT_DRUM_HAT_CLOSED,
  EUT_DRUM_HAT_PEDAL,
  EUT_DRUM_HAT_OPEN,
  EUT_DRUM_CRASH,
  EUT_DRUM_RIDE,
  EUT_DRUM_PIECE_COUNT
};

typedef struct {
  EutInstVoice v;
  int   piece;
  float pitch, pitchTarget, pitchCoef;   /* огибающая высоты */
  float tonePh[2], toneDph[2];
  float metalPh[EUT_INST_DRUM_METAL], metalDph[EUT_INST_DRUM_METAL];
  float noiseLp, noiseHp;
  float noiseLpCoef, noiseHpCoef;  /* полоса шума: свой для каждого куска */
  float mixNoise, mixMetal;        /* доли шума и металла в миксе */
  float drive;
  float gain;
} EutDrumVoice;

typedef struct {
  EutDrumVoice *voices;
  int   voiceCount;
  float sampleRate;
  float tune;     /* множитель высоты */
  float decay;    /* множитель времени затухания */
  float snappy;   /* доля шума (малый, хэты) */
  float tone;     /* яркость 0..1 */
  float drive;
  float pan;
  float level;
  int   seqCounter;
  int   active;
} EutDrums;

/* Нота MIDI -> кусок установки; -1 — нота вне карты (звука не будет).
   Карта GM-совместимая, но не полная: нота вне её честно молчит, а не
   превращается в случайный кусок. */
int eut_drums_piece_for_note(int note);

void eut_drums_init(EutDrums *g, EutDrumVoice *voices, int voiceCount, float sampleRate);
void eut_drums_reset(EutDrums *g);
void eut_drums_set(EutDrums *g, float tune, float decay, float snappy,
                   float tone, float drive, float pan, float level);
void eut_drums_note_on(EutDrums *g, int note, float velocity);
void eut_drums_note_off(EutDrums *g, int note);
void eut_drums_all_off(EutDrums *g);
EUT_TARGET_CLONES
void eut_drums_process(EutDrums *g, float *outL, float *outR, int stride, int n);

/* --- флейта ---------------------------------------------------------------- */

typedef struct {
  EutInstVoice v;
  float ph, dph;        /* основная фаза (почти синус) */
  float breathLp, breathHp;  /* полоса дыхательного шума */
  float chiff;          /* короткий шумовой «чиф» атаки */
  float vibAmp;         /* задержанное вибрато: растёт после атаки */
} EutFluteVoice;

typedef struct {
  EutFluteVoice *voices;
  int   voiceCount;
  float sampleRate;
  float tone;       /* яркость: доля верхних гармоник и шума */
  float breath;     /* уровень дыхания */
  float vibrato;    /* глубина вибрато, центы */
  float pan;
  float level;
  float lfoPhase, lfoInc;
  int   seqCounter;
  int   active;
} EutFlute;

void eut_flute_init(EutFlute *g, EutFluteVoice *voices, int voiceCount, float sampleRate);
void eut_flute_reset(EutFlute *g);
void eut_flute_set(EutFlute *g, float tone, float breath, float vibratoCents,
                   float pan, float level);
void eut_flute_note_on(EutFlute *g, int note, float velocity);
void eut_flute_note_off(EutFlute *g, int note);
void eut_flute_all_off(EutFlute *g);
EUT_TARGET_CLONES
void eut_flute_process(EutFlute *g, float *outL, float *outR, int stride,
                       int n, float bendSemitones, float modCents);

/* --- волынка --------------------------------------------------------------- */

typedef struct {
  EutInstVoice v;
  float ph, dph;        /* шантир (мелодия) */
  float lp, hp;         /* формирование «тростникового» тембра */
} EutBagpipeVoice;

typedef struct {
  EutBagpipeVoice *voices;
  int   voiceCount;
  float sampleRate;
  float tone;        /* яркость шантира */
  float droneLevel;  /* уровень бурдона */
  float droneFreq;   /* частота бурдона, Гц */
  float pan;
  float level;
  float dronePh1, dronePh2;  /* бурдон: тон и квинта выше */
  float droneAmp;            /* плавное включение бурдона (без щелчка) */
  float droneCoef;
  int   seqCounter;
  int   active;
} EutBagpipe;

void eut_bagpipe_init(EutBagpipe *g, EutBagpipeVoice *voices, int voiceCount, float sampleRate);
void eut_bagpipe_reset(EutBagpipe *g);
void eut_bagpipe_set(EutBagpipe *g, float tone, float droneLevel, float droneFreq,
                     float pan, float level);
void eut_bagpipe_note_on(EutBagpipe *g, int note, float velocity);
void eut_bagpipe_note_off(EutBagpipe *g, int note);
void eut_bagpipe_all_off(EutBagpipe *g);
EUT_TARGET_CLONES
void eut_bagpipe_process(EutBagpipe *g, float *outL, float *outR, int stride, int n);

/* --- смычковые (струнный ансамбль) ----------------------------------------- */

typedef struct {
  EutInstVoice v;
  float ph;             /* фаза пилообразной волны */
  float lp1, lp2;       /* двухполюсный ФНЧ (яркость/корпус) */
  float detune;         /* микрорасстройка голоса (ансамбль), центы */
  float vibAmp;         /* задержанное вибрато */
} EutStringsVoice;

typedef struct {
  EutStringsVoice *voices;
  int   voiceCount;
  float sampleRate;
  float tone;       /* яркость: срез ФНЧ (0..1) */
  float vibrato;    /* глубина вибрато, центы */
  float ensemble;   /* разброс расстройки, центы */
  float pan;
  float level;
  float lfoPhase, lfoInc;
  float lpCoef;
  int   seqCounter;
  int   active;
} EutStrings;

void eut_strings_init(EutStrings *g, EutStringsVoice *voices, int voiceCount, float sampleRate);
void eut_strings_reset(EutStrings *g);
void eut_strings_set(EutStrings *g, float tone, float vibratoCents, float ensembleCents,
                     float pan, float level);
void eut_strings_note_on(EutStrings *g, int note, float velocity);
void eut_strings_note_off(EutStrings *g, int note);
void eut_strings_all_off(EutStrings *g);
EUT_TARGET_CLONES
void eut_strings_process(EutStrings *g, float *outL, float *outR, int stride,
                         int n, float bendSemitones, float modCents);

/* --- колокол (трубчатый/церковный, ингармонические частичные) -------------- */

#define EUT_INST_BELL_PARTIALS 8

typedef struct {
  EutInstVoice v;
  float ph[EUT_INST_BELL_PARTIALS];
  float dph[EUT_INST_BELL_PARTIALS];
  float amp[EUT_INST_BELL_PARTIALS];    /* затухание частичных */
  float ampCoef[EUT_INST_BELL_PARTIALS];
} EutBellVoice;

typedef struct {
  EutBellVoice *voices;
  int   voiceCount;
  float sampleRate;
  float tune;       /* множитель строя */
  float decay;      /* множитель затухания */
  float tone;       /* яркость (наклон частичных) */
  float pan;
  float level;
  int   seqCounter;
  int   active;
} EutBell;

void eut_bell_init(EutBell *g, EutBellVoice *voices, int voiceCount, float sampleRate);
void eut_bell_reset(EutBell *g);
void eut_bell_set(EutBell *g, float tune, float decay, float tone, float pan, float level);
void eut_bell_note_on(EutBell *g, int note, float velocity);
void eut_bell_note_off(EutBell *g, int note);
void eut_bell_all_off(EutBell *g);
EUT_TARGET_CLONES
void eut_bell_process(EutBell *g, float *outL, float *outR, int stride, int n);

/* --- щипковые (арфа, клавесин) --------------------------------------------- */

typedef struct {
  EutInstVoice v;
  int   offset;         /* начало линии струны в арене g->memory */
  int   len;            /* длина линии, кадров (период струны) */
  int   pos;            /* текущая позиция в линии */
  float damp;           /* множитель петли за сэмпл (затухание) */
  float lp;             /* петлевой ФНЧ (яркость струны) */
  float y1, y2;         /* резонатор корпуса (двухполюсный) */
  float a1, a2, bg;     /* его коэффициенты: y = bg*x + a1*y1 + a2*y2 */
} EutPluckVoice;

typedef struct {
  EutPluckVoice *voices;
  int   voiceCount;
  int   lineCap;        /* вместимость одной линии, кадров */
  float *memory;        /* voiceCount * lineCap; выделяет хост */
  float sampleRate;
  float tone;           /* яркость петлевого ФНЧ 0..1 */
  float damping;        /* затухание: 0 — короткий щипок, 1 — длинный звон */
  float pluck;          /* резкость щипка (шумовая атака) 0..1 */
  float body;           /* глубина резонатора корпуса 0..1 */
  float bodyHz;         /* частота корпуса, Гц */
  float pan;
  float level;
  int   seqCounter;
  int   active;
} EutPluck;

void eut_pluck_init(EutPluck *g, EutPluckVoice *voices, int voiceCount,
                    float *memory, int lineCap, float sampleRate);
void eut_pluck_reset(EutPluck *g);
void eut_pluck_set(EutPluck *g, float tone, float damping, float pluck,
                   float body, float bodyHz, float pan, float level);
void eut_pluck_note_on(EutPluck *g, int note, float velocity);
void eut_pluck_note_off(EutPluck *g, int note);
void eut_pluck_all_off(EutPluck *g);
EUT_TARGET_CLONES
void eut_pluck_process(EutPluck *g, float *outL, float *outR, int stride, int n);

/* --- свирель/блокфлейта (деревянный духовой) ------------------------------- */

typedef struct {
  EutInstVoice v;
  float ph, dph;
  float breathLp, breathHp;
  float chiff;
  float vibAmp;
} EutRecorderVoice;

typedef struct {
  EutRecorderVoice *voices;
  int   voiceCount;
  float sampleRate;
  float tone;       /* яркость (доля верхних гармоник) */
  float breath;     /* дыхание/шум 0..1 */
  float vibrato;    /* глубина, центы */
  float pan;
  float level;
  float lfoPhase, lfoInc;
  int   seqCounter;
  int   active;
} EutRecorder;

void eut_recorder_init(EutRecorder *g, EutRecorderVoice *voices, int voiceCount,
                       float sampleRate);
void eut_recorder_reset(EutRecorder *g);
void eut_recorder_set(EutRecorder *g, float tone, float breath, float vibratoCents,
                      float pan, float level);
void eut_recorder_note_on(EutRecorder *g, int note, float velocity);
void eut_recorder_note_off(EutRecorder *g, int note);
void eut_recorder_all_off(EutRecorder *g);
EUT_TARGET_CLONES
void eut_recorder_process(EutRecorder *g, float *outL, float *outR, int stride,
                          int n, float bendSemitones, float modCents);

/* --- медь (труба/валторна) ------------------------------------------------- */

typedef struct {
  EutInstVoice v;
  float ph;
  float lp1, lp2;       /* мягкий ФНЧ (яркость) */
  float f1y1, f1y2;     /* форманта меди (резонатор) */
  float f1a1, f1a2, f1g;
  float vibAmp;
} EutBrassVoice;

typedef struct {
  EutBrassVoice *voices;
  int   voiceCount;
  float sampleRate;
  float tone;       /* яркость/открытость раструба 0..1 */
  float rasp;       /* «жёсткость», шумовой призвук атаки 0..1 */
  float vibrato;    /* глубина, центы */
  float pan;
  float level;
  float lfoPhase, lfoInc;
  int   seqCounter;
  int   active;
} EutBrass;

void eut_brass_init(EutBrass *g, EutBrassVoice *voices, int voiceCount,
                    float sampleRate);
void eut_brass_reset(EutBrass *g);
void eut_brass_set(EutBrass *g, float tone, float rasp, float vibratoCents,
                   float pan, float level);
void eut_brass_note_on(EutBrass *g, int note, float velocity);
void eut_brass_note_off(EutBrass *g, int note);
void eut_brass_all_off(EutBrass *g);
EUT_TARGET_CLONES
void eut_brass_process(EutBrass *g, float *outL, float *outR, int stride,
                       int n, float bendSemitones, float modCents);

/* --- литавры (настраиваемый барабан) --------------------------------------- */

#define EUT_INST_TIMPANI_MODES 4

typedef struct {
  EutInstVoice v;
  float ph[EUT_INST_TIMPANI_MODES];
  float dph[EUT_INST_TIMPANI_MODES];
  float amp[EUT_INST_TIMPANI_MODES];
  float ampCoef[EUT_INST_TIMPANI_MODES];
  float noiseLp;
} EutTimpaniVoice;

typedef struct {
  EutTimpaniVoice *voices;
  int   voiceCount;
  float sampleRate;
  float tune;       /* общий строй, множитель */
  float decay;      /* множитель затухания */
  float tone;       /* яркость и шум атаки 0..1 */
  float pan;
  float level;
  int   seqCounter;
  int   active;
} EutTimpani;

void eut_timpani_init(EutTimpani *g, EutTimpaniVoice *voices, int voiceCount,
                      float sampleRate);
void eut_timpani_reset(EutTimpani *g);
void eut_timpani_set(EutTimpani *g, float tune, float decay, float tone,
                     float pan, float level);
void eut_timpani_note_on(EutTimpani *g, int note, float velocity);
void eut_timpani_note_off(EutTimpani *g, int note);
void eut_timpani_all_off(EutTimpani *g);
EUT_TARGET_CLONES
void eut_timpani_process(EutTimpani *g, float *outL, float *outR, int stride, int n);

/* --- хор (формантные гласные) ---------------------------------------------- */

#define EUT_INST_CHOIR_FORMANTS 3

typedef struct {
  EutInstVoice v;
  float ph;             /* фаза «голосовой щели» (источник) */
  float y1[EUT_INST_CHOIR_FORMANTS], y2[EUT_INST_CHOIR_FORMANTS];
  float a1[EUT_INST_CHOIR_FORMANTS], a2[EUT_INST_CHOIR_FORMANTS];
  float gain[EUT_INST_CHOIR_FORMANTS];
  float vibAmp;
} EutChoirVoice;

typedef struct {
  EutChoirVoice *voices;
  int   voiceCount;
  float sampleRate;
  float vowel;      /* 0 — «а», 0.5 — «о», 1 — «и» */
  float tone;       /* яркость источника 0..1 */
  float vibrato;    /* глубина, центы */
  float pan;
  float level;
  float lfoPhase, lfoInc;
  int   seqCounter;
  int   active;
} EutChoir;

void eut_choir_init(EutChoir *g, EutChoirVoice *voices, int voiceCount,
                    float sampleRate);
void eut_choir_reset(EutChoir *g);
void eut_choir_set(EutChoir *g, float vowel, float tone, float vibratoCents,
                   float pan, float level);
void eut_choir_note_on(EutChoir *g, int note, float velocity);
void eut_choir_note_off(EutChoir *g, int note);
void eut_choir_all_off(EutChoir *g);
EUT_TARGET_CLONES
void eut_choir_process(EutChoir *g, float *outL, float *outR, int stride,
                       int n, float bendSemitones, float modCents);


/* ===========================================================================
 * ABI-проверка
 *
 * sizeof C-структуры нельзя получить на стороне Nim без completeStruct,
 * а completeStruct запрещает доступ к полям по имени. Поэтому размеры
 * отдаются наружу явными функциями и сверяются в тестах.
 *
 * Инструменты отдают по два размера: состояние движка и один голос.
 * Хост (Nim) выделяет оба блока одним куском памяти и передаёт указатели
 * в *_init, поэтому размеры обязан знать именно он.
 * ======================================================================= */
int eut_abi_sizeof_biquad(void);
int eut_abi_sizeof_svf(void);
int eut_abi_sizeof_osc(void);
int eut_abi_sizeof_noise(void);
int eut_abi_sizeof_comp(void);
int eut_abi_sizeof_delay(void);

int eut_abi_sizeof_inst_voice(void);
int eut_abi_sizeof_organ_voice(void);
int eut_abi_sizeof_organ(void);
int eut_abi_sizeof_piano_voice(void);
int eut_abi_sizeof_piano(void);
int eut_abi_sizeof_guitar_voice(void);
int eut_abi_sizeof_guitar(void);
int eut_abi_sizeof_drum_voice(void);
int eut_abi_sizeof_drums(void);
int eut_abi_sizeof_flute_voice(void);
int eut_abi_sizeof_flute(void);
int eut_abi_sizeof_bagpipe_voice(void);
int eut_abi_sizeof_bagpipe(void);
int eut_abi_sizeof_strings_voice(void);
int eut_abi_sizeof_strings(void);
int eut_abi_sizeof_bell_voice(void);
int eut_abi_sizeof_bell(void);
int eut_abi_sizeof_pluck_voice(void);
int eut_abi_sizeof_pluck(void);
int eut_abi_sizeof_recorder_voice(void);
int eut_abi_sizeof_recorder(void);
int eut_abi_sizeof_brass_voice(void);
int eut_abi_sizeof_brass(void);
int eut_abi_sizeof_timpani_voice(void);
int eut_abi_sizeof_timpani(void);
int eut_abi_sizeof_choir_voice(void);
int eut_abi_sizeof_choir(void);

#ifdef __cplusplus
}
#endif

#endif /* EUT_DSP_H */

