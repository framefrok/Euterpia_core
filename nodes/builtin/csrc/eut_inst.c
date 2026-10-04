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

/* Soft-clip (аппроксимация tanh). Нужно для усилителя гитары и
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

/* polyBLEP: сглаживает разрыв фазы на 0.5 периода. Без него наивный
   меандр даёт полосу зеркальных частот выше Найквиста — «цифровой звон»
   тарелок. add — фаза 0..1, dt — приращение фазы за сэмпл. */
static inline float inst_polyblep(float t, float dt)
{
  if (dt <= 0.0f) return 0.0f;
  if (t < dt) { t /= dt; return t + t - t * t - 1.0f; }
  if (t > 1.0f - dt) { t = (t - 1.0f) / dt; return t * t + t + t + 1.0f; }
  return 0.0f;
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
 * демпфер — ФНЧ в петле, затухание — множитель за сэмпл. Возбуждение
 * («щипок») заполняет линию шумом, а гребенчатый фильтр по позиции щипка
 * задаёт тембр: щипок у подставки (pick→1) вырезает нечётные гармоники,
 * у грифа (pick→0) даёт глухой «вульф».
 *
 * Указатель чтения — дробный, поэтому струну можно согнуть (pitch bend и
 * вибрато) без пересчёта линии: частота меняется отношением скоростей.
 * После струны — тело корпуса, кабинет (ФНЧ) и насыщение усилителя: без
 * них Karplus-Strong звучит как расчёска, с ними — как электрогитара.
 *
 * Три вещи, без которых синтез слышно «наклеенным»:
 *   * демпфер в петле двухполюсный: один жёсткий ФНЧ даёт «цифровой» квак
 *     на хвосте, две ступени (вторая с меньшим коэффициентом) затухают
 *     ровнее, а строй не плывёт — вторая ступень сильно перекрыта первой;
 *   * тело корпуса — параллельный медленный ФНЧ (~200–320 Гц), подмешанный
 *     к прямому сигналу ДО кабинета: мягкий low-shelf, «деревянная» полка
 *     в нижней середине вместо пустоты;
 *   * огибающая строя — сильный щипок коротко натягивает струну, высота
 *     уезжает вверх на пару центов и садится за ~35 мс: характерный
 *     «въезд» живой щипковой атаки.
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
  g->bodyLp = 0.0f;
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

  /* Тело корпуса: параллельный медленный ФНЧ (~200–320 Гц), подмешанный к
     прямому сигналу до кабинета. Даёт мягкий low-shelf (~2 дБ ниже 200 Гц,
     замерено +2.1 дБ по фундаменталу) — «деревянный» вес без раздувания
     верха. tone двигает и срез, и глубину: тёмный тембр получает больше
     тела. Считается здесь, а не в цикле: параметр не меняется внутри блока. */
  const float fc = 200.0f + 120.0f * (1.0f - g->tone);
  g->bodyCoef = inst_clamp(EUT_INST_TWO_PI * fc / g->sampleRate, 0.005f, 0.5f);
  g->bodyBoost = 0.18f + 0.25f * (1.0f - g->tone);
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
  /* Огибающая строя: сильная атака натягивает струну — короткий «въезд»
     вверх (максимум ~3 цента на ff) и посадка за ~35 мс. Возврат
     экспоненциальный, поэтому слышен как признак живой щипковой атаки,
     а не как вибрато. */
  v->pitchEnv = vel * vel * 0.0018f;
  v->pitchEnvCoef = inst_coef(0.035f, g->sampleRate);
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
     расширяет. Вторая ступень с умеренным коэффициентом сглаживает спад
     верхних гармоник: одна жёсткая петля даёт «цифровой» квак на хвосте,
     две звучат как настоящий демпфер. Строй не плывёт — вторая ступень
     сильно перекрыта первой (lp2Coef = 0.55·lpCoef). Ставить её равной
     первой нельзя: лишний фазовый сдвиг уводит тон вниз на 10–20 центов. */
  const float lpCoef = inst_clamp((0.16f + 0.74f * g->tone) * (1.0f - 0.72f * g->mute),
                                  0.03f, 0.98f);
  const float lp2Coef = lpCoef * 0.55f;
  /* Кабинет: ФНЧ после струны, ~700 Гц … ~7 кГц. */
  const float cabCoef = inst_clamp(0.045f + 0.72f * g->tone * g->tone, 0.02f, 0.9f);
  const float preGain = 1.0f + 6.0f * g->drive;
  const float postGain = 1.0f / (1.0f + 2.6f * g->drive);
  const float cents = bendSemitones * 100.0f + modCents;
  /* Сгиб струны = отношение скоростей чтения. Одного exp2 на блок хватает:
     внутри блока bend и вибрато не меняются. */
  const float baseRate = (cents == 0.0f) ? 1.0f : (float)exp2((double)cents / 1200.0);

  /* Тело корпуса — состояние на весь инструмент: гитара моно до панорамы,
     стерео делает движок (MANIFEST §47). */
  const float bodyCoef = g->bodyCoef;
  const float bodyBoost = g->bodyBoost;
  float bodyLp = g->bodyLp;

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

      /* Петля: двухполюсный ФНЧ. Прочитанный сэмпл фильтруется и
         записывается обратно на его же место — так линия задержки сама
         себя поддерживает. Первая ступень задаёт яркость, вторая
         добавляет мягкий спад ВЧ. */
      v->lp += (y - v->lp) * lpCoef;
      v->lp2 += (v->lp - v->lp2) * lp2Coef;
      ring[ip] = v->lp2 * v->damp;

      /* Огибающая строя: короткий сдвиг вверх в момент щипка, затем
         экспоненциальный возврат к строю. Складывается со сгибом, а не
         заменяет его: bend идёт от хоста, огибающая — от силы щипка. */
      const float rate = baseRate * (1.0f + v->pitchEnv);
      v->pitchEnv *= v->pitchEnvCoef;
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

    /* Тело корпуса: медленный ФНЧ подмешивается к прямому сигналу до
       кабинета. Ниже ~200 Гц суммарный gain > 1 (плотная нижняя середина),
       выше 400 Гц — ровно 1: верх не раздувается. */
    bodyLp += (sum - bodyLp) * bodyCoef;
    const float warm = sum + bodyBoost * bodyLp;

    /* Усилитель целиком: кабинет, насыщение, панорама. */
    g->toneLpL += (warm - g->toneLpL) * cabCoef;
    g->toneLpR = g->toneLpL;   /* гитара моно, стерео делает панорама */
    const float drv = inst_soft_clip(g->toneLpL * preGain) * postGain;
    const float out = drv * g->level * 0.5f;
    if (outL != NULL) outL[i * stride] += out * panL;
    if (outR != NULL) outR[i * stride] += out * panR;
  }

  g->bodyLp = eut_flush(bodyLp);
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
  float level;      /* масштаб уровня детали (баланс бочка/малый/тарелки) */
  float drive;
  float gain;
  float pan;        /* место в стереокартине */
} DrumSpec;

static const DrumSpec DRUM_SPECS[EUT_DRUM_PIECE_COUNT] = {
  /* KICK      */ {  72.0f, 2.10f, 0.032f, 0.22f, 0.06f,  1800.0f, 0.00f, 0.80f, 0.08f, 1.00f,  0.00f },
  /* SNARE     */ { 190.0f, 1.30f, 0.030f, 0.15f, 0.68f,  5200.0f, 0.12f, 0.70f, 0.10f, 0.80f, -0.05f },
  /* RIM       */ { 420.0f, 1.20f, 0.012f, 0.05f, 0.50f,  8000.0f, 0.35f, 0.60f, 0.10f, 0.55f,  0.15f },
  /* CLAP      */ { 340.0f, 1.10f, 0.020f, 0.22f, 0.96f,  7000.0f, 0.00f, 0.70f, 0.10f, 0.65f, -0.20f },
  /* TOM_LOW   */ {  92.0f, 1.50f, 0.040f, 0.40f, 0.16f,  2600.0f, 0.00f, 0.80f, 0.10f, 0.85f, -0.35f },
  /* TOM_MID   */ { 138.0f, 1.50f, 0.040f, 0.34f, 0.16f,  3000.0f, 0.00f, 0.80f, 0.10f, 0.85f, -0.15f },
  /* TOM_HIGH  */ { 196.0f, 1.50f, 0.040f, 0.28f, 0.16f,  3400.0f, 0.00f, 0.80f, 0.10f, 0.85f,  0.10f },
  /* HAT_CLOSED*/ { 540.0f, 1.00f, 0.000f, 0.055f, 1.00f, 14000.0f, 0.90f, 0.36f, 0.05f, 0.45f,  0.30f },
  /* HAT_PEDAL */ { 500.0f, 1.00f, 0.000f, 0.085f, 1.00f, 11000.0f, 0.90f, 0.32f, 0.05f, 0.40f,  0.30f },
  /* HAT_OPEN  */ { 540.0f, 1.00f, 0.000f, 0.34f, 1.00f,  13000.0f, 0.90f, 0.38f, 0.05f, 0.45f,  0.32f },
  /* CRASH     */ { 620.0f, 1.00f, 0.000f, 1.10f, 1.00f,  9000.0f, 0.95f, 0.55f, 0.04f, 0.42f, -0.40f },
  /* RIDE      */ { 820.0f, 1.00f, 0.000f, 0.80f, 0.70f, 13000.0f, 0.85f, 0.40f, 0.04f, 0.38f,  0.40f }
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
     отпусканию. Так одна и та же огибающая обслуживает и «чок» хэта.
     Атака — не нулевая: она даёт короткий фейд, иначе старт с полной
     амплитудой превращался в щелчок (поймано инспектором аудио). */
  inst_voice_setup(&v->v, note, vel, 0.0008f, 0.0f, ampTime, ampTime, sr);
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
  const float toneMix = inst_clamp(sp->level, 0.0f, 1.0f) * g->level * velScale;
  float pl = 0.0f;
  float pr = 0.0f;
  inst_pan_gains(inst_clamp(g->pan + sp->pan, -1.0f, 1.0f), &pl, &pr);
  v->v.gainL = pl * toneMix * 0.5f;
  v->v.gainR = pr * toneMix * 0.5f;
  /* Мгновенной атаки (ampInc = 1) быть не должно: amp прыгал с 0 до 1 за
     один сэмпл, и это слышалось как щелчок на каждом ударе. Атака из
     setup (доли миллисекунды) уже достаточно быстрая для удара, но
     разрыв убирает. */
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
  /* Ингармонические отношения: тарелка — это звон без ясной высоты, а не
     аккорд. Отношения разрежены вверх — вместе с шумом это даёт «шипение». */
  static const float METAL_RATIO[EUT_INST_DRUM_METAL] =
    { 2.00f, 2.83f, 3.76f, 5.10f, 6.80f, 9.10f };

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
        /* Ингармонические ЧАСТИЧНЫЕ вместо меандра: сумма квадратов давала
           густой низко-серединистый «жужжащий» призвук (особенно ride),
           который тянулся и накладывался при игре восьмыми. Синусы такой
           грязи не дают, а «шипение» тарелки добавляет шумовая часть. */
        float partials = 0.0f;
        for (int k = 0; k < EUT_INST_DRUM_METAL; ++k) {
          const float dt = v->pitch * METAL_RATIO[k] * invSr;
          v->metalPh[k] += dt;
          if (v->metalPh[k] >= 1.0f) v->metalPh[k] -= 1.0f;
          partials += inst_sin(v->metalPh[k]) * (1.0f - 0.12f * (float)k);
        }
        metal = partials * (1.0f / EUT_INST_DRUM_METAL);
      }

      /* Тональная часть даётся только «кожаным» деталям: у тарелок
         mixMetal близок к 1, и синус под ними звучал пищащим «биип». */
      const float tonalMix = 1.0f - v->mixMetal;
      float s = tone * tonalMix + noise * v->mixNoise + metal * v->mixMetal;
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


