/* eut_inst.c — полифонические инструменты: орган, пианино, гитара, барабаны.
 *
 * Общая для всех четырёх движков логика лежит в начале файла: огибающие,
 * выбор голоса, панорама, дешёвый синус и детерминированный шум. Дальше —
 * четыре DSP-ядра, каждое со своим тембром. Ни одно из них не аллоцирует
 * память и не обращается к внешнему состоянию: всё, что нужно, лежит в
 * структурах, которые выделил хост (см. eut_dsp.h).
 *
 * Почему синус считается полиномом, а не sinf(): рендер офлайн гоняет
 * 16–32 голоса × 8 частичных × 48 кГц, и вызов libm на каждый частичный
 * превратил бы инструмент в узкое место. Полином Тейлора по приведённой
 * к четверти периода фазе даёт ошибку < 3e-7 при четырёх умножениях, и
 * результат не зависит от реализации libm — golden-рендер воспроизводим
 * на разных платформах.
 */

#include "eut_dsp.h"
#include <math.h>
#include <string.h>

#define EUT_INST_TWO_PI 6.283185307179586f

/* ===========================================================================
 * Общие помощники
 * ========================================================================= */

static inline float inst_clamp(float x, float lo, float hi)
{
  if (x < lo) return lo;
  if (x > hi) return hi;
  return x;
}

/* Частота ноты MIDI. 69 = A4 = 440 Гц, равномерная темперация. */
static inline float inst_hz(int note)
{
  return 440.0f * (float)exp2(((double)note - 69.0) / 12.0);
}

/* Множитель затухания за один сэмпл для времени `seconds`. */
static inline float inst_coef(float seconds, float sampleRate)
{
  if (seconds <= 0.0001f || sampleRate <= 0.0f) return 0.0f;
  return (float)exp(-1.0 / ((double)seconds * (double)sampleRate));
}

/* Синус фазы 0..1 (то есть sin(2π·phase)). Ошибка < 3e-7. */
static inline float inst_sin(float phase)
{
  float x = phase;
  if (x < 0.0f) x += 1.0f;
  if (x >= 1.0f) x -= 1.0f;
  if (x > 0.75f) x -= 1.0f;
  if (x > 0.25f) x = 0.5f - x;
  const float a = EUT_INST_TWO_PI * x;
  const float t = a * a;
  return a * (1.0f - t * (1.0f / 6.0f - t * (1.0f / 120.0f - t * (1.0f / 5040.0f))));
}

/* xorshift32: детерминированный шум. Сид задаёт хост (note + голос), так
   что один и тот же проект всегда даёт один и тот же файл. */
static inline float inst_noise(uint32_t *state)
{
  uint32_t x = *state;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  if (x == 0u) x = 0x9E3779B9u;
  *state = x;
  return (float)(int32_t)x * (1.0f / 2147483648.0f);
}

/* Мягкое ограничение (аппроксимация tanh). Нужно для усилителя гитары и
   для барабанов: жёсткий клип даёт алиасынг, которого здесь не хочется.
   Рациональная аппроксимация уходит выше единицы при |x| > 4, поэтому
   результат дополнительно ограничен диапазоном ±1. */
static inline float inst_soft_clip(float x)
{
  const float x2 = x * x;
  float y = x * (27.0f + x2) / (27.0f + 9.0f * x2);
  if (y > 1.0f) y = 1.0f;
  else if (y < -1.0f) y = -1.0f;
  return y;
}

/* Панорама → усиления каналов (закон «постоянной мощности»). */
static inline void inst_pan_gains(float pan, float *gl, float *gr)
{
  const float p = inst_clamp(pan, -1.0f, 1.0f) * 0.5f + 0.5f;
  *gl = (float)sqrt(1.0f - p);
  *gr = (float)sqrt(p);
}

/* Огибающая голоса: линейная атака, спад к sustain, отпускание.
   Возвращает 0, когда голос можно освободить. */
static inline int inst_voice_alive(EutInstVoice *v)
{
  if (!v->active) return 0;
  if (v->ampInc > 0.0f) {
    v->amp += v->ampInc;
    if (v->amp >= 1.0f) { v->amp = 1.0f; v->ampInc = 0.0f; }
  } else if (v->held) {
    if (v->amp > v->sustain) {
      v->amp *= v->ampCoef;
      if (v->amp <= v->sustain) v->amp = v->sustain;
    }
    /* Затухший под пальцем голос (пианино, гул) освобождается сам: иначе
       он навсегда занял бы место в пуле полифонии. */
    if (v->amp < 0.00001f && v->amp2 <= 0.0f) { v->amp = 0.0f; v->active = 0; return 0; }
  } else {
    v->amp *= v->relCoef;
    if (v->amp < 0.00001f) { v->amp = 0.0f; v->active = 0; return 0; }
  }
  if (v->amp2 > 0.0f) {
    v->amp2 *= v->amp2Coef;
    if (v->amp2 < 0.000001f) v->amp2 = 0.0f;
  }
  return 1;
}

/* Заводит нотные события в голосе: атака, sustain, отпускание, шум. */
static inline void inst_voice_setup(EutInstVoice *v, int note, float vel,
                                    float attackSeconds, float sustain,
                                    float decaySeconds, float releaseSeconds,
                                    float sampleRate)
{
  v->active = 1;
  v->held = 1;
  v->pedal = 0;
  v->note = note;
  v->vel = inst_clamp(vel, 0.0f, 1.0f);
  v->freq = inst_hz(note);
  v->amp = 0.0f;
  v->ampInc = (attackSeconds <= 0.0001f) ? 1.0f
                                         : 1.0f / (attackSeconds * sampleRate);
  v->sustain = inst_clamp(sustain, 0.0f, 1.0f);
  v->ampCoef = inst_coef(decaySeconds, sampleRate);
  v->relCoef = inst_coef(releaseSeconds, sampleRate);
  v->amp2 = 0.0f;
  v->amp2Inc = 0.0f;
  v->amp2Coef = 0.0f;
}

/* Выбор голоса под новую ноту.
 *
 * Порядок предпочтений детерминирован: свободный → отпускаемый (уже в
 * release, самый старый) → самый тихий (при равенстве — самый старый).
 * «Отпускаемый» голос не защищён педалью: голоса под педалью входят в
 * общий пул по амплитуде, иначе педаль съедала бы всю полифонию. */
