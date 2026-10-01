/* eut_abi.c — размеры структур состояния для ABI-проверки из Nim.
 * Само DSP здесь нет: это чистая проверка контракта. */

#include "eut_dsp.h"

int eut_abi_sizeof_biquad(void) { return (int)sizeof(EutBiquadState); }
int eut_abi_sizeof_svf(void)    { return (int)sizeof(EutSvfState); }
int eut_abi_sizeof_osc(void)    { return (int)sizeof(EutOscState); }
int eut_abi_sizeof_noise(void)  { return (int)sizeof(EutNoiseState); }
int eut_abi_sizeof_comp(void)   { return (int)sizeof(EutComp); }
int eut_abi_sizeof_delay(void)  { return (int)sizeof(EutDelay); }