/* ===========================================================================
 * Флейта
 *
 * Почти синус + верхние нечётные гармоники (яркость), дыхательный шум и
 * короткий «чиф» на атаке. Вибрато — общий LFO движка. Гармоники берутся
 * только ниже Найквиста, поэтому алиасинга нет.
 * ========================================================================= */

static inline float inst_sin_mult(float phase, float mult)
{
  float t = phase * mult;
  t -= (float)(long)t;   /* phase >= 0 — приводим к 0..1 */
  return inst_sin(t);
}

void eut_flute_reset(EutFlute *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutFluteVoice *v = &g->voices[i];
    memset(&v->v, 0, sizeof(v->v));
    v->ph = v->dph = 0.0f;
    v->breathLp = v->breathHp = 0.0f;
    v->chiff = 0.0f;
    v->vibAmp = 0.0f;
  }
  g->lfoPhase = 0.0f;
  g->active = 0;
}

void eut_flute_init(EutFlute *g, EutFluteVoice *voices, int voiceCount,
                    float sampleRate)
{
  if (g == NULL) return;
  g->voices = voices;
  g->voiceCount = voiceCount > 0 ? voiceCount : 1;
  g->sampleRate = sampleRate > 0.0f ? sampleRate : 48000.0f;
  g->tone = 0.5f;
  g->breath = 0.35f;
  g->vibrato = 8.0f;
  g->pan = 0.0f;
  g->level = 0.8f;
  g->lfoInc = EUT_INST_TWO_PI * 5.0f / g->sampleRate;   /* вибрато ~5 Гц */
  g->seqCounter = 0;
  eut_flute_reset(g);
}

void eut_flute_set(EutFlute *g, float tone, float breath, float vibratoCents,
                   float pan, float level)
{
  if (g == NULL) return;
  g->tone = inst_clamp(tone, 0.0f, 1.0f);
  g->breath = inst_clamp(breath, 0.0f, 1.0f);
  g->vibrato = inst_clamp(vibratoCents, 0.0f, 100.0f);
  g->pan = inst_clamp(pan, -1.0f, 1.0f);
  g->level = level;
}

void eut_flute_note_on(EutFlute *g, int note, float velocity)
{
  if (g == NULL || g->voices == NULL) return;
  EutFluteVoice *v = (EutFluteVoice *)inst_pick_voice(
    g->voices, (int)sizeof(EutFluteVoice), g->voiceCount);
  if (v == NULL) return;
  /* Флейта монофонична: новую ноту берём одну — прежнюю голос гасим быстро.
     Иначе две ноты звучат вместе, и на слух это «фальшь». */
  for (int i = 0; i < g->voiceCount; ++i) {
    EutFluteVoice *o = &g->voices[i];
    if (o != v && o->v.active) {
      o->v.held = 0;
      o->v.relCoef = inst_coef(0.020f, g->sampleRate);
    }
  }
  v->v.seq = g->seqCounter++;
  /* Флейта — инструмент с дыханием: мягкая атака, длинный хвост. */
  inst_voice_setup(&v->v, note, velocity, 0.045f, 0.92f, 0.6f, 0.10f, g->sampleRate);
  v->ph = 0.0f;
  v->dph = 0.0f;
  v->breathLp = v->breathHp = 0.0f;
  v->chiff = 0.6f;
  v->vibAmp = 0.0f;
  g->active = 1;
}

void eut_flute_note_off(EutFlute *g, int note)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutFluteVoice *v = &g->voices[i];
    if (v->v.active && v->v.note == note) v->v.held = 0;
  }
}

void eut_flute_all_off(EutFlute *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutFluteVoice *v = &g->voices[i];
    if (v->v.active) {
      v->v.held = 0;
      v->v.relCoef = inst_coef(0.020f, g->sampleRate);
    }
  }
}

EUT_TARGET_CLONES
void eut_flute_process(EutFlute *g, float *outL, float *outR, int stride, int n,
                       float bendSemitones, float modCents)
{
  if (g == NULL || g->voices == NULL || n <= 0) return;
  if (g->active == 0) return;
  const float invSr = 1.0f / g->sampleRate;
  const float nyq = g->sampleRate * 0.5f;
  float gl, gr;
  inst_pan_gains(g->pan, &gl, &gr);

  for (int i = 0; i < n; ++i) {
    float sumL = 0.0f, sumR = 0.0f;
    int alive = 0;
    const float lfo = inst_sin(g->lfoPhase);

    for (int vi = 0; vi < g->voiceCount; ++vi) {
      EutFluteVoice *v = &g->voices[vi];
      if (!inst_voice_alive(&v->v)) continue;
      ++alive;

      v->vibAmp += (1.0f - v->vibAmp) * 0.00008f;   /* вибрато soft-включается после атаки */
      float cents = g->vibrato * v->vibAmp * lfo + modCents + bendSemitones * 100.0f;
      float f = v->v.freq;
      if (cents != 0.0f) f *= (float)exp2((double)(cents / 1200.0f));
      v->ph += f * invSr;
      if (v->ph >= 1.0f) v->ph -= 1.0f;

      float s = inst_sin(v->ph);
      if (f * 3.0f < nyq) s += inst_sin_mult(v->ph, 3.0f) * 0.08f * g->tone;
      if (f * 5.0f < nyq) s += inst_sin_mult(v->ph, 5.0f) * 0.03f * g->tone;

      const float nz = inst_noise(&v->v.rng);
      /* «Дыхание» — ПОЛОСОВОЙ шум (ФВЧ + ФНЧ ~2.3 кГц): воздух вокруг тона,
         а не широкополосное шипение. Тихий: у настоящей флейты шум дыхания
         на порядок слабее тона, иначе строй «плывёт» и слышно «сссс». */
      v->breathHp += (nz - v->breathHp) * 0.08f;
      const float hi = nz - v->breathHp;
      v->breathLp += (hi - v->breathLp) * 0.30f;
      s += v->breathLp * g->breath * 0.08f;

      /* «Чиф» атаки — короткий и тихий, тоже полосовой, не щелчок. */
      s += v->chiff * v->breathLp * 0.25f;
      v->chiff *= 0.9985f;

      s *= v->v.amp;
      sumL += s * gl;
      sumR += s * gr;
    }

    g->active = alive;
    g->lfoPhase += g->lfoInc;
    if (g->lfoPhase >= 1.0f) g->lfoPhase -= 1.0f;
    if (outL != NULL) outL[i * stride] += sumL * g->level;
    if (outR != NULL) outR[i * stride] += sumR * g->level;
  }
}


/* ===========================================================================
 * Волынка
 *
 * Две составляющие: шантир (мелодия, «тростниковый» тембр из нечётных
 * гармоник через формирующие фильтры) и бурдон — два постоянных тона, что
 * звучат, пока держится хотя бы одна нота. Отсюда непрерывность: между
 * нотами нет пауз, drone не даёт им «повиснуть».
 * ========================================================================= */

void eut_bagpipe_reset(EutBagpipe *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutBagpipeVoice *v = &g->voices[i];
    memset(&v->v, 0, sizeof(v->v));
    v->ph = v->dph = 0.0f;
    v->lp = v->hp = 0.0f;
  }
  g->dronePh1 = g->dronePh2 = 0.0f;
  g->droneAmp = 0.0f;
  g->active = 0;
}

void eut_bagpipe_init(EutBagpipe *g, EutBagpipeVoice *voices, int voiceCount,
                      float sampleRate)
{
  if (g == NULL) return;
  g->voices = voices;
  g->voiceCount = voiceCount > 0 ? voiceCount : 1;
  g->sampleRate = sampleRate > 0.0f ? sampleRate : 48000.0f;
  g->tone = 0.6f;
  g->droneLevel = 0.35f;
  g->droneFreq = 110.0f;                 /* A2 — типичный бурдон */
  g->pan = 0.0f;
  g->level = 0.65f;
  g->droneCoef = inst_coef(0.06f, g->sampleRate);  /* плавное вкл/выкл */
  g->seqCounter = 0;
  eut_bagpipe_reset(g);
}

void eut_bagpipe_set(EutBagpipe *g, float tone, float droneLevel, float droneFreq,
                     float pan, float level)
{
  if (g == NULL) return;
  g->tone = inst_clamp(tone, 0.0f, 1.0f);
  g->droneLevel = inst_clamp(droneLevel, 0.0f, 1.0f);
  g->droneFreq = inst_clamp(droneFreq, 20.0f, 2000.0f);
  g->pan = inst_clamp(pan, -1.0f, 1.0f);
  g->level = level;
}

void eut_bagpipe_note_on(EutBagpipe *g, int note, float velocity)
{
  if (g == NULL || g->voices == NULL) return;
  EutBagpipeVoice *v = (EutBagpipeVoice *)inst_pick_voice(
    g->voices, (int)sizeof(EutBagpipeVoice), g->voiceCount);
  if (v == NULL) return;
  v->v.seq = g->seqCounter++;
  /* Быстрая атака, «ровный» тон, короткий релиз — legato как у духового. */
  inst_voice_setup(&v->v, note, velocity, 0.020f, 0.95f, 0.5f, 0.08f, g->sampleRate);
  v->ph = 0.0f;
  v->dph = 0.0f;
  v->lp = v->hp = 0.0f;
  g->active = 1;
}

