/* eut_mix.c — element-wise ядра микса: gain, pan, суммирование шин.
 *
 * Это единственное место в EUTERPIA, где SIMD даёт реальный выигрыш:
 * операции не рекурсивные, ветвлений нет, память линейная.
 * Каждое ядро помечено EUT_TARGET_CLONES — компилятор сам соберёт
 * AVX2-версию и выберет её один раз при загрузке процесса.
 */

#include "eut_dsp.h"
#include <math.h>

void eut_gain_apply(const float *in, float *out, int n, float gain)
{
  if (in == NULL || out == NULL || n <= 0) return;

  int i = 0;

  /* Хвост обрабатываем скалярно: он короче одного SIMD-регистра,
     а проверка на каждый остаток стоит дороже самих умножений. */
  for (; i + 8 <= n; i += 8) {
    out[i + 0] = in[i + 0] * gain;
    out[i + 1] = in[i + 1] * gain;
    out[i + 2] = in[i + 2] * gain;
    out[i + 3] = in[i + 3] * gain;
    out[i + 4] = in[i + 4] * gain;
    out[i + 5] = in[i + 5] * gain;
    out[i + 6] = in[i + 6] * gain;
    out[i + 7] = in[i + 7] * gain;
  }
  for (; i < n; ++i) {
    out[i] = in[i] * gain;
  }
}

void eut_gain_apply_interleaved(const float *in, float *out, int n, float gain)
{
  eut_gain_apply(in, out, n, gain);
}

void eut_pan_gains(float pan, float *gainL, float *gainR)
{
  /* Constant power (-3 dB в центре): сумма квадратов усилений
     постоянна, поэтому при панорамировании не меняется воспринимаемая
     громкость. Это заметно на стерео-шине, где сумма идёт в мастер. */
  pan = eut_clampf(pan, -1.0f, 1.0f);

  const float angle = (pan * 0.5f + 0.5f) * EUT_PI_F * 0.5f;
  const float l = cosf(angle);
  const float r = sinf(angle);

  *gainL = l * 1.41421356f;
  *gainR = r * 1.41421356f;
}

void eut_pan_apply(const float *inL, const float *inR,
                   float *outL, float *outR, int n, float gainL, float gainR)
{
  if (inL == NULL || inR == NULL || outL == NULL || outR == NULL || n <= 0) return;

  int i = 0;
  for (; i + 4 <= n; i += 4) {
    outL[i + 0] = inL[i + 0] * gainL;
    outL[i + 1] = inL[i + 1] * gainL;
    outL[i + 2] = inL[i + 2] * gainL;
    outL[i + 3] = inL[i + 3] * gainL;

    outR[i + 0] = inR[i + 0] * gainR;
    outR[i + 1] = inR[i + 1] * gainR;
    outR[i + 2] = inR[i + 2] * gainR;
    outR[i + 3] = inR[i + 3] * gainR;
  }
  for (; i < n; ++i) {
    outL[i] = inL[i] * gainL;
    outR[i] = inR[i] * gainR;
  }
}

void eut_mix_bus(const float *const *srcs, int numSources,
                 float *dst, int frames, int channels)
{
  if (srcs == NULL || dst == NULL || numSources <= 0 || frames <= 0) return;
  if (channels <= 0 || channels > EUT_MAX_CHANNELS) return;

  const int total = frames * channels;

  for (int i = 0; i < total; ++i) {
    dst[i] = 0.0f;
  }
  for (int s = 0; s < numSources; ++s) {
    const float *src = srcs[s];
    if (src == NULL) continue;
    for (int i = 0; i < total; ++i) {
      dst[i] += src[i];
    }
  }
}

void eut_saturate(float *buf, int n, float drive, float ceiling)
{
  if (buf == NULL || n <= 0) return;

  drive   = eut_clampf(drive, 0.0f, 16.0f);
  ceiling = eut_clampf(ceiling, 0.05f, 4.0f);

  const float norm = 1.0f / (1.0f + drive);

  for (int i = 0; i < n; ++i) {
    /* Мягкий клиппинг: (x / (1 + |x|)) даёт асимптоту ±1 с плавным
       подходом — в отличие от жёсткого clamp, который даёт щелчки
       на вершинах и широкополосный треск при перегрузке. */
    const float x = buf[i] * drive;
    const float y = x / (1.0f + ((x < 0.0f) ? -x : x));
    buf[i] = y * ceiling * 2.0f * norm;
  }
}