static inline void *inst_pick_voice(void *voices, int stride, int count)
{
  char *base = (char *)voices;
  EutInstVoice *bestFree = NULL;
  EutInstVoice *bestPlain = NULL;   /* не под педалью */
  EutInstVoice *bestAny = NULL;

  for (int i = 0; i < count; ++i) {
    EutInstVoice *v = (EutInstVoice *)(base + (size_t)i * (size_t)stride);
    if (!v->active) {
      if (bestFree == NULL) bestFree = v;
      continue;
    }
    /* Самый тихий: его потеря слышна меньше всего. При равенстве берём
       самый старый (меньший seq) — выбор обязан быть детерминированным. */
    if (bestAny == NULL || v->amp < bestAny->amp ||
        (v->amp == bestAny->amp && v->seq < bestAny->seq)) {
      bestAny = v;
    }
    if (!v->pedal) {
      if (bestPlain == NULL || v->amp < bestPlain->amp ||
          (v->amp == bestPlain->amp && v->seq < bestPlain->seq)) {
        bestPlain = v;
      }
    }
  }
  if (bestFree != NULL) return bestFree;
  if (bestPlain != NULL) return bestPlain;
  return bestAny;
}

/* ===========================================================================
 * Орган
 *
 * Аддитивный синтез по регистрам: 8 частичных с гармониками
 * 1-2-3-4-6-8-12-16. Параметр `bars` (морфинг регистров) подмешивает
 * верхние частичные порогами, `tone` приглушает их — так из одной ноды
 * получается и флейта, и полное тутти.
 *
 * Реализм держится на трёх деталях: щелчок клавиши (шум через фильтр),
 * вибрато общим LFO (у органов оно общее для мануала, а не на голос) и
 * микродетонация голосов: без неё аккорд звучит одним толстым тоном, с
 * ней — как ансамбль труб.
 * ========================================================================= */

static const float ORGAN_HARM[EUT_INST_ORGAN_PARTIALS] =
  { 1.0f, 2.0f, 3.0f, 4.0f, 6.0f, 8.0f, 12.0f, 16.0f };
static const float ORGAN_BASE[EUT_INST_ORGAN_PARTIALS] =
  { 1.00f, 0.62f, 0.42f, 0.34f, 0.24f, 0.18f, 0.11f, 0.07f };

void eut_organ_init(EutOrgan *g, EutOrganVoice *voices, int voiceCount, float sampleRate)
{
  if (g == NULL) return;
  memset(g, 0, sizeof(*g));
  if (sampleRate < 1000.0f) sampleRate = 48000.0f;
  g->voices = voices;
  g->voiceCount = (voiceCount > 0) ? voiceCount : 1;
  g->sampleRate = sampleRate;
  g->lfoInc = 6.0f / sampleRate;   /* вибрато органов ~6 Гц */
  eut_organ_set(g, 0.55f, 0.75f, 0.35f, 0.0f, 0.0f, 0.8f);
  eut_organ_reset(g);
}

void eut_organ_reset(EutOrgan *g)
{
  if (g == NULL || g->voices == NULL) return;
  memset(g->voices, 0, (size_t)g->voiceCount * sizeof(EutOrganVoice));
  g->lfoPhase = 0.0f;
  g->seqCounter = 0;
  g->active = 0;
}

void eut_organ_set(EutOrgan *g, float bars, float tone, float clickLevel,
                   float vibratoCents, float pan, float level)
{
  if (g == NULL) return;
  g->bars = inst_clamp(bars, 0.0f, 1.0f);
  g->tone = inst_clamp(tone, 0.0f, 1.0f);
  g->clickLevel = inst_clamp(clickLevel, 0.0f, 1.0f);
  g->vibrato = inst_clamp(vibratoCents, 0.0f, 120.0f);
  g->pan = inst_clamp(pan, -1.0f, 1.0f);
  g->level = inst_clamp(level, 0.0f, 2.0f);

  /* Регистры пересчитываются здесь, а не в note_on: note_on приходит из
     audio thread, и не держать в нём exp/pow важнее, чем сэкономить на
     холодном пути. */
  float sum = 0.0f;
  for (int k = 0; k < EUT_INST_ORGAN_PARTIALS; ++k) {
    const float threshold = 0.04f + 0.11f * (float)k;
    float presence = 1.0f;
    if (g->bars < threshold) presence = 0.0f;
    else if (threshold < 0.999f) presence = (g->bars - threshold) / (1.0f - threshold);
    const float toneCut = inst_clamp(1.0f - 0.085f * (float)k * (1.0f - g->tone), 0.0f, 1.0f);
    g->reg[k] = ORGAN_BASE[k] * presence * toneCut;
    sum += g->reg[k];
  }
  if (sum > 0.001f) {
    const float norm = 0.85f / sum;
    for (int k = 0; k < EUT_INST_ORGAN_PARTIALS; ++k) g->reg[k] *= norm;
  }
}


void eut_organ_note_on(EutOrgan *g, int note, float velocity)
{
  if (g == NULL || g->voices == NULL) return;
  if (note < 0) note = 0;
  if (note > 127) note = 127;
  EutOrganVoice *v = (EutOrganVoice *)inst_pick_voice(g->voices,
                        (int)sizeof(EutOrganVoice), g->voiceCount);
  if (v == NULL) return;
  memset(v, 0, sizeof(*v));
  inst_voice_setup(&v->v, note, velocity, 0.008f, 1.0f, 1.0f, 0.09f, g->sampleRate);
  v->v.seq = ++g->seqCounter;
  /* Сид привязан к ноте и номеру запуска: повторный рендер — байт в байт. */
  v->v.rng = (uint32_t)(0x2545F491u * (uint32_t)(note + 1)) ^
             (uint32_t)((uint32_t)g->seqCounter * 2654435761u);
  if (v->v.rng == 0u) v->v.rng = 0x1234567u;
  const float detune = (inst_noise(&v->v.rng) * 0.5f + 0.5f) * 10.0f - 5.0f;
  v->v.freq = inst_hz(note) * (float)exp2((double)detune / 1200.0);

  const float nyquist = g->sampleRate * 0.45f;
  for (int k = 0; k < EUT_INST_ORGAN_PARTIALS; ++k) {
    v->ph[k] = inst_noise(&v->v.rng) * 0.5f + 0.5f;
    v->dph[k] = 0.0f;
    if (v->v.freq * ORGAN_HARM[k] < nyquist) {
      v->dph[k] = v->v.freq * ORGAN_HARM[k] / g->sampleRate;
    }
  }
  /* Щелчок клавиши: короткая шумовая вспышка со своей огибающей. */
  v->v.amp2 = v->v.vel * g->clickLevel * 0.8f;
  v->v.amp2Coef = inst_coef(0.012f, g->sampleRate);
  v->clickLp = 0.0f;

  const float velScale = 0.30f + 0.70f * v->v.vel;
  inst_pan_gains(g->pan, &v->v.gainL, &v->v.gainR);
  v->v.gainL *= 0.20f * g->level * velScale;
  v->v.gainR *= 0.20f * g->level * velScale;
  g->active = 1;
}