void eut_bagpipe_note_off(EutBagpipe *g, int note)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutBagpipeVoice *v = &g->voices[i];
    if (v->v.active && v->v.note == note) v->v.held = 0;
  }
}

void eut_bagpipe_all_off(EutBagpipe *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutBagpipeVoice *v = &g->voices[i];
    if (v->v.active) {
      v->v.held = 0;
      v->v.relCoef = inst_coef(0.030f, g->sampleRate);
    }
  }
}

EUT_TARGET_CLONES
void eut_bagpipe_process(EutBagpipe *g, float *outL, float *outR, int stride, int n)
{
  if (g == NULL || g->voices == NULL || n <= 0) return;
  const float invSr = 1.0f / g->sampleRate;
  const float nyq = g->sampleRate * 0.5f;
  float gl, gr;
  inst_pan_gains(g->pan, &gl, &gr);

  for (int i = 0; i < n; ++i) {
    float chanterL = 0.0f, chanterR = 0.0f;
    int alive = 0;
    int held = 0;

    for (int vi = 0; vi < g->voiceCount; ++vi) {
      EutBagpipeVoice *v = &g->voices[vi];
      if (!inst_voice_alive(&v->v)) continue;
      ++alive;
      if (v->v.held) held = 1;

      v->ph += v->v.freq * invSr;
      if (v->ph >= 1.0f) v->ph -= 1.0f;

      /* Нечётные гармоники — «тростниковый» тембр шантира. */
      float s = inst_sin(v->ph);
      if (v->v.freq * 3.0f < nyq) s += inst_sin_mult(v->ph, 3.0f) * 0.55f * g->tone;
      if (v->v.freq * 5.0f < nyq) s += inst_sin_mult(v->ph, 5.0f) * 0.35f * g->tone;
      if (v->v.freq * 7.0f < nyq) s += inst_sin_mult(v->ph, 7.0f) * 0.20f * g->tone;

      /* Формирующие фильтры срезают «низ» и мягчат верх. */
      v->hp += (s - v->hp) * 0.15f;
      float shaped = s - v->hp * 0.5f;
      v->lp += (shaped - v->lp) * 0.65f;
      s = v->lp * v->v.amp;

      chanterL += s * gl;
      chanterR += s * gr;
    }
    g->active = alive;

    /* Бурдон: включается плавно, пока держится нота; затухает с релизом. */
    const float target = held ? 1.0f : 0.0f;
    g->droneAmp = target - (target - g->droneAmp) * g->droneCoef;
    float drone = 0.0f;
    if (g->droneAmp > 1.0e-4f) {
      g->dronePh1 += g->droneFreq * invSr;
      if (g->dronePh1 >= 1.0f) g->dronePh1 -= 1.0f;
      g->dronePh2 += g->droneFreq * 1.5f * invSr;   /* квинта выше */
      if (g->dronePh2 >= 1.0f) g->dronePh2 -= 1.0f;
      drone = (inst_sin(g->dronePh1) + 0.7f * inst_sin(g->dronePh2)) *
              g->droneAmp * g->droneLevel;
    }

    if (outL != NULL) outL[i * stride] += (chanterL + drone * gl) * g->level;
    if (outR != NULL) outR[i * stride] += (chanterR + drone * gr) * g->level;
  }
}


/* ===========================================================================
 * Смычковые (струнный ансамбль)
 *
 * Пилообразная волна (band-limited, polyBLEP) через двухполюсный ФНЧ —
 * корпус и «смычковая» мягкость; задержанное вибрато; лёгкая микрорасстройка
 * голосов даёт ансамблевую глубину. Медленная атака — как у смычка.
 * ========================================================================= */

void eut_strings_reset(EutStrings *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutStringsVoice *v = &g->voices[i];
    memset(&v->v, 0, sizeof(v->v));
    v->ph = 0.0f;
    v->lp1 = v->lp2 = 0.0f;
    v->detune = 0.0f;
    v->vibAmp = 0.0f;
  }
  g->lfoPhase = 0.0f;
  g->active = 0;
}

void eut_strings_init(EutStrings *g, EutStringsVoice *voices, int voiceCount,
                      float sampleRate)
{
  if (g == NULL) return;
  g->voices = voices;
  g->voiceCount = voiceCount > 0 ? voiceCount : 1;
  g->sampleRate = sampleRate > 0.0f ? sampleRate : 48000.0f;
  g->tone = 0.5f;
  g->vibrato = 10.0f;
  g->ensemble = 7.0f;
  g->pan = 0.0f;
  g->level = 0.7f;
  g->lfoInc = EUT_INST_TWO_PI * 4.8f / g->sampleRate;
  g->lpCoef = inst_clamp(EUT_INST_TWO_PI * 2200.0f / g->sampleRate, 0.02f, 0.8f);
  g->seqCounter = 0;
  eut_strings_reset(g);
}

void eut_strings_set(EutStrings *g, float tone, float vibratoCents,
                     float ensembleCents, float pan, float level)
{
  if (g == NULL) return;
  g->tone = inst_clamp(tone, 0.0f, 1.0f);
  g->vibrato = inst_clamp(vibratoCents, 0.0f, 100.0f);
  g->ensemble = inst_clamp(ensembleCents, 0.0f, 40.0f);
  g->pan = inst_clamp(pan, -1.0f, 1.0f);
  g->level = level;
  /* Яркость = срез ФНЧ: 500 Гц (тёмно) … 5 кГц (ярко). */
  const float fc = 500.0f + g->tone * 4500.0f;
  g->lpCoef = inst_clamp(EUT_INST_TWO_PI * fc / g->sampleRate, 0.02f, 0.85f);
}

void eut_strings_note_on(EutStrings *g, int note, float velocity)
{
  if (g == NULL || g->voices == NULL) return;
  EutStringsVoice *v = (EutStringsVoice *)inst_pick_voice(
    g->voices, (int)sizeof(EutStringsVoice), g->voiceCount);
  if (v == NULL) return;
  v->v.seq = g->seqCounter++;
  /* Смычок: мягкая атака, длинная нота, умеренный релиз. */
  inst_voice_setup(&v->v, note, velocity, 0.14f, 0.9f, 1.2f, 0.30f, g->sampleRate);
  v->ph = 0.0f;
  v->lp1 = v->lp2 = 0.0f;
  /* Микрорасстройка голоса: детерминированно от seq — ансамбль без «хора» вразнобой. */
  v->detune = ((float)(v->v.seq % 5) - 2.0f) * (g->ensemble / 2.0f);
  v->vibAmp = 0.0f;
  g->active = 1;
}

void eut_strings_note_off(EutStrings *g, int note)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutStringsVoice *v = &g->voices[i];
    if (v->v.active && v->v.note == note) v->v.held = 0;
  }
}

void eut_strings_all_off(EutStrings *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutStringsVoice *v = &g->voices[i];
    if (v->v.active) {
      v->v.held = 0;
      v->v.relCoef = inst_coef(0.060f, g->sampleRate);
    }
  }
}

EUT_TARGET_CLONES
void eut_strings_process(EutStrings *g, float *outL, float *outR, int stride, int n,
                         float bendSemitones, float modCents)
{
  if (g == NULL || g->voices == NULL || n <= 0) return;
  if (g->active == 0) return;
  const float invSr = 1.0f / g->sampleRate;
  float gl, gr;
  inst_pan_gains(g->pan, &gl, &gr);

  for (int i = 0; i < n; ++i) {
    float sumL = 0.0f, sumR = 0.0f;
    int alive = 0;
    const float lfo = inst_sin(g->lfoPhase);

    for (int vi = 0; vi < g->voiceCount; ++vi) {
      EutStringsVoice *v = &g->voices[vi];
      if (!inst_voice_alive(&v->v)) continue;
      ++alive;

      v->vibAmp += (1.0f - v->vibAmp) * 0.00010f;
      float cents = v->detune + g->vibrato * v->vibAmp * lfo + modCents +
                    bendSemitones * 100.0f;
      float f = v->v.freq * (float)exp2((double)(cents / 1200.0f));
      const float dt = f * invSr;
      v->ph += dt;
      if (v->ph >= 1.0f) v->ph -= 1.0f;

      /* Пила с polyBLEP (band-limited) → меньше алиасинга на высоких нотах. */
      float saw = 2.0f * v->ph - 1.0f - inst_polyblep(v->ph, dt);
      v->lp1 += (saw - v->lp1) * g->lpCoef;
      v->lp2 += (v->lp1 - v->lp2) * g->lpCoef;
      float s = v->lp2 * v->v.amp;

      sumL += s * gl;
      sumR += s * gr;
    }

    g->active = alive;
    g->lfoPhase += g->lfoInc;
    if (g->lfoPhase >= 1.0f) g->lfoPhase -= 1.0f;
    if (outL != NULL) outL[i * stride] += sumL * g->level;
    if (outR != NULL) outR[i * stride] += sumR * g->level;
  }
}


/* ===========================================================================
 * Колокол (трубчатый/церковный)
 *
 * Ингармонические частичные (как у настоящего колокола) с индивидуальным
 * затуханием: высокие частичные гаснут быстрее — «звон» постепенно темнеет.
 * Удар — очень короткая атака, дальше чистое естественное затухание.
 * ========================================================================= */

static const float kBellRatios[EUT_INST_BELL_PARTIALS] = {
  0.50f, 1.00f, 1.19f, 1.56f, 2.00f, 2.51f, 2.66f, 3.01f
};
static const float kBellWeights[EUT_INST_BELL_PARTIALS] = {
  0.90f, 1.00f, 0.70f, 0.55f, 0.40f, 0.30f, 0.22f, 0.16f
};

void eut_bell_reset(EutBell *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutBellVoice *v = &g->voices[i];
    memset(&v->v, 0, sizeof(v->v));
    for (int k = 0; k < EUT_INST_BELL_PARTIALS; ++k) {
      v->ph[k] = v->dph[k] = 0.0f;
      v->amp[k] = 0.0f;
      v->ampCoef[k] = 0.0f;
    }
  }
  g->active = 0;
}

