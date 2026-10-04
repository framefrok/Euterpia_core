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
int eut_abi_sizeof_flute_voice(void)  { return (int)sizeof(EutFluteVoice); }
int eut_abi_sizeof_flute(void)        { return (int)sizeof(EutFlute); }
int eut_abi_sizeof_bagpipe_voice(void){ return (int)sizeof(EutBagpipeVoice); }
int eut_abi_sizeof_bagpipe(void)      { return (int)sizeof(EutBagpipe); }
int eut_abi_sizeof_strings_voice(void){ return (int)sizeof(EutStringsVoice); }
int eut_abi_sizeof_strings(void)      { return (int)sizeof(EutStrings); }
int eut_abi_sizeof_bell_voice(void)   { return (int)sizeof(EutBellVoice); }
int eut_abi_sizeof_bell(void)         { return (int)sizeof(EutBell); }
int eut_abi_sizeof_pluck_voice(void)  { return (int)sizeof(EutPluckVoice); }
int eut_abi_sizeof_pluck(void)        { return (int)sizeof(EutPluck); }
int eut_abi_sizeof_recorder_voice(void){ return (int)sizeof(EutRecorderVoice); }
int eut_abi_sizeof_recorder(void)     { return (int)sizeof(EutRecorder); }
int eut_abi_sizeof_brass_voice(void)  { return (int)sizeof(EutBrassVoice); }
int eut_abi_sizeof_brass(void)        { return (int)sizeof(EutBrass); }
int eut_abi_sizeof_timpani_voice(void){ return (int)sizeof(EutTimpaniVoice); }
int eut_abi_sizeof_timpani(void)      { return (int)sizeof(EutTimpani); }
int eut_abi_sizeof_choir_voice(void)  { return (int)sizeof(EutChoirVoice); }
int eut_abi_sizeof_choir(void)        { return (int)sizeof(EutChoir); }
int eut_abi_sizeof_reed_voice(void)   { return (int)sizeof(EutReedVoice); }
int eut_abi_sizeof_reed(void)         { return (int)sizeof(EutReed); }

