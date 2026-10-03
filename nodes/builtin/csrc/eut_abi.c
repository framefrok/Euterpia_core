/* eut_abi.c — размеры структур состояния для ABI-проверки из Nim.
 * Само DSP здесь нет: это чистая проверка контракта. */

#include "eut_dsp.h"

int eut_abi_sizeof_biquad(void) { return (int)sizeof(EutBiquadState); }
int eut_abi_sizeof_svf(void)    { return (int)sizeof(EutSvfState); }
int eut_abi_sizeof_osc(void)    { return (int)sizeof(EutOscState); }
int eut_abi_sizeof_noise(void)  { return (int)sizeof(EutNoiseState); }
int eut_abi_sizeof_comp(void)   { return (int)sizeof(EutComp); }
int eut_abi_sizeof_delay(void)  { return (int)sizeof(EutDelay); }
int eut_abi_sizeof_inst_voice(void)   { return (int)sizeof(EutInstVoice); }
int eut_abi_sizeof_organ_voice(void)  { return (int)sizeof(EutOrganVoice); }
int eut_abi_sizeof_organ(void)        { return (int)sizeof(EutOrgan); }
int eut_abi_sizeof_piano_voice(void)  { return (int)sizeof(EutPianoVoice); }
int eut_abi_sizeof_piano(void)        { return (int)sizeof(EutPiano); }
int eut_abi_sizeof_guitar_voice(void) { return (int)sizeof(EutGuitarVoice); }
int eut_abi_sizeof_guitar(void)       { return (int)sizeof(EutGuitar); }
int eut_abi_sizeof_drum_voice(void)   { return (int)sizeof(EutDrumVoice); }
int eut_abi_sizeof_drums(void)        { return (int)sizeof(EutDrums); }