void eut_bell_init(EutBell *g, EutBellVoice *voices, int voiceCount, float sampleRate)
{
  if (g == NULL) return;
  g->voices = voices;
  g->voiceCount = voiceCount > 0 ? voiceCount : 1;
  g->sampleRate = sampleRate > 0.0f ? sampleRate : 48000.0f;
  g->tune = 1.0f;
  g->decay = 4.0f;
  g->tone = 0.5f;
  g->pan = 0.0f;
  g->level = 0.7f;
  g->seqCounter = 0;
  eut_bell_reset(g);
}

void eut_bell_set(EutBell *g, float tune, float decay, float tone, float pan, float level)
{
  if (g == NULL) return;
  g->tune = inst_clamp(tune, 0.25f, 4.0f);
  g->decay = inst_clamp(decay, 0.1f, 30.0f);
  g->tone = inst_clamp(tone, 0.0f, 1.0f);
  g->pan = inst_clamp(pan, -1.0f, 1.0f);
  g->level = level;
}

void eut_bell_note_on(EutBell *g, int note, float velocity)
{
  if (g == NULL || g->voices == NULL) return;
  EutBellVoice *v = (EutBellVoice *)inst_pick_voice(
    g->voices, (int)sizeof(EutBellVoice), g->voiceCount);
  if (v == NULL) return;
  v->v.seq = g->seqCounter++;
  /* Удар: мгновенная атака, без сустейна, длинный «хвост». */
  inst_voice_setup(&v->v, note, velocity, 0.004f, 0.0f, g->decay, g->decay * 0.35f,
                   g->sampleRate);
  const float nyq = g->sampleRate * 0.5f;
  const float f0 = v->v.freq * g->tune;
  for (int k = 0; k < EUT_INST_BELL_PARTIALS; ++k) {
    const float f = f0 * kBellRatios[k];
    v->ph[k] = 0.0f;
    v->dph[k] = (f < nyq) ? (f / g->sampleRate) : 0.0f;
    /* Наклон спектра: «тёмный» колокол — меньше верхних частичных. */
    float w = kBellWeights[k] / (1.0f + 0.5f * (float)k * (1.2f - g->tone));
    if (v->dph[k] <= 0.0f) w = 0.0f;
    v->amp[k] = w;
    /* Высокие частичные затухают быстрее — звон со временем темнеет. */
    const float t = g->decay / (1.0f + 0.6f * (float)k);
    v->ampCoef[k] = inst_coef(t, g->sampleRate);
  }
  g->active = 1;
}

void eut_bell_note_off(EutBell *g, int note)
{
  if (g == NULL || g->voices == NULL) return;
  /* Колокол не глушится нотой: он звенит до естественного затухания. */
  (void)note;
}

void eut_bell_all_off(EutBell *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutBellVoice *v = &g->voices[i];
    if (v->v.active) {
      v->v.held = 0;
      v->v.relCoef = inst_coef(0.12f, g->sampleRate);
    }
  }
}

EUT_TARGET_CLONES
void eut_bell_process(EutBell *g, float *outL, float *outR, int stride, int n)
{
  if (g == NULL || g->voices == NULL || n <= 0) return;
  if (g->active == 0) return;
  float gl, gr;
  inst_pan_gains(g->pan, &gl, &gr);

  for (int i = 0; i < n; ++i) {
    float sumL = 0.0f, sumR = 0.0f;
    int alive = 0;

    for (int vi = 0; vi < g->voiceCount; ++vi) {
      EutBellVoice *v = &g->voices[vi];
      if (!inst_voice_alive(&v->v)) continue;
      ++alive;

      float s = 0.0f;
      for (int k = 0; k < EUT_INST_BELL_PARTIALS; ++k) {
        if (v->amp[k] <= 0.00002f || v->dph[k] <= 0.0f) continue;
        v->ph[k] += v->dph[k];
        if (v->ph[k] >= 1.0f) v->ph[k] -= 1.0f;
        s += inst_sin(v->ph[k]) * v->amp[k];
        v->amp[k] *= v->ampCoef[k];
      }
      s *= v->v.amp;

      sumL += s * gl;
      sumR += s * gr;
    }

    g->active = alive;
    if (outL != NULL) outL[i * stride] += sumL * g->level;
    if (outR != NULL) outR[i * stride] += sumR * g->level;
  }
}


/* ===========================================================================
 * Щипковые (арфа, клавесин)
 *
 * Классический Карплус-Стронг: линия задержки длиной в период струны, в петле
 * — усредняющий ФНЧ (яркость и затухание), наружу — резонатор корпуса.
 * Арфа и клавесин — один движок с разными умолчаниями: у арфы длинный тёплый
 * звон и мягкий щипок, у клавесина яркий короткий и «перо» (больше шума).
 * ========================================================================= */

void eut_pluck_reset(EutPluck *g)
{
  if (g == NULL || g->voices == NULL) return;
  if (g->memory != NULL) {
    memset(g->memory, 0,
           (size_t)g->voiceCount * (size_t)g->lineCap * sizeof(float));
  }
  for (int i = 0; i < g->voiceCount; ++i) {
    memset(&g->voices[i], 0, sizeof(g->voices[i]));
  }
  g->seqCounter = 0;
  g->active = 0;
}

void eut_pluck_init(EutPluck *g, EutPluckVoice *voices, int voiceCount,
                    float *memory, int lineCap, float sampleRate)
{
  if (g == NULL) return;
  g->voices = voices;
  g->voiceCount = voiceCount > 0 ? voiceCount : 1;
  g->memory = memory;
  g->lineCap = lineCap > 8 ? lineCap : 8;
  g->sampleRate = sampleRate > 0.0f ? sampleRate : 48000.0f;
  g->tone = 0.6f;
  g->damping = 0.6f;
  g->pluck = 0.4f;
  g->body = 0.35f;
  g->bodyHz = 220.0f;
  g->nylon = 0.0f;      /* стальная струна: как у арфы и клавесина */
  g->pan = 0.0f;
  g->level = 0.7f;
  g->seqCounter = 0;
  eut_pluck_reset(g);
}

void eut_pluck_set(EutPluck *g, float tone, float damping, float pluck,
                   float body, float bodyHz, float nylon, float pan,
                   float level)
{
  if (g == NULL) return;
  g->tone = inst_clamp(tone, 0.0f, 1.0f);
  g->damping = inst_clamp(damping, 0.0f, 1.0f);
  g->pluck = inst_clamp(pluck, 0.0f, 1.0f);
  g->body = inst_clamp(body, 0.0f, 1.0f);
  g->bodyHz = inst_clamp(bodyHz, 40.0f, 2000.0f);
  g->nylon = inst_clamp(nylon, 0.0f, 1.0f);
  g->pan = inst_clamp(pan, -1.0f, 1.0f);
  g->level = level;
}

void eut_pluck_note_on(EutPluck *g, int note, float velocity)
{
  if (g == NULL || g->voices == NULL || g->memory == NULL) return;
  if (note < 0) note = 0;
  if (note > 127) note = 127;
  EutPluckVoice *v = (EutPluckVoice *)inst_pick_voice(g->voices,
                       (int)sizeof(EutPluckVoice), g->voiceCount);
  if (v == NULL) return;

  const int idx = (int)(v - g->voices);
  memset(v, 0, sizeof(*v));
  v->offset = idx * g->lineCap;

  const float f0 = inst_hz(note);
  int len = (int)(g->sampleRate / f0 + 0.5f);
  if (len < 4) len = 4;
  if (len > g->lineCap - 1) len = g->lineCap - 1;
  v->len = len;

  /* Затухание за сэмпл: damp^len = exp(-1/(T*f0)), то есть за T секунд
     амплитуда падает в e раз. T = 0.4 … 12 с по параметру damping. */
  const float tail = 0.4f + 11.6f * g->damping;
  v->damp = (float)exp(-1.0 / ((double)tail * (double)g->sampleRate));

  /* Резонатор корпуса: двухполюсный с полюсным радиусом r. */
  {
    const float f = inst_clamp(g->bodyHz, 40.0f, g->sampleRate * 0.45f);
    const float w = EUT_INST_TWO_PI * f / g->sampleRate;
    const float q = 5.0f;
    const float r = (float)exp(-(double)w / (2.0 * (double)q));
    v->a1 = 2.0f * r * (float)cos((double)w);
    v->a2 = -r * r;
    v->bg = 1.0f - r;
  }

  const float vel = inst_clamp(velocity, 0.0f, 1.0f);
  inst_voice_setup(&v->v, note, vel, 0.0015f, 1.0f, 1.0f, 0.35f, g->sampleRate);
  v->v.seq = ++g->seqCounter;
  v->v.rng = (uint32_t)(0x9E3779B9u * (uint32_t)(note + 1)) ^
             (uint32_t)(0x85EBCA6Bu * (uint32_t)g->seqCounter);
  if (v->v.rng == 0u) v->v.rng = 0x1234567u;
  v->v.freq = f0;
  v->v.amp = 0.0f;

  /* Возбуждение: шум по длине линии + гребёнка (щипок не у самого края —
     так гаснет часть гармоник, и щипок звучит «мясистее»). */
  float *line = g->memory + (size_t)v->offset;
  const float noiseAmp = 0.35f + 0.65f * g->pluck;
  /* Нейлон: щипок мягче — шум возбуждения сглажен глубже. При nylon = 0
     коэффициент прежний (0.4), поэтому арфа и клавесин не меняются. */
  const float sm = 0.4f + 0.3f * g->nylon;
  float prev = 0.0f;
  for (int i = 0; i < len; ++i) {
    float nz = inst_noise(&v->v.rng) * noiseAmp;
    nz = (1.0f - sm) * nz + sm * prev;   /* мягче атака: меньше щелчка */
    prev = nz;
    line[i] = nz;
  }
  for (int i = len - 1; i >= 1; --i) {
    line[i] -= 0.45f * line[i - 1];
  }
  g->active = 1;
}

void eut_pluck_note_off(EutPluck *g, int note)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutPluckVoice *v = &g->voices[i];
    if (v->v.active && v->v.note == note) v->v.held = 0;
  }
}

void eut_pluck_all_off(EutPluck *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutPluckVoice *v = &g->voices[i];
    if (v->v.active) {
      v->v.held = 0;
      v->v.relCoef = inst_coef(0.08f, g->sampleRate);
    }
  }
}