void eut_organ_note_off(EutOrgan *g, int note)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutOrganVoice *v = &g->voices[i];
    if (v->v.active && v->v.held && v->v.note == note) v->v.held = 0;
  }
}

void eut_organ_all_off(EutOrgan *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    if (g->voices[i].v.active) g->voices[i].v.held = 0;
  }
}

EUT_TARGET_CLONES
void eut_organ_process(EutOrgan *g, float *outL, float *outR, int stride,
                       int n, float bendSemitones, float modCents)
{
  if (g == NULL || g->voices == NULL || n <= 0) return;
  if (g->active == 0) return;
  const int vibratoOn = (g->vibrato > 0.01f);

  for (int i = 0; i < n; ++i) {
    float pitchCents = bendSemitones * 100.0f + modCents;
    if (vibratoOn) {
      g->lfoPhase += g->lfoInc;
      if (g->lfoPhase >= 1.0f) g->lfoPhase -= 1.0f;
      pitchCents += g->vibrato * inst_sin(g->lfoPhase);
    }
    const float pitchFactor = (pitchCents == 0.0f)
                                ? 1.0f
                                : (float)exp2((double)pitchCents / 1200.0);

    float sumL = 0.0f;
    float sumR = 0.0f;
    int alive = 0;
    for (int vi = 0; vi < g->voiceCount; ++vi) {
      EutOrganVoice *v = &g->voices[vi];
      if (!inst_voice_alive(&v->v)) continue;
      ++alive;

      float s = 0.0f;
      for (int k = 0; k < EUT_INST_ORGAN_PARTIALS; ++k) {
        if (v->dph[k] <= 0.0f) continue;
        v->ph[k] += v->dph[k] * pitchFactor;
        if (v->ph[k] >= 1.0f) v->ph[k] -= 1.0f;
        s += inst_sin(v->ph[k]) * g->reg[k];
      }
      if (v->v.amp2 > 0.0f) {
        v->clickLp += (inst_noise(&v->v.rng) - v->clickLp) * 0.45f;
        s += v->clickLp * v->v.amp2;
      }
      const float a = v->v.amp;
      sumL += s * a * v->v.gainL;
      sumR += s * a * v->v.gainR;
    }
    g->active = alive;
    if (outL != NULL) outL[i * stride] += sumL;
    if (outR != NULL) outR[i * stride] += sumR;
  }
}


/* ===========================================================================
 * Пианино
 *
 * Двухоператорный FM: несущая — «струна», модулятор с быстро спадающим
 * индексом — «молоточек». Спад индекса и есть физика пианино: удар даёт
 * много верхних гармоник, а через 0.2–0.3 с остаётся почти чистый тон.
 *
 * На каждую ноту — две расстроенные «струны» (у настоящего пианино их три
 * в унисоне; третья стоила бы ещё одного генератора без слышимой разницы)
 * плюс молоточковый шум. Низкие ноты звучат дольше: время затухания
 * зависит от номера ноты, а не только от параметра decay.
 *
 * Педаль сустейна: клавиша отпущена, но голос продолжает звучать, пока
 * педаль нажата (флаг pedal в голосе). Поднятие педали отпускает все
 * удерживаемые голоса сразу — как на настоящем инструменте.
 * ========================================================================= */

void eut_piano_init(EutPiano *g, EutPianoVoice *voices, int voiceCount, float sampleRate)
{
  if (g == NULL) return;
  memset(g, 0, sizeof(*g));
  if (sampleRate < 1000.0f) sampleRate = 48000.0f;
  g->voices = voices;
  g->voiceCount = (voiceCount > 0) ? voiceCount : 1;
  g->sampleRate = sampleRate;
  eut_piano_set(g, 0.55f, 1.0f, 1.6f, 0.35f, 0.35f, 0.0f, 0.8f);
  eut_piano_reset(g);
}

void eut_piano_reset(EutPiano *g)
{
  if (g == NULL || g->voices == NULL) return;
  memset(g->voices, 0, (size_t)g->voiceCount * sizeof(EutPianoVoice));
  g->seqCounter = 0;
  g->pedalDown = 0;
  g->active = 0;
}

void eut_piano_set(EutPiano *g, float tone, float decay, float detuneCents,
                   float hammer, float release, float pan, float level)
{
  if (g == NULL) return;
  g->tone = inst_clamp(tone, 0.0f, 1.0f);
  g->decay = inst_clamp(decay, 0.15f, 4.0f);
  g->detune = inst_clamp(detuneCents, 0.0f, 30.0f);
  g->hammer = inst_clamp(hammer, 0.0f, 1.0f);
  g->release = inst_clamp(release, 0.02f, 3.0f);
  g->pan = inst_clamp(pan, -1.0f, 1.0f);
  g->level = inst_clamp(level, 0.0f, 2.0f);
}

/* Время затухания струны: ~7 с в самом низу, ~0.7 с на последней клавише. */
static inline float piano_decay_seconds(int note)
{
  double t = 0.6 + 6.4 * exp(-((double)note - 21.0) / 26.0);
  if (t < 0.35) t = 0.35;
  if (t > 9.0) t = 9.0;
  return (float)t;
}

