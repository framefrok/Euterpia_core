/* eut_biquad.c — biquad TDF-II, RBJ Audio EQ Cookbook.
 *
 * Форма Direct Form II Transposed: две переменные состояния на канал,
 * ноль задержек в сигнальном пути, одна умножение + сложение на сэмпл.
 * Фильтры каскадируются внешним узлом, состояние на канал — здесь.
 */

#include "eut_dsp.h"
#include <math.h>

#define EUT_SHELF_SLOPE 0.9f

void eut_biquad_design(EutBiquadState *st, int kind,
                       float sampleRate, float freq, float q, float gainDb)
{
  if (st == NULL) return;

  /* Границы устойчивости. Частота выше 0.45*fs и Q близкий к нулю
     дают коэффициенты вне устойчивой области — там фильтр «взрывается»
     в NaN и портит весь последующий сигнал. */
  if (sampleRate < 100.0f) sampleRate = 100.0f;
  freq = eut_clampf(freq, 10.0f, sampleRate * 0.45f);
  q    = eut_clampf(q, 0.05f, 40.0f);

  const double sr = (double)sampleRate;
  const double f0 = (double)freq;
  const double w0 = 2.0 * EUT_PI_F * f0 / sr;
  const double cw = cos(w0);
  const double sw = sin(w0);
  const double A  = pow(10.0, (double)gainDb / 40.0);

  double b0, b1, b2, a0, a1, a2;

  switch (kind) {
    case EUT_BIQUAD_HIGHPASS: {
      const double alpha = sw / (2.0 * (double)q);
      a0 = 1.0 + alpha; a1 = -2.0 * cw; a2 = 1.0 - alpha;
      b0 = (1.0 + cw) / 2.0; b1 = -(1.0 + cw); b2 = (1.0 + cw) / 2.0;
      break;
    }
    case EUT_BIQUAD_BANDPASS: {
      const double alpha = sw / (2.0 * (double)q);
      a0 = 1.0 + alpha; a1 = -2.0 * cw; a2 = 1.0 - alpha;
      b0 = alpha; b1 = 0.0; b2 = -alpha;
      break;
    }
    case EUT_BIQUAD_NOTCH: {
      const double alpha = sw / (2.0 * (double)q);
      a0 = 1.0 + alpha; a1 = -2.0 * cw; a2 = 1.0 - alpha;
      b0 = 1.0; b1 = -2.0 * cw; b2 = 1.0;
      break;
    }
    case EUT_BIQUAD_PEAK: {
      const double alpha = sw / (2.0 * (double)q);
      a0 = 1.0 + alpha / A; a1 = -2.0 * cw; a2 = 1.0 - alpha / A;
      b0 = 1.0 + alpha * A; b1 = -2.0 * cw; b2 = 1.0 - alpha * A;
      break;
    }
    case EUT_BIQUAD_LOWSHELF: {
      const double alpha = 0.5 * sw *
        sqrt((A + 1.0 / A) * (1.0 / (double)EUT_SHELF_SLOPE - 1.0) + 2.0);
      a0 = (A + 1.0) + (A - 1.0) * cw + sqrt(A) * alpha;
      a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cw);
      a2 = (A + 1.0) + (A - 1.0) * cw - sqrt(A) * alpha;
      b0 =      A * ((A + 1.0) - (A - 1.0) * cw + sqrt(A) * alpha);
      b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cw + sqrt(A) * alpha);
      b2 =      A * ((A + 1.0) - (A - 1.0) * cw - sqrt(A) * alpha);
      break;
    }
    case EUT_BIQUAD_HIGHSHELF: {
      const double alpha = 0.5 * sw *
        sqrt((A + 1.0 / A) * (1.0 / (double)EUT_SHELF_SLOPE - 1.0) + 2.0);
      a0 = (A + 1.0) - (A - 1.0) * cw + sqrt(A) * alpha;
      a1 =  2.0 * ((A - 1.0) - (A + 1.0) * cw);
      a2 = (A + 1.0) - (A - 1.0) * cw - sqrt(A) * alpha;
      b0 =      A * ((A + 1.0) + (A - 1.0) * cw + sqrt(A) * alpha);
      b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cw - sqrt(A) * alpha);
      b2 =      A * ((A + 1.0) + (A - 1.0) * cw - sqrt(A) * alpha);
      break;
    }
    case EUT_BIQUAD_LOWPASS:
    default: {
      const double alpha = sw / (2.0 * (double)q);
      a0 = 1.0 + alpha; a1 = -2.0 * cw; a2 = 1.0 - alpha;
      b0 = (1.0 - cw) / 2.0; b1 = 1.0 - cw; b2 = (1.0 - cw) / 2.0;
      break;
    }
  }

  if (fabs(a0) < 1e-12) a0 = 1e-12;

  const double inv = 1.0 / a0;
  st->b0 = (float)(b0 * inv);
  st->b1 = (float)(b1 * inv);
  st->b2 = (float)(b2 * inv);
  st->a1 = (float)(a1 * inv);
  st->a2 = (float)(a2 * inv);
  st->z1 = 0.0f;
  st->z2 = 0.0f;
}

void eut_biquad_reset(EutBiquadState *st)
{
  if (st == NULL) return;
  st->z1 = 0.0f;
  st->z2 = 0.0f;
}

void eut_biquad_process(EutBiquadState *st, const float *in, float *out, int n)
{
  if (st == NULL || in == NULL || out == NULL || n <= 0) return;

  const float b0 = st->b0, b1 = st->b1, b2 = st->b2;
  const float a1 = st->a1, a2 = st->a2;
  float z1 = st->z1, z2 = st->z2;

  /* Один цикл на оба случая: в TDF-II значение out[i] вычисляется
     из x = in[i] до записи, поэтому in == out (in-place) корректен. */
  for (int i = 0; i < n; ++i) {
    const float x = in[i];
    const float y = b0 * x + z1;
    z1 = b1 * x - a1 * y + z2;
    z2 = b2 * x - a2 * y;
    out[i] = eut_flush(y);
  }

  st->z1 = eut_flush(z1);
  st->z2 = eut_flush(z2);
}

float eut_biquad_process_one(EutBiquadState *st, float x)
{
  if (st == NULL) return 0.0f;

  const float y = st->b0 * x + st->z1;
  st->z1 = st->b1 * x - st->a1 * y + st->z2;
  st->z2 = st->b2 * x - st->a2 * y;

  st->z1 = eut_flush(st->z1);
  st->z2 = eut_flush(st->z2);
  return eut_flush(y);
}