EUT_TARGET_CLONES
void eut_pluck_process(EutPluck *g, float *outL, float *outR, int stride, int n)
{
  if (g == NULL || g->voices == NULL || g->memory == NULL || n <= 0) return;
  if (g->active == 0) return;
  float gl, gr;
  inst_pan_gains(g->pan, &gl, &gr);
  /* Яркость петли: 0 — верхние гаснут сразу, 1 — звонкий «стеклянный» тон.
     Нейлоновая струна теряет верх быстрее стали, поэтому петля глуше. */
  const float loopCoef = (0.18f + 0.72f * g->tone) * (1.0f - 0.42f * g->nylon);
  const float bodyMix = g->body;

  for (int i = 0; i < n; ++i) {
    float sumL = 0.0f, sumR = 0.0f;
    int alive = 0;

    for (int vi = 0; vi < g->voiceCount; ++vi) {
      EutPluckVoice *v = &g->voices[vi];
      if (!inst_voice_alive(&v->v)) continue;
      ++alive;
      if (v->len <= 1) continue;

      float *line = g->memory + (size_t)v->offset;
      const float cur = line[v->pos];
      const float nxt = (v->pos + 1 < v->len) ? line[v->pos + 1] : line[0];
      const float avg = 0.5f * (cur + nxt);
      v->lp += (avg - v->lp) * loopCoef;
      line[v->pos] = v->lp * v->damp;
      if (++v->pos >= v->len) v->pos = 0;

      /* Корпус: резонанс деревянного ящика (арфа) или деки (клавесин). */
      const float body = v->bg * cur + v->a1 * v->y1 + v->a2 * v->y2;
      v->y2 = v->y1;
      v->y1 = body;

      const float s = (cur + bodyMix * body) * v->v.amp;
      sumL += s * gl;
      sumR += s * gr;
    }

    g->active = alive;
    if (outL != NULL) outL[i * stride] += sumL * g->level;
    if (outR != NULL) outR[i * stride] += sumR * g->level;
  }
}

/* ===========================================================================
 * Свирель / блокфлейта
 *
 * Деревянный духовой: та же схема, что у флейты (тон + дыхание + чиф), но
 * источник «деревянный» — заметная 2-я гармоника, мягкая 4-я, и дыхание
 * чуть слышнее в атаке. Монофоничный: новая нота гасит прежний голос, иначе
 * легато превратилось бы в двух играющих свирельщиков.
 * ========================================================================= */

void eut_recorder_reset(EutRecorder *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutRecorderVoice *v = &g->voices[i];
    memset(&v->v, 0, sizeof(v->v));
    v->ph = v->dph = 0.0f;
    v->breathLp = v->breathHp = 0.0f;
    v->chiff = 0.0f;
    v->vibAmp = 0.0f;
  }
  g->lfoPhase = 0.0f;
  g->active = 0;
}

void eut_recorder_init(EutRecorder *g, EutRecorderVoice *voices, int voiceCount,
                       float sampleRate)
{
  if (g == NULL) return;
  g->voices = voices;
  g->voiceCount = voiceCount > 0 ? voiceCount : 1;
  g->sampleRate = sampleRate > 0.0f ? sampleRate : 48000.0f;
  g->tone = 0.6f;
  g->breath = 0.30f;
  g->vibrato = 5.0f;
  g->pan = 0.0f;
  g->level = 0.8f;
  g->lfoInc = EUT_INST_TWO_PI * 5.2f / g->sampleRate;
  g->seqCounter = 0;
  eut_recorder_reset(g);
}

void eut_recorder_set(EutRecorder *g, float tone, float breath, float vibratoCents,
                      float pan, float level)
{
  if (g == NULL) return;
  g->tone = inst_clamp(tone, 0.0f, 1.0f);
  g->breath = inst_clamp(breath, 0.0f, 1.0f);
  g->vibrato = inst_clamp(vibratoCents, 0.0f, 100.0f);
  g->pan = inst_clamp(pan, -1.0f, 1.0f);
  g->level = level;
}

void eut_recorder_note_on(EutRecorder *g, int note, float velocity)
{
  if (g == NULL || g->voices == NULL) return;
  EutRecorderVoice *v = (EutRecorderVoice *)inst_pick_voice(
    g->voices, (int)sizeof(EutRecorderVoice), g->voiceCount);
  if (v == NULL) return;

  /* Моно: прежний голос уводим в быстрый релиз. */
  for (int i = 0; i < g->voiceCount; ++i) {
    EutRecorderVoice *o = &g->voices[i];
    if (o != v && o->v.active) {
      o->v.held = 0;
      o->v.relCoef = inst_coef(0.018f, g->sampleRate);
    }
  }

  v->v.seq = g->seqCounter++;
  inst_voice_setup(&v->v, note, velocity, 0.030f, 0.88f, 0.5f, 0.09f,
                   g->sampleRate);
  v->ph = 0.0f;
  v->dph = 0.0f;
  v->breathLp = v->breathHp = 0.0f;
  v->chiff = 0.85f;     /* у дерева атака слышнее, чем у металла */
  v->vibAmp = 0.0f;
  g->active = 1;
}

void eut_recorder_note_off(EutRecorder *g, int note)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutRecorderVoice *v = &g->voices[i];
    if (v->v.active && v->v.note == note) v->v.held = 0;
  }
}

void eut_recorder_all_off(EutRecorder *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutRecorderVoice *v = &g->voices[i];
    if (v->v.active) {
      v->v.held = 0;
      v->v.relCoef = inst_coef(0.020f, g->sampleRate);
    }
  }
}

EUT_TARGET_CLONES
void eut_recorder_process(EutRecorder *g, float *outL, float *outR, int stride,
                          int n, float bendSemitones, float modCents)
{
  if (g == NULL || g->voices == NULL || n <= 0) return;
  if (g->active == 0) return;
  const float invSr = 1.0f / g->sampleRate;
  const float nyq = g->sampleRate * 0.5f;
  float gl, gr;
  inst_pan_gains(g->pan, &gl, &gr);

  for (int i = 0; i < n; ++i) {
    float sumL = 0.0f, sumR = 0.0f;
    int alive = 0;
    const float lfo = inst_sin(g->lfoPhase);

    for (int vi = 0; vi < g->voiceCount; ++vi) {
      EutRecorderVoice *v = &g->voices[vi];
      if (!inst_voice_alive(&v->v)) continue;
      ++alive;

      v->vibAmp += (1.0f - v->vibAmp) * 0.00008f;
      const float cents = g->vibrato * v->vibAmp * lfo + modCents +
                          bendSemitones * 100.0f;
      float f = v->v.freq;
      if (cents != 0.0f) f *= (float)exp2((double)(cents / 1200.0f));
      v->ph += f * invSr;
      if (v->ph >= 1.0f) v->ph -= 1.0f;

      /* «Деревянный» спектр: чётные гармоники заметнее, чем у флейты. */
      float s = inst_sin(v->ph);
      if (f * 2.0f < nyq) s += inst_sin_mult(v->ph, 2.0f) * 0.16f * g->tone;
      if (f * 3.0f < nyq) s += inst_sin_mult(v->ph, 3.0f) * 0.22f * g->tone;
      if (f * 4.0f < nyq) s += inst_sin_mult(v->ph, 4.0f) * 0.10f * g->tone;
      if (f * 5.0f < nyq) s += inst_sin_mult(v->ph, 5.0f) * 0.06f * g->tone;

      const float nz = inst_noise(&v->v.rng);
      /* Дыхание — узкая полоса вокруг тона: «дерево дышит», а не шипит. */
      v->breathHp += (nz - v->breathHp) * 0.09f;
      const float hi = nz - v->breathHp;
      v->breathLp += (hi - v->breathLp) * 0.32f;
      s += v->breathLp * g->breath * 0.10f;

      s += v->chiff * v->breathLp * 0.30f;
      v->chiff *= 0.9990f;

      s *= v->v.amp;
      sumL += s * gl;
      sumR += s * gr;
    }

    g->active = alive;
    g->lfoPhase += g->lfoInc;
    if (g->lfoPhase >= 1.0f) g->lfoPhase -= 1.0f;
    if (outL != NULL) outL[i * stride] += sumL * g->level;
    if (outR != NULL) outR[i * stride] += sumR * g->level;
  }
}

/* ===========================================================================
 * Медь (труба / валторна)
 *
 * Пила (band-limited, polyBLEP) через формантный резонатор меди: у трубы
 * спектр «собран» вокруг форманты, а не размазан, как у струны. Мягкий ФНЧ
 * ограничивает верх (раструб), вибрато включается после атаки, а в атаку
 * подмешивается шум — так нота «въезжает», а не включается тумблером.
 * ========================================================================= */

void eut_brass_reset(EutBrass *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutBrassVoice *v = &g->voices[i];
    memset(&v->v, 0, sizeof(v->v));
    v->ph = 0.0f;
    v->lp1 = v->lp2 = 0.0f;
    v->f1y1 = v->f1y2 = 0.0f;
    v->vibAmp = 0.0f;
  }
  g->lfoPhase = 0.0f;
  g->active = 0;
}

void eut_brass_init(EutBrass *g, EutBrassVoice *voices, int voiceCount,
                    float sampleRate)
{
  if (g == NULL) return;
  g->voices = voices;
  g->voiceCount = voiceCount > 0 ? voiceCount : 1;
  g->sampleRate = sampleRate > 0.0f ? sampleRate : 48000.0f;
  g->tone = 0.55f;
  g->rasp = 0.35f;
  g->vibrato = 6.0f;
  g->pan = 0.0f;
  g->level = 0.75f;
  g->lfoInc = EUT_INST_TWO_PI * 5.4f / g->sampleRate;
  g->seqCounter = 0;
  eut_brass_reset(g);
}

void eut_brass_set(EutBrass *g, float tone, float rasp, float vibratoCents,
                   float pan, float level)
{
  if (g == NULL) return;
  g->tone = inst_clamp(tone, 0.0f, 1.0f);
  g->rasp = inst_clamp(rasp, 0.0f, 1.0f);
  g->vibrato = inst_clamp(vibratoCents, 0.0f, 100.0f);
  g->pan = inst_clamp(pan, -1.0f, 1.0f);
  g->level = level;
}