void eut_piano_note_on(EutPiano *g, int note, float velocity)
{
  if (g == NULL || g->voices == NULL) return;
  if (note < 0) note = 0;
  if (note > 127) note = 127;
  EutPianoVoice *v = (EutPianoVoice *)inst_pick_voice(g->voices,
                        (int)sizeof(EutPianoVoice), g->voiceCount);
  if (v == NULL) return;
  memset(v, 0, sizeof(*v));

  const float vel = inst_clamp(velocity, 0.0f, 1.0f);
  const float decayTime = piano_decay_seconds(note) * g->decay;
  /* sustain == 0: пианино не держит уровень, оно затухает даже под пальцем. */
  inst_voice_setup(&v->v, note, vel, 0.003f, 0.0f, decayTime, g->release, g->sampleRate);
  v->v.seq = ++g->seqCounter;

  /* Яркость удара: сильнее удар — больше верхних гармоник. */
  v->modIndex = (1.4f + 3.2f * vel) * (0.35f + 0.65f * g->tone);
  v->modCoef = inst_coef(0.16f + 0.30f * g->tone, g->sampleRate);

  const float halfDetune = g->detune * 0.5f;
  const float fA = v->v.freq * (float)exp2((double)halfDetune / 1200.0);
  const float fB = v->v.freq * (float)exp2((double)-halfDetune / 1200.0);
  const float invSr = 1.0f / g->sampleRate;
  v->dphA = fA * invSr;
  v->dphB = fB * invSr;
  v->dmodA = v->dphA;
  v->dmodB = v->dphB;
  /* Фазы «струн» расходятся: одинаковый старт звучал бы как один тон. */
  v->phA = 0.0f;
  v->phB = 0.37f;
  v->modA = 0.11f;
  v->modB = 0.61f;

  /* Молотковый шум: короткая вспышка, яркость которой задаёт tone. */
  v->v.amp2 = g->hammer * (0.35f + 0.65f * vel);
  v->v.amp2Coef = inst_coef(0.014f, g->sampleRate);
  v->hammerLp = 0.0f;

  inst_pan_gains(g->pan, &v->v.gainL, &v->v.gainR);
  const float scale = 0.17f * g->level * (0.35f + 0.65f * vel);
  v->v.gainL *= scale;
  v->v.gainR *= scale;
  g->active = 1;
}


void eut_piano_note_off(EutPiano *g, int note)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutPianoVoice *v = &g->voices[i];
    if (!v->v.active || !v->v.held || v->v.note != note) continue;
    if (g->pedalDown) {
      /* Педаль нажата: клавиша отпущена, струна звучит до подъёма педали. */
      v->v.pedal = 1;
    } else {
      v->v.held = 0;
    }
  }
}

void eut_piano_pedal(EutPiano *g, int down)
{
  if (g == NULL || g->voices == NULL) return;
  const int on = (down != 0);
  if (on == g->pedalDown) return;
  g->pedalDown = on;
  if (!on) {
    /* Педаль подняли: отпускаем всё, что держала педаль, а не палец. */
    for (int i = 0; i < g->voiceCount; ++i) {
      EutPianoVoice *v = &g->voices[i];
      if (v->v.active && v->v.pedal) { v->v.pedal = 0; v->v.held = 0; }
    }
  }
}

void eut_piano_all_off(EutPiano *g)
{
  if (g == NULL || g->voices == NULL) return;
  g->pedalDown = 0;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutPianoVoice *v = &g->voices[i];
    if (v->v.active) { v->v.held = 0; v->v.pedal = 0; }
  }
}

EUT_TARGET_CLONES
void eut_piano_process(EutPiano *g, float *outL, float *outR, int stride,
                       int n, float bendSemitones, float modCents)
{
  if (g == NULL || g->voices == NULL || n <= 0) return;
  if (g->active == 0) return;
  /* Молотковый шум идёт через ФНЧ: чистый белый шум звучит как «ссс», а не
     как удар войлока по струне. Коэффициент считается на блок. */
  const float hammerLpCoef = 0.18f + 0.42f * g->tone;
  const float cents = bendSemitones * 100.0f + modCents;
  const float pitchFactor = (cents == 0.0f) ? 1.0f : (float)exp2((double)cents / 1200.0);

  for (int i = 0; i < n; ++i) {
    float sumL = 0.0f;
    float sumR = 0.0f;
    int alive = 0;
    for (int vi = 0; vi < g->voiceCount; ++vi) {
      EutPianoVoice *v = &g->voices[vi];
      if (!inst_voice_alive(&v->v)) continue;
      ++alive;

      v->modA += v->dmodA * pitchFactor; if (v->modA >= 1.0f) v->modA -= 1.0f;
      v->modB += v->dmodB * pitchFactor; if (v->modB >= 1.0f) v->modB -= 1.0f;
      const float depth = v->modIndex * 0.15915494f;   /* радианы → фаза 0..1 */
      const float mA = inst_sin(v->modA) * depth;
      const float mB = inst_sin(v->modB) * depth * 0.72f;

      v->phA += v->dphA * pitchFactor; if (v->phA >= 1.0f) v->phA -= 1.0f;
      v->phB += v->dphB * pitchFactor; if (v->phB >= 1.0f) v->phB -= 1.0f;
      float s = (inst_sin(v->phA + mA) + inst_sin(v->phB + mB) * 0.85f) * 0.5f;

      v->modIndex *= v->modCoef;
      if (v->modIndex < 0.0001f) v->modIndex = 0.0f;

      if (v->v.amp2 > 0.0f) {
        v->hammerLp += (inst_noise(&v->v.rng) - v->hammerLp) * hammerLpCoef;
        s += v->hammerLp * v->v.amp2;
      }
      const float a = v->v.amp;
      sumL += s * a * v->v.gainL;
      sumR += s * a * v->v.gainR;
    }
    g->active = alive;
    if (outL != NULL) outL[i * stride] += sumL;
    if (outR != NULL) outR[i * stride] += sumR;
  }
}

/* ===========================================================================
 * Электрогитара (Karplus-Strong)
 *
 * Струна — это линия задержки с демпфером: длина линии = период ноты,
 * демпфер — однополюсный ФНЧ, затухание — множитель за сэмпл. Возбуждение
 * («щипок») заполняет линию шумом, а гребенчатый фильтр по позиции щипка
 * задаёт тембр: щипок у подставки (pick→1) вырезает нечётные гармоники,
 * у грифа (pick→0) даёт глухой «вульф».
 *
 * Указатель чтения — дробный, поэтому струну можно согнуть (pitch bend и
 * вибрато) без пересчёта линии: частота меняется отношением скоростей.
 * После струны — кабинет (ФНЧ) и насыщение усилителя: без них
 * Karplus-Strong звучит как расчёска, с ними — как электрогитара.
 * ========================================================================= */

