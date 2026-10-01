/* eut_svf.c — SVF (state variable filter), TPT-формулировка Zavalishin.
 *
 * Даёт 12 dB/окт на обоих полюсах, не ограничен пределом частоты
 * как biquad, и не требует пересчёта при изменении резонанса.
 * Каскад из двух SVF даёт 24 dB — типичная схема «резонансный фильтр».
 */

#include "eut_dsp.h"
#include <math.h>

void eut_svf_design(EutSvfState *st, int kind,
                    float sampleRate, float cutoff, float resonance)
{
  if (st == NULL) return;

  if (sampleRate < 100.0f) sampleRate = 100.0f;
  cutoff    = eut_clampf(cutoff, 10.0f, sampleRate * 0.45f);
  /* resonance = 1/Q. Ниже 0.02 фильтр уходит в самовозбуждение. */
  resonance = eut_clampf(resonance, 0.05f, 4.0f);

  const double g = tan(EUT_PI_F * (double)cutoff / (double)sampleRate);
  const double k = (double)resonance;
  const double a1 = 1.0 / (1.0 + g * (g + k));
  const double a2 = g * a1;
  const double a3 = g * a2;

  st->g  = (float)g;
  st->k  = (float)k;
  st->a1 = (float)a1;
  st->a2 = (float)a2;
  st->a3 = (float)a3;
  /* Состояние НЕ трогаем: design вызывается на каждый блок (коэффициенты
     сглаживаются), а ic1/ic2 — это непрерывная история фильтра. Обнуление
     здесь разрывало импульсную характеристику на границе каждого блока:
     highpass пропускал НЧ, lowpass терял хвост. Сброс — только в
     eut_svf_reset (создание/смена sample rate). */
  (void)kind;   /* тип выбирается в process(), коэффициенты от него не зависят */
}

void eut_svf_reset(EutSvfState *st)
{
  if (st == NULL) return;
  st->ic1 = 0.0f;
  st->ic2 = 0.0f;
}

void eut_svf_process(EutSvfState *st, int kind, const float *in, float *out, int n)
{
  if (st == NULL || in == NULL || out == NULL || n <= 0) return;

  const float a1 = st->a1, a2 = st->a2, a3 = st->a3, k = st->k;
  float ic1eq = st->ic1, ic2eq = st->ic2;

  switch (kind) {
    case EUT_SVF_HIGHPASS:
      for (int i = 0; i < n; ++i) {
        const float v3 = in[i] - ic2eq;
        const float v1 = a1 * ic1eq + a2 * v3;
        const float v2 = ic2eq + a2 * ic1eq + a3 * v3;
        ic1eq = 2.0f * v1 - ic1eq;
        ic2eq = 2.0f * v2 - ic2eq;
        out[i] = in[i] - k * v1 - v2;
      }
      break;

    case EUT_SVF_BANDPASS:
      for (int i = 0; i < n; ++i) {
        const float v3 = in[i] - ic2eq;
        const float v1 = a1 * ic1eq + a2 * v3;
        const float v2 = ic2eq + a2 * ic1eq + a3 * v3;
        ic1eq = 2.0f * v1 - ic1eq;
        ic2eq = 2.0f * v2 - ic2eq;
        out[i] = v1;
      }
      break;

    case EUT_SVF_NOTCH:
      for (int i = 0; i < n; ++i) {
        const float v3 = in[i] - ic2eq;
        const float v1 = a1 * ic1eq + a2 * v3;
        const float v2 = ic2eq + a2 * ic1eq + a3 * v3;
        ic1eq = 2.0f * v1 - ic1eq;
        ic2eq = 2.0f * v2 - ic2eq;
        out[i] = v2 - k * v1;
      }
      break;

    case EUT_SVF_LOWPASS:
    default:
      for (int i = 0; i < n; ++i) {
        const float v3 = in[i] - ic2eq;
        const float v1 = a1 * ic1eq + a2 * v3;
        const float v2 = ic2eq + a2 * ic1eq + a3 * v3;
        ic1eq = 2.0f * v1 - ic1eq;
        ic2eq = 2.0f * v2 - ic2eq;
        out[i] = v2;
      }
      break;
  }

  st->ic1 = eut_flush(ic1eq);
  st->ic2 = eut_flush(ic2eq);
}

float eut_svf_process_one(EutSvfState *st, int kind, float x)
{
  if (st == NULL) return 0.0f;

  const float v3 = x - st->ic2;
  const float v1 = st->a1 * st->ic1 + st->a2 * v3;
  const float v2 = st->ic2 + st->a2 * st->ic1 + st->a3 * v3;

  st->ic1 = eut_flush(2.0f * v1 - st->ic1);
  st->ic2 = eut_flush(2.0f * v2 - st->ic2);

  switch (kind) {
    case EUT_SVF_HIGHPASS: return x - st->k * v1 - v2;
    case EUT_SVF_BANDPASS: return v1;
    case EUT_SVF_NOTCH:    return v2 - st->k * v1;
    default:               return v2;
  }
}