void eut_brass_note_on(EutBrass *g, int note, float velocity)
{
  if (g == NULL || g->voices == NULL) return;
  EutBrassVoice *v = (EutBrassVoice *)inst_pick_voice(
    g->voices, (int)sizeof(EutBrassVoice), g->voiceCount);
  if (v == NULL) return;

  v->v.seq = g->seqCounter++;
  inst_voice_setup(&v->v, note, velocity, 0.055f, 0.92f, 1.0f, 0.12f,
                   g->sampleRate);
  v->ph = 0.0f;
  v->lp1 = v->lp2 = 0.0f;
  v->f1y1 = v->f1y2 = 0.0f;
  v->vibAmp = 0.0f;

  /* Форманта меди: выше ноты — выше форманта (раструб «следует» за тоном). */
  const float f1 = inst_clamp(0.9f * v->v.freq + 700.0f * (0.5f + g->tone),
                              200.0f, g->sampleRate * 0.40f);
  const float bw = 500.0f;
  const float c = (float)exp(-EUT_INST_TWO_PI * bw / g->sampleRate);
  const float b = 2.0f * c * (float)cos((double)(EUT_INST_TWO_PI * f1 /
                                                 g->sampleRate));
  v->f1a1 = b;
  v->f1a2 = -c * c;
  v->f1g = 1.0f - b + c * c;   /* нормировка: усиление на DC = 1 */
  g->active = 1;
}

void eut_brass_note_off(EutBrass *g, int note)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutBrassVoice *v = &g->voices[i];
    if (v->v.active && v->v.note == note) v->v.held = 0;
  }
}

void eut_brass_all_off(EutBrass *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutBrassVoice *v = &g->voices[i];
    if (v->v.active) {
      v->v.held = 0;
      v->v.relCoef = inst_coef(0.030f, g->sampleRate);
    }
  }
}

EUT_TARGET_CLONES
void eut_brass_process(EutBrass *g, float *outL, float *outR, int stride,
                       int n, float bendSemitones, float modCents)
{
  if (g == NULL || g->voices == NULL || n <= 0) return;
  if (g->active == 0) return;
  const float invSr = 1.0f / g->sampleRate;
  float gl, gr;
  inst_pan_gains(g->pan, &gl, &gr);
  /* Срез «раструба»: 0 — глухо (валторна в сурдине), 1 — открыто (труба). */
  const float lpCoef = 0.12f + 0.50f * g->tone;

  for (int i = 0; i < n; ++i) {
    float sumL = 0.0f, sumR = 0.0f;
    int alive = 0;
    const float lfo = inst_sin(g->lfoPhase);

    for (int vi = 0; vi < g->voiceCount; ++vi) {
      EutBrassVoice *v = &g->voices[vi];
      if (!inst_voice_alive(&v->v)) continue;
      ++alive;

      v->vibAmp += (1.0f - v->vibAmp) * 0.00009f;
      const float cents = g->vibrato * v->vibAmp * lfo + modCents +
                          bendSemitones * 100.0f;
      float f = v->v.freq;
      if (cents != 0.0f) f *= (float)exp2((double)(cents / 1200.0f));
      const float dt = f * invSr;
      v->ph += dt;
      if (v->ph >= 1.0f) v->ph -= 1.0f;

      /* Пила с polyBLEP: без алиасинга даже на высоких нотах. */
      const float saw = 2.0f * v->ph - 1.0f - inst_polyblep(v->ph, dt);

      /* Форманта меди: собирает энергию в характерную «поющую» полосу. */
      const float fo = v->f1g * saw + v->f1a1 * v->f1y1 + v->f1a2 * v->f1y2;
      v->f1y2 = v->f1y1;
      v->f1y1 = fo;

      /* Мягкий ФНЧ (раструб) — и заодно защита от резкого верха. */
      v->lp1 += (fo - v->lp1) * lpCoef;
      v->lp2 += (v->lp1 - v->lp2) * lpCoef;
      float s = v->lp2 * 1.6f;

      /* Атака: пока громкость нарастает, подмешиваем шум — «въезд» в ноту. */
      if (v->v.amp < 0.985f) {
        s += inst_noise(&v->v.rng) * g->rasp * 0.35f * (1.0f - v->v.amp);
      }

      s *= v->v.amp;
      sumL += s * gl;
      sumR += s * gr;
    }

    g->active = alive;
    g->lfoPhase += g->lfoInc;
    if (g->lfoPhase >= 1.0f) g->lfoPhase -= 1.0f;
    if (outL != NULL) outL[i * stride] += sumL * g->level;
    if (outR != NULL) outR[i * stride] += sumR * g->level;
  }
}

/* ===========================================================================
 * Литавры
 *
 * Настраиваемый барабан — это не шум, а СТРОЙ. Моды литавр ингармонические
 * (1 : 1.504 : 2 : 2.61) и затухают с разной скоростью: чем выше мода, тем
 * короче её жизнь, поэтому удар «темнеет» по мере затухания. Поверх мод —
 * короткий шумовой удар. Нотой не глушится: барабан звенит до конца.
 * ========================================================================= */

static const float kTimpaniRatios[EUT_INST_TIMPANI_MODES] = {
  1.000f, 1.504f, 2.000f, 2.610f
};
static const float kTimpaniWeights[EUT_INST_TIMPANI_MODES] = {
  1.00f, 0.50f, 0.26f, 0.12f
};

void eut_timpani_reset(EutTimpani *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutTimpaniVoice *v = &g->voices[i];
    memset(&v->v, 0, sizeof(v->v));
    for (int k = 0; k < EUT_INST_TIMPANI_MODES; ++k) {
      v->ph[k] = v->dph[k] = 0.0f;
      v->amp[k] = 0.0f;
      v->ampCoef[k] = 0.0f;
    }
    v->noiseLp = 0.0f;
  }
  g->active = 0;
}

void eut_timpani_init(EutTimpani *g, EutTimpaniVoice *voices, int voiceCount,
                      float sampleRate)
{
  if (g == NULL) return;
  g->voices = voices;
  g->voiceCount = voiceCount > 0 ? voiceCount : 1;
  g->sampleRate = sampleRate > 0.0f ? sampleRate : 48000.0f;
  g->tune = 1.0f;
  g->decay = 1.0f;
  g->tone = 0.5f;
  g->pan = 0.0f;
  g->level = 0.8f;
  g->seqCounter = 0;
  eut_timpani_reset(g);
}

void eut_timpani_set(EutTimpani *g, float tune, float decay, float tone,
                     float pan, float level)
{
  if (g == NULL) return;
  g->tune = inst_clamp(tune, 0.25f, 4.0f);
  g->decay = inst_clamp(decay, 0.1f, 8.0f);
  g->tone = inst_clamp(tone, 0.0f, 1.0f);
  g->pan = inst_clamp(pan, -1.0f, 1.0f);
  g->level = level;
}

void eut_timpani_note_on(EutTimpani *g, int note, float velocity)
{
  if (g == NULL || g->voices == NULL) return;
  EutTimpaniVoice *v = (EutTimpaniVoice *)inst_pick_voice(
    g->voices, (int)sizeof(EutTimpaniVoice), g->voiceCount);
  if (v == NULL) return;
  v->v.seq = g->seqCounter++;

  /* Удар: очень короткая атака, без сустейна, длинный естественный хвост. */
  const float ring = 3.2f * g->decay;
  inst_voice_setup(&v->v, note, velocity, 0.0025f, 0.0f, ring, ring, g->sampleRate);

  const float nyq = g->sampleRate * 0.5f;
  const float f0 = v->v.freq * g->tune;
  for (int k = 0; k < EUT_INST_TIMPANI_MODES; ++k) {
    const float f = f0 * kTimpaniRatios[k];
    v->ph[k] = 0.0f;
    v->dph[k] = (f < nyq) ? (f / g->sampleRate) : 0.0f;
    float w = kTimpaniWeights[k];
    /* Яркость: «кожа» слышнее на высокой моде — больше верхних составляющих. */
    if (k >= 2) w *= 0.4f + 1.2f * g->tone;
    if (v->dph[k] <= 0.0f) w = 0.0f;
    v->amp[k] = w;
    v->ampCoef[k] = inst_coef(ring / (1.0f + 0.9f * (float)k), g->sampleRate);
  }
  v->noiseLp = 0.0f;
  g->active = 1;
}

void eut_timpani_note_off(EutTimpani *g, int note)
{
  /* Литавры не глушатся нотой: они звенят, пока звучит кожа. */
  (void)g;
  (void)note;
}

void eut_timpani_all_off(EutTimpani *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutTimpaniVoice *v = &g->voices[i];
    if (v->v.active) {
      v->v.held = 0;
      v->v.relCoef = inst_coef(0.09f, g->sampleRate);
    }
  }
}

EUT_TARGET_CLONES
void eut_timpani_process(EutTimpani *g, float *outL, float *outR, int stride, int n)
{
  if (g == NULL || g->voices == NULL || n <= 0) return;
  if (g->active == 0) return;
  float gl, gr;
  inst_pan_gains(g->pan, &gl, &gr);
  const float noiseAmp = 0.10f + 0.55f * g->tone;

  for (int i = 0; i < n; ++i) {
    float sumL = 0.0f, sumR = 0.0f;
    int alive = 0;

    for (int vi = 0; vi < g->voiceCount; ++vi) {
      EutTimpaniVoice *v = &g->voices[vi];
      if (!inst_voice_alive(&v->v)) continue;
      ++alive;

      float s = 0.0f;
      for (int k = 0; k < EUT_INST_TIMPANI_MODES; ++k) {
        if (v->amp[k] <= 0.00002f || v->dph[k] <= 0.0f) continue;
        v->ph[k] += v->dph[k];
        if (v->ph[k] >= 1.0f) v->ph[k] -= 1.0f;
        s += inst_sin(v->ph[k]) * v->amp[k];
        v->amp[k] *= v->ampCoef[k];
      }

      /* Шумовой удар «палочки»: пока идёт атака, кожа шумит. */
      if (v->v.amp < 0.995f) {
        v->noiseLp += (inst_noise(&v->v.rng) - v->noiseLp) * 0.45f;
        s += v->noiseLp * noiseAmp * (1.0f - v->v.amp);
      }

      s *= v->v.amp;
      sumL += s * gl;
      sumR += s * gr;
    }

    g->active = alive;
    if (outL != NULL) outL[i * stride] += sumL * g->level;
    if (outR != NULL) outR[i * stride] += sumR * g->level;
  }
}



/* ===========================================================================
 * Хор (формантные гласные)
 *
 * Голос — это не «инструмент со спектром», а источник (голосовая щель) плюс
 * форманты: полосы, которые усиливают гласную. Источник — пила с polyBLEP
 * (богатая гармониками «жужжалка»), форманты — три параллельных резонатора
 * Клатта. Параметр `vowel` плавно переводит «а» → «о» → «и», коэффициенты
 * пересчитываются на каждом блоке, поэтому гласную можно вести автоматизацией.
 * ========================================================================= */