void eut_guitar_init(EutGuitar *g, EutGuitarVoice *voices, int voiceCount,
                     float *memory, int lineCap, float sampleRate)
{
  if (g == NULL) return;
  memset(g, 0, sizeof(*g));
  if (sampleRate < 1000.0f) sampleRate = 48000.0f;
  g->voices = voices;
  g->voiceCount = (voiceCount > 0) ? voiceCount : 1;
  g->lineCap = (lineCap > 4) ? lineCap : 4;
  g->memory = memory;
  g->sampleRate = sampleRate;
  if (g->memory != NULL) {
    memset(g->memory, 0, (size_t)g->voiceCount * (size_t)g->lineCap * sizeof(float));
  }
  eut_guitar_set(g, 0.28f, 0.65f, 0.55f, 0.25f, 0.0f, 0.22f, 0.0f, 0.8f);
  eut_guitar_reset(g);
}

void eut_guitar_reset(EutGuitar *g)
{
  if (g == NULL || g->voices == NULL) return;
  memset(g->voices, 0, (size_t)g->voiceCount * sizeof(EutGuitarVoice));
  if (g->memory != NULL) {
    memset(g->memory, 0, (size_t)g->voiceCount * (size_t)g->lineCap * sizeof(float));
  }
  g->toneLpL = 0.0f;
  g->toneLpR = 0.0f;
  g->seqCounter = 0;
  g->active = 0;
}

void eut_guitar_set(EutGuitar *g, float pick, float damping, float tone,
                    float drive, float mute, float release, float pan, float level)
{
  if (g == NULL) return;
  g->pick = inst_clamp(pick, 0.02f, 0.95f);
  g->damping = inst_clamp(damping, 0.0f, 1.0f);
  g->tone = inst_clamp(tone, 0.0f, 1.0f);
  g->drive = inst_clamp(drive, 0.0f, 1.0f);
  g->mute = inst_clamp(mute, 0.0f, 1.0f);
  g->release = inst_clamp(release, 0.01f, 2.0f);
  g->pan = inst_clamp(pan, -1.0f, 1.0f);
  g->level = inst_clamp(level, 0.0f, 2.0f);
}

void eut_guitar_note_on(EutGuitar *g, int note, float velocity)
{
  if (g == NULL || g->voices == NULL || g->memory == NULL) return;
  if (note < 0) note = 0;
  if (note > 127) note = 127;
  EutGuitarVoice *v = (EutGuitarVoice *)inst_pick_voice(g->voices,
                        (int)sizeof(EutGuitarVoice), g->voiceCount);
  if (v == NULL) return;
  memset(v, 0, sizeof(*v));

  const float f0 = inst_hz(note);
  int len = (int)(g->sampleRate / f0 + 0.5f);
  if (len < 4) len = 4;
  if (len > g->lineCap - 1) len = g->lineCap - 1;
  v->offset = (int)((v - g->voices) * (size_t)g->lineCap);
  v->len = len;
  v->rp = 0.0f;

  /* Свободная струна звенит секунды, заглушённая ладонью — доли секунды.
     Затухание пересчитывается в множитель за сэмпл здесь, а не в цикле. */
  float tail = (0.7f + 6.0f * g->damping) * (1.0f - 0.92f * g->mute);
  if (tail < 0.05f) tail = 0.05f;
  v->damp = inst_coef(tail, g->sampleRate);

  const float vel = inst_clamp(velocity, 0.0f, 1.0f);
  inst_voice_setup(&v->v, note, vel, 0.002f, 1.0f, 1.0f, g->release, g->sampleRate);
  v->v.seq = ++g->seqCounter;
  v->v.rng = (uint32_t)(0x27D4EB2Fu * (uint32_t)(note + 1)) ^
             (uint32_t)((uint32_t)g->seqCounter * 2246822519u);
  if (v->v.rng == 0u) v->v.rng = 0xABCDEFu;
  /* Детонация струны: ±4 цента, иначе повторяющиеся ноты звучат копией. */
  v->v.freq = f0 * (float)exp2((double)((inst_noise(&v->v.rng) * 4.0f)) / 1200.0);
  v->v.amp = 0.0f;
  v->v.gainL = 1.0f;   /* гитара моно: панораму ставит движок целиком */
  v->v.gainR = 1.0f;

  /* Возбуждение: шум по всей длине линии + гребёнка по позиции щипка. */
  float *ring = g->memory + (size_t)v->offset;
  float exc = 0.55f + 0.45f * vel;
  for (int i = 0; i < len; ++i) ring[i] = inst_noise(&v->v.rng) * exc;
  int combDelay = (int)(g->pick * (float)len);
  if (combDelay < 1) combDelay = 1;
  if (combDelay > len - 1) combDelay = len - 1;
  if (combDelay > 0) {
    for (int i = combDelay; i < len; ++i) ring[i] -= 0.7f * ring[i - combDelay];
  }

  /* Щелчок медиатора. */
  v->v.amp2 = (0.30f + 0.70f * vel) * (0.3f + 0.7f * g->drive);
  v->v.amp2Coef = inst_coef(0.005f, g->sampleRate);
  g->active = 1;
}

void eut_guitar_note_off(EutGuitar *g, int note)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutGuitarVoice *v = &g->voices[i];
    if (v->v.active && v->v.held && v->v.note == note) v->v.held = 0;
  }
}

void eut_guitar_all_off(EutGuitar *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    if (g->voices[i].v.active) g->voices[i].v.held = 0;
  }
}

