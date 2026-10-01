/* eut_noise.c — генераторы шума.
 *
 * xorshift32 вместо rand(): детерминирован, не трогает глобальное
 * состояние libc и не блокирует (в audio thread нельзя использовать
 * функции с внутренней блокировкой).
 */

#include "eut_dsp.h"

static inline uint32_t xorshift32(uint32_t *s)
{
  uint32_t x = *s;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  *s = x;
  return x;
}

static inline float to_unit(uint32_t x)
{
  /* [0,1) из 32 бит, масштабирование точно в [-1, 1). */
  return ((float)(x >> 8) * (1.0f / 8388608.0f)) - 1.0f;
}

void eut_noise_init(EutNoiseState *st, uint32_t seed)
{
  if (st == NULL) return;
  st->rng = (seed == 0u) ? 0x9E3779B9u : seed;
  st->b0 = st->b1 = st->b2 = 0.0f;
  st->b3 = st->b4 = st->b5 = st->b6 = 0.0f;
  st->brown = 0.0f;
}

void eut_noise_render(EutNoiseState *st, int kind, float *out, int n, float gain)
{
  if (st == NULL || out == NULL || n <= 0) return;

  switch (kind) {
    case EUT_NOISE_PINK: {
      /* Paul Kellet economy pink filter: -3 dB/окт, 7 накопленных
         состояний вместо банка фильтров. */
      for (int i = 0; i < n; ++i) {
        const float w = to_unit(xorshift32(&st->rng));
        st->b0 = 0.99886f * st->b0 + w * 0.0555179f;
        st->b1 = 0.99332f * st->b1 + w * 0.0750759f;
        st->b2 = 0.96900f * st->b2 + w * 0.1538520f;
        st->b3 = 0.86650f * st->b3 + w * 0.3104856f;
        st->b4 = 0.55000f * st->b4 + w * 0.5329522f;
        st->b5 = -0.7616f * st->b5 - w * 0.0168980f;
        out[i] = (st->b0 + st->b1 + st->b2 + st->b3 + st->b4 +
                  st->b5 + st->b6 + w * 0.5362f) * 0.11f * gain;
        st->b6 = w * 0.115926f;
      }
      break;
    }
    case EUT_NOISE_BROWN: {
      /* Интегратор с утечкой: -6 dB/окт. Утечка обязательна, иначе
         интегратор уедет в inf за несколько секунд. */
      for (int i = 0; i < n; ++i) {
        const float w = to_unit(xorshift32(&st->rng));
        st->brown = eut_flush(st->brown * 0.9985f + w * 0.05f);
        out[i] = eut_safety_clip(st->brown * 3.5f) * gain;
      }
      break;
    }
    case EUT_NOISE_WHITE:
    default: {
      for (int i = 0; i < n; ++i) {
        out[i] = to_unit(xorshift32(&st->rng)) * gain;
      }
      break;
    }
  }
}