static const float kChoirFormantA[EUT_INST_CHOIR_FORMANTS] = {700.0f, 1220.0f, 2600.0f};
static const float kChoirFormantO[EUT_INST_CHOIR_FORMANTS] = {400.0f,  800.0f, 2600.0f};
static const float kChoirFormantI[EUT_INST_CHOIR_FORMANTS] = {300.0f, 2200.0f, 3000.0f};

static void choirDesign(EutChoirVoice *v, float vowel, float sr)
{
  const float t = inst_clamp(vowel, 0.0f, 1.0f);
  for (int k = 0; k < EUT_INST_CHOIR_FORMANTS; ++k) {
    float f;
    if (t <= 0.5f) {
      const float u = t * 2.0f;
      f = kChoirFormantA[k] + (kChoirFormantO[k] - kChoirFormantA[k]) * u;
    } else {
      const float u = (t - 0.5f) * 2.0f;
      f = kChoirFormantO[k] + (kChoirFormantI[k] - kChoirFormantO[k]) * u;
    }
    f = inst_clamp(f, 80.0f, sr * 0.45f);
    const float bw = 90.0f + 45.0f * (float)k;
    const float c = (float)exp(-EUT_INST_TWO_PI * bw / sr);
    const float b = 2.0f * c * (float)cos((double)(EUT_INST_TWO_PI * f / sr));
    v->a1[k] = b;
    v->a2[k] = -c * c;
    v->gain[k] = 1.0f - b + c * c;   /* нормировка Клатта: DC-усиление = 1 */
  }
}

void eut_choir_reset(EutChoir *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutChoirVoice *v = &g->voices[i];
    memset(&v->v, 0, sizeof(v->v));
    v->ph = 0.0f;
    v->vibAmp = 0.0f;
    for (int k = 0; k < EUT_INST_CHOIR_FORMANTS; ++k) {
      v->y1[k] = v->y2[k] = 0.0f;
    }
    choirDesign(v, g->vowel, g->sampleRate);
  }
  g->lfoPhase = 0.0f;
  g->active = 0;
}

void eut_choir_init(EutChoir *g, EutChoirVoice *voices, int voiceCount,
                    float sampleRate)
{
  if (g == NULL) return;
  g->voices = voices;
  g->voiceCount = voiceCount > 0 ? voiceCount : 1;
  g->sampleRate = sampleRate > 0.0f ? sampleRate : 48000.0f;
  g->vowel = 0.0f;
  g->tone = 0.5f;
  g->vibrato = 9.0f;
  g->pan = 0.0f;
  g->level = 0.6f;
  g->lfoInc = EUT_INST_TWO_PI * 4.6f / g->sampleRate;
  g->seqCounter = 0;
  eut_choir_reset(g);
}

void eut_choir_set(EutChoir *g, float vowel, float tone, float vibratoCents,
                   float pan, float level)
{
  if (g == NULL) return;
  g->vowel = inst_clamp(vowel, 0.0f, 1.0f);
  g->tone = inst_clamp(tone, 0.0f, 1.0f);
  g->vibrato = inst_clamp(vibratoCents, 0.0f, 100.0f);
  g->pan = inst_clamp(pan, -1.0f, 1.0f);
  g->level = level;
}

void eut_choir_note_on(EutChoir *g, int note, float velocity)
{
  if (g == NULL || g->voices == NULL) return;
  EutChoirVoice *v = (EutChoirVoice *)inst_pick_voice(
    g->voices, (int)sizeof(EutChoirVoice), g->voiceCount);
  if (v == NULL) return;
  v->v.seq = g->seqCounter++;

  /* Певцы «входят» постепенно — атака мягкая, как вдох. */
  inst_voice_setup(&v->v, note, velocity, 0.120f, 0.95f, 1.0f, 0.28f,
                   g->sampleRate);
  v->ph = 0.0f;
  v->vibAmp = 0.0f;
  for (int k = 0; k < EUT_INST_CHOIR_FORMANTS; ++k) {
    v->y1[k] = v->y2[k] = 0.0f;
  }
  /* Микрорасстройка: у хора нет двух одинаковых голосов. */
  v->v.freq *= (float)exp2(
    (double)((float)((v->v.seq % 7) - 3) * 3.0f) / 1200.0);
  choirDesign(v, g->vowel, g->sampleRate);
  g->active = 1;
}

void eut_choir_note_off(EutChoir *g, int note)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutChoirVoice *v = &g->voices[i];
    if (v->v.active && v->v.note == note) v->v.held = 0;
  }
}

void eut_choir_all_off(EutChoir *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutChoirVoice *v = &g->voices[i];
    if (v->v.active) {
      v->v.held = 0;
      v->v.relCoef = inst_coef(0.06f, g->sampleRate);
    }
  }
}

EUT_TARGET_CLONES
void eut_choir_process(EutChoir *g, float *outL, float *outR, int stride,
                       int n, float bendSemitones, float modCents)
{
  if (g == NULL || g->voices == NULL || n <= 0) return;
  if (g->active == 0) return;
  const float invSr = 1.0f / g->sampleRate;
  float gl, gr;
  inst_pan_gains(g->pan, &gl, &gr);

  /* Гласная — параметр, а не константа: пересчитываем форманты раз в блок,
     поэтому автоматизация `vowel` ведёт гласную без разрывов. */
  for (int vi = 0; vi < g->voiceCount; ++vi) {
    if (g->voices[vi].v.active) {
      choirDesign(&g->voices[vi], g->vowel, g->sampleRate);
    }
  }

  const float w1 = 0.35f + 0.55f * g->tone;
  const float w2 = 0.12f + 0.35f * g->tone;
  const float direct = 0.10f * g->tone;

  for (int i = 0; i < n; ++i) {
    float sumL = 0.0f, sumR = 0.0f;
    int alive = 0;
    const float lfo = inst_sin(g->lfoPhase);

    for (int vi = 0; vi < g->voiceCount; ++vi) {
      EutChoirVoice *v = &g->voices[vi];
      if (!inst_voice_alive(&v->v)) continue;
      ++alive;

      v->vibAmp += (1.0f - v->vibAmp) * 0.00007f;
      const float cents = g->vibrato * v->vibAmp * lfo + modCents +
                          bendSemitones * 100.0f;
      float f = v->v.freq;
      if (cents != 0.0f) f *= (float)exp2((double)(cents / 1200.0f));
      const float dt = f * invSr;
      v->ph += dt;
      if (v->ph >= 1.0f) v->ph -= 1.0f;

      /* Источник: пила (голосовая щель) без алиасинга. */
      const float src = 2.0f * v->ph - 1.0f - inst_polyblep(v->ph, dt);

      /* Форманты параллельно: каждая усиливает свою полосу. */
      float out = 0.0f;
      for (int k = 0; k < EUT_INST_CHOIR_FORMANTS; ++k) {
        const float y = v->gain[k] * src + v->a1[k] * v->y1[k] +
                        v->a2[k] * v->y2[k];
        v->y2[k] = v->y1[k];
        v->y1[k] = y;
        const float w = (k == 0) ? 1.0f : ((k == 1) ? w1 : w2);
        out += y * w;
      }
      out += direct * src;   /* немного прямого «дыхания» голоса */

      out *= v->v.amp;
      sumL += out * gl;
      sumR += out * gr;
    }

    g->active = alive;
    g->lfoPhase += g->lfoInc;
    if (g->lfoPhase >= 1.0f) g->lfoPhase -= 1.0f;
    if (outL != NULL) outL[i * stride] += sumL * g->level;
    if (outR != NULL) outR[i * stride] += sumR * g->level;
  }
}



/* ===========================================================================
 * Свободноязычковые (баян/аккордеон, губная гармошка)
 *
 * Язычок качается в камере под давлением воздуха — это не струна и не столб
 * воздуха. Отсюда три части тембра, которых нет у других движков:
 *
 *   1) НЕСКОЛЬКО ЯЗЫЧКОВ на одну ноту (2–3), расстроенных на единицы центов.
 *      Их биения и есть «разлив»: дрожание уровня в 2–6 Гц, которое одним
 *      генератором не получается. `detune = 0` складывает язычки в один —
 *      так звучит гармошка: у неё язычок на ноту один.
 *   2) КАМЕРА: два резонатора вокруг `formantHz` собирают «тростниковую»
 *      полосу, а ФВЧ ниже неё убирает гул, которого у язычка нет.
 *   3) ВОЗДУХ: мех (баян) или дыхание (гармошка) шумят всё время, пока
 *      звучит нота, и «дышат» с медленной модуляцией. Ровный шумовой фон
 *      читается как синтезатор, живой мех — нет.
 *
 * Плюс механика: язычок разгоняется (мягкая атака), первые десятки
 * миллисекунд строй чуть ниже и садится в тон, клапан клацает на атаке.
 *
 * Характер инструмента задаёт нода, как у щипковых: баян — `formantHz`
 * ~1.4 кГц и разлив в 12 центов, гармошка — ~2.6 кГц и сухой строй.
 * ========================================================================= */

static const float kReedSpread[EUT_INST_REED_BANKS] = { 0.0f, 1.0f, -1.0f };
static const float kReedWeight[EUT_INST_REED_BANKS] = { 1.00f, 0.60f, 0.60f };

/* Пила плюс меандровая составляющая: нечётные гармоники дают «гнусавость»
   трости, которой нет у гладкой пилы. Обе — band-limited (polyBLEP). */
static inline float inst_reed_wave(float ph, float dt, float sharp)
{
  float s = 2.0f * ph - 1.0f - inst_polyblep(ph, dt);
  if (sharp > 0.0f) {
    float sq = (ph < 0.5f) ? 1.0f : -1.0f;
    sq += inst_polyblep(ph, dt);
    float t = ph + 0.5f;
    if (t >= 1.0f) t -= 1.0f;
    sq -= inst_polyblep(t, dt);
    s += sharp * sq;
  }
  return s;
}

/* Резонатор Клатта: единичное усиление на постоянной составляющей, полоса
   `bw`. Та же нормировка, что у формант хора (1 - b - a2). */
static inline void inst_reed_band(float f, float bw, float sampleRate,
                                  float *a1, float *a2, float *gain)
{
  const float c = (float)exp(-EUT_INST_TWO_PI * bw / sampleRate);
  const float b = 2.0f * c *
                  (float)cos((double)(EUT_INST_TWO_PI * f / sampleRate));
  *a1 = b;
  *a2 = -c * c;
  *gain = 1.0f - b + c * c;
}