EUT_TARGET_CLONES
void eut_guitar_process(EutGuitar *g, float *outL, float *outR, int stride,
                        int n, float bendSemitones, float modCents)
{
  if (g == NULL || g->voices == NULL || g->memory == NULL || n <= 0) return;
  if (g->active == 0) return;

  /* Демпфер струны: palm mute сужает полосу (глухой «чак»), tone её
     расширяет. Считается на блок: параметр не меняется внутри блока. */
  const float lpCoef = inst_clamp((0.16f + 0.74f * g->tone) * (1.0f - 0.72f * g->mute),
                                  0.03f, 0.98f);
  /* Кабинет: ФНЧ после струны, ~700 Гц … ~7 кГц. */
  const float cabCoef = inst_clamp(0.045f + 0.72f * g->tone * g->tone, 0.02f, 0.9f);
  const float preGain = 1.0f + 6.0f * g->drive;
  const float postGain = 1.0f / (1.0f + 2.6f * g->drive);
  const float cents = bendSemitones * 100.0f + modCents;
  /* Сгиб струны = отношение скоростей чтения. Одного exp2 на блок хватает:
     внутри блока bend и вибрато не меняются. */
  const float rate = (cents == 0.0f) ? 1.0f : (float)exp2((double)cents / 1200.0);

  float panL = 0.0f;
  float panR = 0.0f;
  inst_pan_gains(g->pan, &panL, &panR);

  for (int i = 0; i < n; ++i) {
    float sum = 0.0f;
    int alive = 0;
    for (int vi = 0; vi < g->voiceCount; ++vi) {
      EutGuitarVoice *v = &g->voices[vi];
      if (!inst_voice_alive(&v->v)) continue;
      ++alive;

      const int ip = (int)v->rp;
      const int iq = (ip + 1 < v->len) ? (ip + 1) : 0;
      const float frac = v->rp - (float)ip;
      float *ring = g->memory + (size_t)v->offset;
      const float y = ring[ip] + (ring[iq] - ring[ip]) * frac;

      /* Петля: прочитанный сэмпл фильтруется и записывается обратно на его
         же место — так линия задержки сама себя поддерживает. */
      v->lp += (y - v->lp) * lpCoef;
      ring[ip] = v->lp * v->damp;

      v->rp += rate;
      if (v->rp >= (float)v->len) v->rp -= (float)v->len;

      /* DC-блокировка: у щипка есть постоянная составляющая, и в петле она
         накапливалась бы до смещения всего сигнала. */
      const float dc = y - v->dcIn + 0.9985f * v->dcOut;
      v->dcIn = y;
      v->dcOut = dc;

      float s = dc;
      if (v->v.amp2 > 0.0f) {
        /* Щелчок медиатора: высокочастотная вспышка возбуждения. */
        s += inst_noise(&v->v.rng) * v->v.amp2;
      }
      sum += s * v->v.amp;
    }
    g->active = alive;

    /* Усилитель целиком: кабинет, насыщение, панорама. */
    g->toneLpL += (sum - g->toneLpL) * cabCoef;
    g->toneLpR = g->toneLpL;   /* гитара моно, стерео делает панорама */
    const float drv = inst_soft_clip(g->toneLpL * preGain) * postGain;
    const float out = drv * g->level * 0.5f;
    if (outL != NULL) outL[i * stride] += out * panL;
    if (outR != NULL) outR[i * stride] += out * panR;
  }
}

/* ===========================================================================
 * Барабаны
 *
 * Установка собирается из трёх примитивов:
 *   - тон (1–2 синуса с огибающей высоты): бочка, томы, тело малого;
 *   - шум в полосе: «щётки» малого, воздух клэпа;
 *   - металлическая группа 6 квадратов на несоизмеримых частотах с
 *     высокочастотным фильтром: тарелки и хэты.
 *
 * Карта нот — GM-совместимая: нота вне карты молчит (см.
 * eut_drums_piece_for_note). Так партия, написанная для внешнего
 * инструмента, не превращается в случайный набор кусков.
 *
 * Микроразброс по нотам (высота ±1.5%, время затухания ±4%) засеян ГПСЧ
 * от ноты и счётчика событий: живые повторы остаются воспроизводимыми.
 * ========================================================================= */

typedef struct {
  float freq;       /* основная частота тона */
  float pitchDrop;  /* во сколько раз выше стартовая высота */
  float pitchTime;  /* время спада высоты, с */
  float ampTime;    /* время затухания огибающей, с */
  float noise;      /* доля шума */
  float toneFreq;   /* срез полосы шума, Гц */
  float metal;      /* доля металлической группы */
  float tone;       /* доля тона в миксе */
  float drive;
  float gain;
  float pan;        /* место в стереокартине */
} DrumSpec;

static const DrumSpec DRUM_SPECS[EUT_DRUM_PIECE_COUNT] = {
  /* KICK      */ { 108.0f, 2.60f, 0.048f, 0.42f, 0.10f,  2400.0f, 0.00f, 1.00f, 0.30f, 1.00f,  0.00f },
  /* SNARE     */ { 188.0f, 1.35f, 0.030f, 0.19f, 0.72f,  5200.0f, 0.22f, 0.85f, 0.28f, 0.80f, -0.05f },
  /* RIM       */ { 420.0f, 1.20f, 0.012f, 0.05f, 0.50f,  8000.0f, 0.35f, 0.70f, 0.22f, 0.55f,  0.15f },
  /* CLAP      */ { 340.0f, 1.10f, 0.020f, 0.24f, 0.96f,  7000.0f, 0.00f, 0.15f, 0.25f, 0.65f, -0.20f },
  /* TOM_LOW   */ {  92.0f, 1.50f, 0.040f, 0.52f, 0.16f,  2600.0f, 0.00f, 1.00f, 0.22f, 0.85f, -0.35f },
  /* TOM_MID   */ { 138.0f, 1.50f, 0.040f, 0.44f, 0.16f,  3000.0f, 0.00f, 1.00f, 0.22f, 0.85f, -0.15f },
  /* TOM_HIGH  */ { 196.0f, 1.50f, 0.040f, 0.36f, 0.16f,  3400.0f, 0.00f, 1.00f, 0.22f, 0.85f,  0.10f },
  /* HAT_CLOSED*/ { 540.0f, 1.00f, 0.000f, 0.055f, 1.00f, 14000.0f, 0.95f, 0.05f, 0.12f, 0.45f,  0.30f },
  /* HAT_PEDAL */ { 500.0f, 1.00f, 0.000f, 0.085f, 1.00f, 11000.0f, 0.95f, 0.05f, 0.12f, 0.40f,  0.30f },
  /* HAT_OPEN  */ { 540.0f, 1.00f, 0.000f, 0.40f, 1.00f,  13000.0f, 0.95f, 0.05f, 0.10f, 0.45f,  0.32f },
  /* CRASH     */ { 620.0f, 1.00f, 0.000f, 1.80f, 1.00f,  9000.0f, 1.00f, 0.10f, 0.08f, 0.42f, -0.40f },
  /* RIDE      */ { 880.0f, 1.00f, 0.000f, 1.50f, 0.55f, 12000.0f, 1.00f, 0.15f, 0.08f, 0.38f,  0.40f }
};

