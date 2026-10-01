/* eut_osc.c — осцилляторы с подавлением алиасинга (polyBLEP).
 *
 * Наивная пила/меандр на 44.1 кГц даёт алиасынг, который превращается
 * в «песочный шум» после любого нелинейного блока. polyBLEP убирает
 * самый громкий паразитный гармонический сгиб разрыва, оставляя
 * синус чистым по определению.
 */

#include "eut_dsp.h"
#include <math.h>

#define EUT_OSC_MIN_FREQ 0.01f
#define EUT_OSC_MAX_HARM 0.45f   /* верхняя граница инкремента фазы */

/* Полиномиальное приближение разрыва (2 points, 1 polynomial):
   корректирует ступеньку в момент перехода фазы через 0. */
static inline float poly_blep(float t, float dt)
{
  if (t < dt) {
    t /= dt;
    return t + t - t * t - 1.0f;
  } else if (t > 1.0f - dt) {
    t = (t - 1.0f) / dt;
    return t * t + t + t + 1.0f;
  }
  return 0.0f;
}

void eut_osc_init(EutOscState *st, float sampleRate, float freq)
{
  if (st == NULL) return;
  st->phase = 0.0f;
  st->pulseWidth = 0.5f;
  /* Правый канал стартует со сдвигом в полпериода: иначе расстройка
     в центах звучит как «плавание» громкости, а не как расстройка. */
  st->phaseR = 0.5f;
  eut_osc_set_freq(st, sampleRate, freq);
}

void eut_osc_set_freq(EutOscState *st, float sampleRate, float freq)
{
  if (st == NULL) return;
  if (sampleRate < 100.0f) sampleRate = 100.0f;
  freq = eut_clampf(freq, EUT_OSC_MIN_FREQ, sampleRate * 0.45f);

  const float inc = freq / sampleRate;
  st->inc = eut_clampf(inc, 0.0f, EUT_OSC_MAX_HARM);
}

void eut_osc_set_pulse_width(EutOscState *st, float width)
{
  if (st == NULL) return;
  st->pulseWidth = eut_clampf(width, 0.05f, 0.95f);
}

void eut_osc_reset(EutOscState *st)
{
  if (st == NULL) return;
  st->phase = 0.0f;
  st->phaseR = 0.5f;
}

/* Один сэмпл осциллятора; фаза продвигается внутри. */
static inline float osc_sample(EutOscState *st, int kind, float inc)
{
  const float phase = st->phase;
  float v;

  switch (kind) {
    case EUT_OSC_SAW: {
      v = 2.0f * phase - 1.0f;
      v -= poly_blep(phase, inc);
      break;
    }
    case EUT_OSC_SQUARE: {
      const float pw = st->pulseWidth;
      v = (phase < pw) ? 1.0f : -1.0f;
      v += poly_blep(phase, inc);
      {
        float t2 = phase + (1.0f - pw);
        if (t2 >= 1.0f) t2 -= 1.0f;
        v -= poly_blep(t2, inc);
      }
      break;
    }
    case EUT_OSC_TRIANGLE: {
      /* Треугольник — единственная форма, которую мы НЕ делаем
         band-limited: polyBLEP корректирует разрыв, а у треугольника
         разрывов нет (есть изломы, но они уже сглажены).
         Частотная точность при этом точная, лишние гармоники -18 dB/окт.
         Если понадобится идеально чистый треугольник — это отдельная
         задача (интегратор с BLEP по производной), а не «магическая»
         строчка в process(). */
      const float d = phase - 0.5f;
      v = 4.0f * ((d < 0.0f) ? -d : d) - 1.0f;
      break;
    }
    case EUT_OSC_SINE:
    default:
      v = sinf(EUT_TWO_PI_F * phase);
      break;
  }

  float next = phase + inc;
  if (next >= 1.0f) next -= 1.0f;
  st->phase = next;

  return v;
}

void eut_osc_render(EutOscState *st, int kind, float *out, int n, float gain)
{
  if (st == NULL || out == NULL || n <= 0) return;

  const float inc = st->inc;
  for (int i = 0; i < n; ++i) {
    out[i] = osc_sample(st, kind, inc) * gain;
  }
}

void eut_osc_render_stereo(EutOscState *st, int kind,
                           float *outL, float *outR, int n,
                           float gain, float detuneCents)
{
  if (st == NULL || outL == NULL || outR == NULL || n <= 0) return;

  const float ratio = powf(2.0f, detuneCents * (1.0f / 1200.0f));
  const float incL = st->inc;
  const float incR = eut_clampf(st->inc * ratio, 0.0f, EUT_OSC_MAX_HARM);

  for (int i = 0; i < n; ++i) {
    outL[i] = osc_sample(st, kind, incL) * gain;
  }

  /* Правый канал хранит СВОЮ фазу в st->phaseR: пересоздавать её из phase0
     каждый блок нельзя. При incR != incL фаза к концу блока уходит на
     n*incR, а перезапуск от phase0 + 0.5 даёт на каждой границе скачок
     n*(incR - incL), который накапливается — расстройка «уезжает» от
     заданной и при малых центах пропадает совсем. */
  EutOscState tmp = *st;
  tmp.phase = st->phaseR;
  for (int i = 0; i < n; ++i) {
    outR[i] = osc_sample(&tmp, kind, incR) * gain;
  }
  st->phaseR = tmp.phase;
}
