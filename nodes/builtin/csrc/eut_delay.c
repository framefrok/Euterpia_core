/* eut_delay.c — стерео-задержка с дробным временем и ping-pong.
 *
 * Память под кольцо выделяет хост (Nim) и передаёт сюда: ядро ничего
 * не аллоцирует само (MANIFEST §46).
 *
 * Интерполяция Catmull-Rom даёт ровную модуляцию без «зерна» на низких
 * частотах, где линейная интерполяция слышно как повторяющийся щелчок.
 */

#include "eut_dsp.h"
#include <math.h>

void eut_delay_init(EutDelay *d, float *memory, int capacityFrames)
{
  if (d == NULL) return;

  d->buf      = memory;
  d->capacity = (memory != NULL && capacityFrames > 3) ? capacityFrames : 0;
  d->writePos = 0;

  if (d->buf != NULL && d->capacity > 0) {
    for (int i = 0; i < d->capacity * 2; ++i) {
      d->buf[i] = 0.0f;
    }
  }

  d->delayL = 0.0f;
  d->delayR = 0.0f;
  d->feedback = 0.0f;
  d->mix = 0.0f;
  d->pingPong = 0;
  d->lpStateL = 0.0f;
  d->lpStateR = 0.0f;
}

void eut_delay_reset(EutDelay *d)
{
  if (d == NULL) return;

  d->writePos = 0;
  d->lpStateL = 0.0f;
  d->lpStateR = 0.0f;

  if (d->buf != NULL && d->capacity > 0) {
    for (int i = 0; i < d->capacity * 2; ++i) {
      d->buf[i] = 0.0f;
    }
  }
}

void eut_delay_set(EutDelay *d, float sampleRate,
                   float timeLeftSec, float timeRightSec,
                   float feedback, float mix, int pingPong)
{
  if (d == NULL) return;

  if (sampleRate < 100.0f) sampleRate = 100.0f;

  /* Минимальная задержка — 1 кадр (0 при таком чтении прочитает тот же
     кадр, который вот-вот будет перезаписан), максимальная — cap - 4,
     чтобы интерполяция Catmull-Rom всегда имела 4 точки в кольце. */
  const float maxFrames = (d->capacity > 4) ? (float)(d->capacity - 4) : 1.0f;

  const float framesL = timeLeftSec  * sampleRate;
  const float framesR = timeRightSec * sampleRate;

  d->delayL = eut_clampf(framesL, 1.0f, maxFrames);
  d->delayR = eut_clampf(framesR, 1.0f, maxFrames);

  /* Feedback выше единицы гарантированно самовозбуждает систему,
     поэтому ограничиваем 0.95 — это запас до единицы. */
  d->feedback = eut_clampf(feedback, 0.0f, 0.95f);
  d->mix      = eut_clampf(mix, 0.0f, 1.0f);
  d->pingPong = pingPong ? 1 : 0;
}

/* Чтение из кольца с интерполяцией Catmull-Rom.
   delayFrames — на сколько кадров назад от указателя записи читать. */
static inline float delay_read(const EutDelay *d, float delayFrames, int channel)
{
  const int cap = d->capacity;

  float rp = (float)d->writePos - delayFrames;
  while (rp < 0.0f) rp += (float)cap;
  while (rp >= (float)cap) rp -= (float)cap;

  /* Окрестность вокруг центральной точки i1 = floor(rp): (i1-1, i1, i1+1,
     i1+2). Именно так записан полином: при t = 0 он возвращает y1 = buf[i1].
     Прежний базис (i0, i0+1, i0+2, i0+3) отдавал при t = 0 значение
     buf[i0+1], то есть чтение было сдвинуто ровно на один отсчёт вперёд
     (и «защита минимальной задержки» на самом деле не срабатывала). */
  int i1 = (int)rp;
  const float t = rp - (float)i1;

  int i0 = i1 - 1; if (i0 < 0) i0 += cap;
  int i2 = i1 + 1; if (i2 >= cap) i2 -= cap;
  int i3 = i2 + 1; if (i3 >= cap) i3 -= cap;

  const float *b = d->buf;
  const float y0 = b[i0 * 2 + channel];
  const float y1 = b[i1 * 2 + channel];
  const float y2 = b[i2 * 2 + channel];
  const float y3 = b[i3 * 2 + channel];

  const float c1 = 0.5f * (y2 - y0);
  const float c2 = y0 - 2.5f * y1 + 2.0f * y2 - 0.5f * y3;
  const float c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);

  return ((c3 * t + c2) * t + c1) * t + y1;
}

void eut_delay_process(EutDelay *d, const float *inL, const float *inR,
                       float *outL, float *outR, int n)
{
  if (d == NULL || d->buf == NULL || d->capacity <= 4) return;
  if (inL == NULL || inR == NULL || outL == NULL || outR == NULL || n <= 0) return;

  const float fb   = d->feedback;
  const float mix  = d->mix;
  const int   ping = d->pingPong;
  /* Линейный dry/wet-баланс (сумма = 1): mix = 0 — сухой проход,
     mix = 1 — строго 100% wet, mix = 0.5 — равные доли. Прежняя формула
     (wetGain = mix*0.5) при mix = 1 оставляла половину сухого сигнала,
     то есть 100% wet был недостижим, а «центр» ручки перекашивал 3:1. */
  const float wetGain = mix;
  const float dryGain = 1.0f - mix;

  float lpL = d->lpStateL;
  float lpR = d->lpStateR;

  for (int i = 0; i < n; ++i) {
    const float dryL = inL[i];
    const float dryR = inR[i];

    const float wetL = delay_read(d, d->delayL, 0);
    const float wetR = delay_read(d, d->delayR, 1);

    /* Feedback с однополюсным сглаживанием: убирает «звон» высоких
       гармоник, который иначе копится с каждым повторением. */
    lpL += 0.35f * (wetL - lpL);
    lpR += 0.35f * (wetR - lpR);

    const float fbL = eut_safety_clip(eut_flush(lpL) * fb);
    const float fbR = eut_safety_clip(eut_flush(lpR) * fb);

    d->buf[d->writePos * 2 + 0] = dryL + ((ping == 1) ? fbR : fbL);
    d->buf[d->writePos * 2 + 1] = dryR + ((ping == 1) ? fbL : fbR);

    outL[i] = dryL * dryGain + wetL * wetGain;
    outR[i] = dryR * dryGain + wetR * wetGain;

    d->writePos++;
    if (d->writePos >= d->capacity) d->writePos = 0;
  }

  d->lpStateL = eut_flush(lpL);
  d->lpStateR = eut_flush(lpR);
}