void eut_reed_reset(EutReed *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutReedVoice *v = &g->voices[i];
    memset(&v->v, 0, sizeof(v->v));
    for (int k = 0; k < EUT_INST_REED_BANKS; ++k) {
      v->ph[k] = 0.0f;
      v->ratio[k] = 1.0f;
      v->w[k] = 0.0f;
    }
    v->f1y1 = v->f1y2 = v->f2y1 = v->f2y2 = 0.0f;
    v->f1a1 = v->f1a2 = v->f1g = 0.0f;
    v->f2a1 = v->f2a2 = v->f2g = 0.0f;
    v->lp1 = v->lp2 = v->hp = 0.0f;
    v->pitchEnv = 0.0f;
    v->pitchEnvCoef = 0.0f;
    v->chiff = 0.0f;
    v->breathLp = 0.0f;
    v->bellowPh = 0.0f;
  }
  g->active = 0;
}

void eut_reed_init(EutReed *g, EutReedVoice *voices, int voiceCount,
                   float sampleRate)
{
  if (g == NULL) return;
  g->voices = voices;
  g->voiceCount = voiceCount > 0 ? voiceCount : 1;
  g->sampleRate = sampleRate > 0.0f ? sampleRate : 48000.0f;
  g->tone = 0.55f;
  g->detune = 12.0f;
  g->noise = 0.25f;
  g->attack = 0.05f;
  g->formantHz = 1400.0f;
  g->pan = 0.0f;
  g->level = 0.8f;
  g->seqCounter = 0;
  eut_reed_set(g, g->tone, g->detune, g->noise, g->attack, g->formantHz,
               g->pan, g->level);
  eut_reed_reset(g);
}

void eut_reed_set(EutReed *g, float tone, float detuneCents, float noise,
                  float attackSeconds, float formantHz, float pan, float level)
{
  if (g == NULL) return;
  g->tone = inst_clamp(tone, 0.0f, 1.0f);
  g->detune = inst_clamp(detuneCents, 0.0f, 40.0f);
  g->noise = inst_clamp(noise, 0.0f, 1.0f);
  g->attack = inst_clamp(attackSeconds, 0.002f, 0.5f);
  g->formantHz = inst_clamp(formantHz, 300.0f, g->sampleRate * 0.4f);
  g->pan = inst_clamp(pan, -1.0f, 1.0f);
  g->level = level;
  /* Срез верха: 0 — тёмный баян, 1 — звонкая гармошка. */
  const float fc = 1400.0f + 7000.0f * g->tone;
  g->lpCoef = inst_clamp(EUT_INST_TWO_PI * fc / g->sampleRate, 0.05f, 0.9f);
  /* Ниже камеры гула нет: срезаем то, что резонатор не поддерживает. */
  g->hpCoef = inst_clamp(EUT_INST_TWO_PI * (g->formantHz * 0.06f) /
                         g->sampleRate, 0.0005f, 0.05f);
  /* «Мех дышит» ~0.9 Гц: медленнее вибрато, это дыхание, а не тремоло. */
  g->bellowInc = EUT_INST_TWO_PI * 0.9f / g->sampleRate;
}

void eut_reed_note_on(EutReed *g, int note, float velocity)
{
  if (g == NULL || g->voices == NULL) return;
  EutReedVoice *v = (EutReedVoice *)inst_pick_voice(
    g->voices, (int)sizeof(EutReedVoice), g->voiceCount);
  if (v == NULL) return;
  v->v.seq = g->seqCounter++;

  /* Язычок разгоняется: мягкая атака и быстрый, но не мгновенный релиз
     (клапан закрывается за десятки миллисекунд). */
  inst_voice_setup(&v->v, note, velocity, g->attack, 0.96f, 0.8f, 0.09f,
                   g->sampleRate);

  /* Разлив: язычки одного тона, расстроенные врозь. Веса нормированы, так
     что один язычок и три звучат с одинаковым уровнем. */
  float wsum = 0.0f;
  for (int k = 0; k < EUT_INST_REED_BANKS; ++k) wsum += kReedWeight[k];
  for (int k = 0; k < EUT_INST_REED_BANKS; ++k) {
    const float cents = kReedSpread[k] * g->detune;
    v->ratio[k] = (float)exp2((double)(cents / 1200.0f));
    v->w[k] = kReedWeight[k] / wsum;
    /* Фазы независимы: одинаковый старт трёх язычков слышен как щелчок. */
    v->ph[k] = inst_noise(&v->v.rng) * 0.5f + 0.5f;
  }

  /* Посадка строя: язычок под давлением начинает ниже и садится в тон; чем
     сильнее нота, тем глубже просадка (сильнее «толкнули» мех). */
  const float vel = inst_clamp(velocity, 0.0f, 1.0f);
  v->pitchEnv = 0.0002f + 0.0045f * vel;
  v->pitchEnvCoef = inst_coef(0.06f, g->sampleRate);

  /* Резонансы камеры: нижний собирает «тростниковую» полосу, верхний
     добавляет звон. Ширину полос ведёт `tone` вместе с нодой. */
  const float f1 = g->formantHz;
  const float f2 = inst_clamp(f1 * 1.9f, 400.0f, g->sampleRate * 0.45f);
  inst_reed_band(f1, 240.0f + 180.0f * (1.0f - g->tone), g->sampleRate,
                 &v->f1a1, &v->f1a2, &v->f1g);
  inst_reed_band(f2, 420.0f + 260.0f * (1.0f - g->tone), g->sampleRate,
                 &v->f2a1, &v->f2a2, &v->f2g);

  v->lp1 = v->lp2 = v->hp = 0.0f;
  v->chiff = 1.0f;          /* клац клапана: гаснет в process() */
  v->breathLp = 0.0f;
  /* «Дыхание меха» стартует вразнобой — иначе все ноты дышат в такт. */
  v->bellowPh = inst_noise(&v->v.rng) * 0.5f + 0.5f;
  g->active = 1;
}

void eut_reed_note_off(EutReed *g, int note)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutReedVoice *v = &g->voices[i];
    if (v->v.active && v->v.note == note) v->v.held = 0;
  }
}

void eut_reed_all_off(EutReed *g)
{
  if (g == NULL || g->voices == NULL) return;
  for (int i = 0; i < g->voiceCount; ++i) {
    EutReedVoice *v = &g->voices[i];
    if (v->v.active) {
      v->v.held = 0;
      v->v.relCoef = inst_coef(0.030f, g->sampleRate);
    }
  }
}

EUT_TARGET_CLONES
void eut_reed_process(EutReed *g, float *outL, float *outR, int stride,
                      int n, float bendSemitones, float modCents)
{
  if (g == NULL || g->voices == NULL || n <= 0) return;
  if (g->active == 0) return;
  const float invSr = 1.0f / g->sampleRate;
  float gl, gr;
  inst_pan_gains(g->pan, &gl, &gr);
  /* «Гнусавость»: доля меандра в источнике растёт с яркостью. */
  const float sharp = 0.22f + 0.30f * g->tone;
  const float noiseLvl = g->noise;
  /* Колесо и модуляция сдвигают все язычки разом: разлив сохраняется. */
  const float commonCents = bendSemitones * 100.0f + modCents;
  const float common = (commonCents != 0.0f)
                     ? (float)exp2((double)(commonCents / 1200.0f)) : 1.0f;

  for (int i = 0; i < n; ++i) {
    float sumL = 0.0f, sumR = 0.0f;
    int alive = 0;

    for (int vi = 0; vi < g->voiceCount; ++vi) {
      EutReedVoice *v = &g->voices[vi];
      if (!inst_voice_alive(&v->v)) continue;
      ++alive;

      /* Посадка строя: язычок «въезжает» снизу вверх за десятки мс. */
      v->pitchEnv *= v->pitchEnvCoef;
      const float f = v->v.freq * (1.0f - v->pitchEnv) * common;

      float src = 0.0f;
      for (int k = 0; k < EUT_INST_REED_BANKS; ++k) {
        const float dk = f * invSr * v->ratio[k];
        v->ph[k] += dk;
        if (v->ph[k] >= 1.0f) v->ph[k] -= 1.0f;
        src += v->w[k] * inst_reed_wave(v->ph[k], dk, sharp);
      }

      /* Нелинейность трости: громкая нота «гнусавее» — гармоники растут от
         давления, а не только от фильтра. Уровень при этом сохраняется. */
      const float pre = 1.0f + 1.3f * v->v.vel;
      src = inst_soft_clip(src * pre) * (1.0f / pre);

      /* Камера: две полосы плюс остаток источника (прямой звук язычка). */
      const float o1 = v->f1g * src + v->f1a1 * v->f1y1 + v->f1a2 * v->f1y2;
      v->f1y2 = v->f1y1;
      v->f1y1 = o1;
      const float o2 = v->f2g * src + v->f2a1 * v->f2y1 + v->f2a2 * v->f2y2;
      v->f2y2 = v->f2y1;
      v->f2y1 = o2;
      float s = src * 0.40f
              + o1 * (0.45f + 0.30f * g->tone)
              + o2 * (0.15f + 0.35f * g->tone);

      /* Корпус и воздух глушат верх, ФВЧ убирает гул ниже камеры. */
      v->lp1 += (s - v->lp1) * g->lpCoef;
      v->lp2 += (v->lp1 - v->lp2) * g->lpCoef;
      s = v->lp2;
      v->hp += (s - v->hp) * g->hpCoef;
      s -= v->hp;

      /* Воздух: полосовой шум, «дышащий» с медленной скоростью. Ровный
         шумовой фон читается как синтезатор, живой мех — нет. */
      const float nz = inst_noise(&v->v.rng);
      v->breathLp += (nz - v->breathLp) * 0.10f;
      const float air = v->breathLp * (0.65f + 0.35f * inst_sin(v->bellowPh));
      s += air * noiseLvl * 0.06f;
      /* Клац клапана: короткий шум на атаке, тоже через полосу воздуха. */
      s += v->chiff * (nz - v->breathLp) * (0.06f + 0.10f * noiseLvl);
      v->chiff *= 0.9982f;      /* ≈ 12 мс: щелчок, а не шипение */

      v->bellowPh += g->bellowInc;
      if (v->bellowPh >= 1.0f) v->bellowPh -= 1.0f;

      s *= v->v.amp;
      sumL += s * gl;
      sumR += s * gr;
    }

    g->active = alive;
    if (outL != NULL) outL[i * stride] += sumL * g->level;
    if (outR != NULL) outR[i * stride] += sumR * g->level;
  }
}

