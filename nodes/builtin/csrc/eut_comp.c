/* eut_comp.c — feed-forward компрессор: детектор + gain computer.
 *
 * Классическая схема:
 *   детектор (peak/RMS) -> сглаживание attack/release -> gain computer
 *   (порог, knee, ratio) -> makeup -> кривая gain на весь блок.
 *
 * Кривая считается ОТДЕЛЬНО от применения намеренно: это позволяет
 * хосту реализовать stereo link (детектор по максимуму каналов),
 * look-ahead и side-chain, не трогая это ядро.
 */

#include "eut_dsp.h"
#include <math.h>
#include <string.h>

void eut_comp_init(EutComp *c, int channels, int detector, float sampleRate)
{
  if (c == NULL) return;

  memset(c, 0, sizeof(*c));
  c->channels  = (channels < 1) ? 1
               : ((channels > EUT_MAX_CHANNELS) ? EUT_MAX_CHANNELS : channels);
  c->detector  = (detector == EUT_COMP_RMS) ? EUT_COMP_RMS : EUT_COMP_PEAK;
  c->sampleRate = (sampleRate < 100.0f) ? 100.0f : sampleRate;

  eut_comp_set_params(c, -12.0f, 4.0f, 6.0f, 0.01f, 0.10f, 0.0f);
  eut_comp_reset(c);
}

void eut_comp_set_params(EutComp *c, float thresholdDb, float ratio,
                         float kneeDb, float attackSec, float releaseSec,
                         float makeupDb)
{
  if (c == NULL) return;

  c->thresholdDb  = eut_clampf(thresholdDb, -60.0f, 0.0f);
  c->slope        = 1.0f / eut_clampf(ratio, 1.0f, 20.0f);
  c->kneeDb       = eut_clampf(kneeDb, 0.0f, 24.0f);
  c->makeupLin    = eut_db_to_lin(eut_clampf(makeupDb, -24.0f, 24.0f));

  attackSec  = eut_clampf(attackSec, 0.0001f, 2.0f);
  releaseSec = eut_clampf(releaseSec, 0.0001f, 4.0f);

  /* One-pole: coeff = exp(-1 / (time * sr)). */
  c->attackCoef  = (float)__builtin_expf(-1.0f / (attackSec  * c->sampleRate));
  c->releaseCoef = (float)__builtin_expf(-1.0f / (releaseSec * c->sampleRate));
  /* RMS-детектор усредняет мощность на фиксированном окне 10 мс. */
  c->avgCoef     = (c->detector == EUT_COMP_RMS)
                     ? (float)__builtin_expf(-1.0f / (0.01f * c->sampleRate))
                     : 0.0f;
}

void eut_comp_reset(EutComp *c)
{
  if (c == NULL) return;
  c->env     = 0.0f;
  c->rmsEnv  = 0.0f;
  c->gainLin = 1.0f;
  c->gainDb  = 0.0f;
  for (int i = 0; i < EUT_COMP_MAX_BLOCK; ++i) {
    c->gainCurve[i] = 1.0f;
  }
}

/* Gain computer: считается в dB, потому что порог, ratio и knee задаются
   в dB, и в линейном домене кривая получается с бессмысленным изломом
   на самом пороге.

   Классическая мягкая колено (Zölzer):
     over <= -knee/2 : gain = 0 dB
     |over| < knee/2 : parabola, стыкуется с 0 dB и с линейной ветвью
     over >=  knee/2 : gain = -(1 - 1/ratio) * over
*/
static inline float comp_gain_from_env(float env, float thrDb, float slope,
                                       float kneeDb, float makeupLin)
{
  if (env <= 1e-9f) return makeupLin;

  const float over = eut_lin_to_db(env) - thrDb;
  const float kneeHalf = kneeDb * 0.5f;
  float grDb;

  if (kneeHalf > 0.0f && over > -kneeHalf && over < kneeHalf) {
    const float t = over + kneeHalf;
    grDb = -(1.0f - slope) * t * t / (2.0f * kneeHalf);
  } else if (over >= kneeHalf) {
    grDb = -(1.0f - slope) * over;
  } else {
    grDb = 0.0f;
  }

  return eut_clampf(eut_db_to_lin(grDb), 0.0f, 1.0f) * makeupLin;
}

void eut_comp_detect(EutComp *c, const float *in, int n)
{
  if (c == NULL || in == NULL || n <= 0) return;
  if (n > EUT_COMP_MAX_BLOCK) n = EUT_COMP_MAX_BLOCK;

  const float attack   = c->attackCoef;
  const float release  = c->releaseCoef;
  const float avg      = c->avgCoef;
  const float thrDb    = c->thresholdDb;
  const float slope    = c->slope;
  const float kneeDb   = c->kneeDb;
  const float makeup   = c->makeupLin;
  const int   isRms    = (c->detector == EUT_COMP_RMS);

  float env    = c->env;
  float rmsEnv = c->rmsEnv;
  float gain   = c->gainLin;
  float gainDb = c->gainDb;

  for (int i = 0; i < n; ++i) {
    float level = in[i];
    if (level < 0.0f) level = -level;

    if (isRms) {
      /* RMS: усредняем МОЩНОСТЬ в отдельном накопителе rmsEnv, а корень
         берём только чтобы получить линейный уровень. Смешивать мощность
         и линейную огибающую в одной переменной нельзя — это величины
         разной размерности, из-за чего детектор сходился не к RMS
         (на постоянном сигнале «недобутывал» почти вдвое). */
      rmsEnv += avg * (level * level - rmsEnv);
      level = sqrtf(rmsEnv);
    }

    /* Огибающая: мгновенный подъём, экспоненциальный спад. */
    const float coef = (level > env) ? attack : release;
    env = coef * env + (1.0f - coef) * level;

    gain = comp_gain_from_env(env, thrDb, slope, kneeDb, makeup);
    /* Метрика GR считается из ФАКТИЧЕСКИ применённого gain (без makeup):
       она согласована с сигналом и учитывает soft knee. Прежняя формула
       (lin_to_db(env) - thrDb) при уровне ниже порога давала отрицательное
       «подавление» там, где подавления нет. makeupLin >= 0.063 (зажат по
       dB), поэтому деление безопасно. */
    gainDb = eut_lin_to_db(gain / makeup);
    if (gainDb > 0.0f) gainDb = 0.0f;

    c->gainCurve[i] = gain;
  }

  c->env     = eut_flush(env);
  c->rmsEnv  = eut_flush(rmsEnv);
  c->gainLin = gain;
  c->gainDb  = gainDb;
}


void eut_comp_apply(const float *gainCurve, const float *in, float *out, int n)
{
  if (gainCurve == NULL || in == NULL || out == NULL || n <= 0) return;

  for (int i = 0; i < n; ++i) {
    out[i] = in[i] * gainCurve[i];
  }
}

float eut_comp_gain_db(const EutComp *c)
{
  if (c == NULL) return 0.0f;
  return c->gainDb;
}

float eut_comp_gain_at(const EutComp *c, int index)
{
  if (c == NULL || index < 0 || index >= EUT_COMP_MAX_BLOCK) return 1.0f;
  return c->gainCurve[index];
}