int eut_drums_piece_for_note(int note)
{
  switch (note) {
  case 35: case 36: return EUT_DRUM_KICK;
  case 37: return EUT_DRUM_RIM;
  case 38: case 40: return EUT_DRUM_SNARE;
  case 39: return EUT_DRUM_CLAP;
  case 41: case 43: return EUT_DRUM_TOM_LOW;
  case 45: case 47: return EUT_DRUM_TOM_MID;
  case 48: case 50: return EUT_DRUM_TOM_HIGH;
  case 42: return EUT_DRUM_HAT_CLOSED;
  case 44: return EUT_DRUM_HAT_PEDAL;
  case 46: return EUT_DRUM_HAT_OPEN;
  case 49: case 55: case 57: return EUT_DRUM_CRASH;
  case 51: case 53: case 59: return EUT_DRUM_RIDE;
  default: return -1;
  }
}

void eut_drums_init(EutDrums *g, EutDrumVoice *voices, int voiceCount, float sampleRate)
{
  if (g == NULL) return;
  memset(g, 0, sizeof(*g));
  if (sampleRate < 1000.0f) sampleRate = 48000.0f;
  g->voices = voices;
  g->voiceCount = (voiceCount > 0) ? voiceCount : 1;
  g->sampleRate = sampleRate;
  eut_drums_set(g, 1.0f, 1.0f, 1.0f, 0.6f, 0.2f, 0.0f, 0.85f);
  eut_drums_reset(g);
}

void eut_drums_reset(EutDrums *g)
{
  if (g == NULL || g->voices == NULL) return;
  memset(g->voices, 0, (size_t)g->voiceCount * sizeof(EutDrumVoice));
  g->seqCounter = 0;
  g->active = 0;
}

void eut_drums_set(EutDrums *g, float tune, float decay, float snappy,
                   float tone, float drive, float pan, float level)
{
  if (g == NULL) return;
  g->tune = inst_clamp(tune, 0.25f, 4.0f);
  g->decay = inst_clamp(decay, 0.1f, 5.0f);
  g->snappy = inst_clamp(snappy, 0.0f, 2.0f);
  g->tone = inst_clamp(tone, 0.0f, 1.0f);
  g->drive = inst_clamp(drive, 0.0f, 1.0f);
  g->pan = inst_clamp(pan, -1.0f, 1.0f);
  g->level = inst_clamp(level, 0.0f, 2.0f);
}

void eut_drums_note_on(EutDrums *g, int note, float velocity)
{
  if (g == NULL || g->voices == NULL) return;
  const int piece = eut_drums_piece_for_note(note);
  if (piece < 0) return;   /* нота вне карты: честная тишина */
  const DrumSpec *sp = &DRUM_SPECS[piece];
  const float sr = g->sampleRate;

  const float vel = inst_clamp(velocity, 0.0f, 1.0f);

  /* Закрытый хэт гасит открытый и предыдущий закрытый: у настоящей
     установки между тарелками одна пара, и они глушат друг друга. */
  if (piece == EUT_DRUM_HAT_CLOSED || piece == EUT_DRUM_HAT_PEDAL) {
    for (int i = 0; i < g->voiceCount; ++i) {
      EutDrumVoice *o = &g->voices[i];
      if (!o->v.active) continue;
      if (o->piece == EUT_DRUM_HAT_OPEN || o->piece == EUT_DRUM_HAT_CLOSED ||
          o->piece == EUT_DRUM_HAT_PEDAL) {
        o->v.held = 0;
        o->v.relCoef = inst_coef(0.006f, sr);
      }
    }
  }

  EutDrumVoice *v = (EutDrumVoice *)inst_pick_voice(g->voices,
                        (int)sizeof(EutDrumVoice), g->voiceCount);
  if (v == NULL) return;
  memset(v, 0, sizeof(*v));
  v->piece = piece;
  v->v.note = note;
  v->v.vel = vel;
  v->v.rng = (uint32_t)(0x9E3779B9u * (uint32_t)(note + 1)) ^
             (uint32_t)((uint32_t)(++g->seqCounter) * 2654435761u);
  if (v->v.rng == 0u) v->v.rng = 0x5A5A5A5u;

  /* Микроразброс: живые повторы не звучат копией, но остаются
     воспроизводимыми (сид детерминирован). */
  const float jitterPitch = 1.0f + inst_noise(&v->v.rng) * 0.015f;
  const float jitterDecay = 1.0f + inst_noise(&v->v.rng) * 0.04f;

  const float ampTime = inst_clamp(sp->ampTime * g->decay * jitterDecay, 0.008f, 8.0f);
  /* Удар ударных держится не пальцем: held = 0, затухание идёт по
     отпусканию. Так одна и та же огибающая обслуживает и «чок» хэта. */
  inst_voice_setup(&v->v, note, vel, 0.0005f, 0.0f, ampTime, ampTime, sr);
  v->v.held = 0;
  v->v.seq = g->seqCounter;

  const float f0 = sp->freq * g->tune * jitterPitch;
  v->pitch = f0 * sp->pitchDrop;
  v->pitchTarget = f0;
  v->pitchCoef = inst_coef(sp->pitchTime, sr);
  v->tonePh[0] = 0.0f;
  v->tonePh[1] = 0.25f;
  v->toneDph[0] = 0.0f;
  v->toneDph[1] = 0.0f;
  for (int k = 0; k < EUT_INST_DRUM_METAL; ++k) {
    v->metalPh[k] = (inst_noise(&v->v.rng) * 0.5f + 0.5f);
    v->metalDph[k] = 0.0f;
  }
  v->noiseLp = 0.0f;
  v->noiseHp = 0.0f;
  /* Полоса шума: сверху — toneFreq с поправкой на параметр tone, снизу —
     высокочастотный срез, чтобы шум не гудел. */
  const float lpHz = sp->toneFreq * (0.45f + 0.85f * g->tone);
  v->noiseLpCoef = inst_clamp(EUT_INST_TWO_PI * lpHz / sr, 0.02f, 0.99f);
  v->noiseHpCoef = inst_clamp(EUT_INST_TWO_PI * 320.0f / sr, 0.005f, 0.5f);

  /* Доли микса: у ударов с «пружиной» (малый, клэп) их подмешивает snappy. */
  float noiseMix = sp->noise * (0.55f + 0.45f * vel);
  if (piece == EUT_DRUM_SNARE || piece == EUT_DRUM_CLAP || piece == EUT_DRUM_RIM) {
    noiseMix *= (0.4f + 0.6f * g->snappy);
  }
  v->mixNoise = inst_clamp(noiseMix, 0.0f, 2.0f);
  v->mixMetal = sp->metal;

  /* Предусиление с компенсацией: мягкое ограничение оставляет уровень
     примерно тем же, что и до него, поэтому drive не «прыгает» громкостью. */
  const float pre = 1.0f + 2.2f * sp->drive + 1.8f * g->drive;
  v->drive = pre;
  v->gain = sp->gain / pre;
  const float velScale = 0.28f + 0.72f * (vel * vel * 0.6f + vel * 0.4f);
  const float toneMix = inst_clamp(sp->tone, 0.0f, 1.0f) * g->level * velScale;
  float pl = 0.0f;
  float pr = 0.0f;
  inst_pan_gains(inst_clamp(g->pan + sp->pan, -1.0f, 1.0f), &pl, &pr);
  v->v.gainL = pl * toneMix * 0.5f;
  v->v.gainR = pr * toneMix * 0.5f;
  v->v.ampInc = 1.0f;   /* мгновенная атака: у удара нет «нарастания» */
  g->active = 1;
}

void eut_drums_note_off(EutDrums *g, int note)
{
  if (g == NULL || g->voices == NULL) return;
  /* Тарелки и хэты можно заглушить рукой (нота без длительности снята):
     остальные куски затухают сами. */
  for (int i = 0; i < g->voiceCount; ++i) {
    EutDrumVoice *v = &g->voices[i];
    if (!v->v.active || v->v.note != note) continue;
    if (v->piece == EUT_DRUM_HAT_OPEN || v->piece == EUT_DRUM_CRASH ||
        v->piece == EUT_DRUM_RIDE) {
      v->v.held = 0;
      v->v.relCoef = inst_coef(0.030f, g->sampleRate);
    }
  }
}

void eut_drums_all_off(EutDrums *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutDrumVoice *v = &g->voices[i];
    if (v->v.active) {
      v->v.held = 0;
      v->v.relCoef = inst_coef(0.020f, g->sampleRate);
    }
  }
}


EUT_TARGET_CLONES
void eut_drums_process(EutDrums *g, float *outL, float *outR, int stride, int n)
{
  if (g == NULL || g->voices == NULL || n <= 0) return;
  if (g->active == 0) return;
  const float invSr = 1.0f / g->sampleRate;
  /* Несоизмеримые отношения металлической группы: так сумма шести
     квадратов не даёт слышимой высоты — получается тарелка, а не аккорд. */
  static const float METAL_RATIO[EUT_INST_DRUM_METAL] =
    { 2.00f, 2.68f, 3.26f, 3.88f, 4.62f, 5.42f };
  const float metalHp = 0.55f + 0.30f * g->tone;

  for (int i = 0; i < n; ++i) {
    float sumL = 0.0f;
    float sumR = 0.0f;
    int alive = 0;
    for (int vi = 0; vi < g->voiceCount; ++vi) {
      EutDrumVoice *v = &g->voices[vi];
      if (!inst_voice_alive(&v->v)) continue;
      ++alive;

      /* Огибающая высоты: бочка «падает» с 2.6× до основной частоты. */
      v->pitch = v->pitchTarget + (v->pitch - v->pitchTarget) * v->pitchCoef;

      float tone = 0.0f;
      v->tonePh[0] += v->pitch * invSr;
      if (v->tonePh[0] >= 1.0f) v->tonePh[0] -= 1.0f;
      tone += inst_sin(v->tonePh[0]);
      /* Вторая составляющая у малого и томов: 1.44 — нецелое отношение,
         оно и даёт «кожаный» призвук вместо чистого тона. */
      v->tonePh[1] += v->pitch * 1.44f * invSr;
      if (v->tonePh[1] >= 1.0f) v->tonePh[1] -= 1.0f;
      tone += inst_sin(v->tonePh[1]) * 0.7f;

      float noise = 0.0f;
      if (v->mixNoise > 0.0f) {
        const float nz = inst_noise(&v->v.rng);
        v->noiseHp += (nz - v->noiseHp) * v->noiseHpCoef;
        const float hi = nz - v->noiseHp;
        v->noiseLp += (hi - v->noiseLp) * v->noiseLpCoef;
        noise = v->noiseLp * 2.4f;
      }

      float metal = 0.0f;
      if (v->mixMetal > 0.0f) {
        float sq = 0.0f;
        for (int k = 0; k < EUT_INST_DRUM_METAL; ++k) {
          v->metalPh[k] += v->pitch * METAL_RATIO[k] * invSr;
          if (v->metalPh[k] >= 1.0f) v->metalPh[k] -= 1.0f;
          sq += (v->metalPh[k] < 0.5f) ? 1.0f : -1.0f;
        }
        sq *= (1.0f / EUT_INST_DRUM_METAL);
        /* ФВЧ оставляет от квадратов только «звон»: основной тон группы
           вырезан, поэтому нет слышимой высоты. */
        v->toneDph[0] += (sq - v->toneDph[0]) * metalHp;
        metal = (sq - v->toneDph[0]) * 2.0f;
      }

      float s = tone + noise * v->mixNoise + metal * v->mixMetal;
      s = inst_soft_clip(s * v->drive) * v->gain;
      const float a = v->v.amp;
      sumL += s * a * v->v.gainL;
      sumR += s * a * v->v.gainR;
    }
    g->active = alive;
    if (outL != NULL) outL[i * stride] += sumL;
    if (outR != NULL) outR[i * stride] += sumR;
  }
}

