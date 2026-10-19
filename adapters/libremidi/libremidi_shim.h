/* adapters/libremidi/libremidi_shim.h
 *
 * Тонкий C-фасад libremidi (issue #38).
 *
 * Зачем фасад:
 *   libremidi — C++-библиотека с шаблонами и исключениями. Nim-адаптер
 *   (`midi_backend_libremidi.nim`) грузит ЭТУ разделяемую библиотеку через
 *   dynlib и работает только с POD-структурами. Никакие C++-типы наружу
 *   не выходят, ABI стабилен и версионируется вместе с этим заголовком.
 *
 * Направления: 0 — вход (Core читает), 1 — выход (Core пишет).
 * Коды возврата: 0 — успех, <0 — ошибка.
 *
 * UMP-пакет передаётся как 4 слова по 32 бита: слово 0 — старшее
 * (network order внутри UMP, но здесь просто порядок массива).
 */

#ifndef EUTERPIA_LIBREMIDI_SHIM_H
#define EUTERPIA_LIBREMIDI_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct eut_lrm_ump {
    uint32_t words[4];
    int32_t word_count;
    int32_t reserved;   /* выравнивание: timestamp должен быть на 8 */
    double timestamp;   /* секунды от открытия порта */
} eut_lrm_ump;

typedef void (*eut_lrm_ump_cb)(const eut_lrm_ump* msg, void* user);

int eut_lrm_init(void);
void eut_lrm_shutdown(void);

int eut_lrm_port_count(int dir);
int eut_lrm_port_name(int dir, int index, char* buf, int len);

void* eut_lrm_open(int dir, int index);
void eut_lrm_close(void* port);

int eut_lrm_send_midi1(void* port, const uint8_t* data, int len);
int eut_lrm_send_ump(void* port, const uint32_t* words, int count);

int eut_lrm_set_callback(void* port, eut_lrm_ump_cb cb, void* user);
int eut_lrm_poll(void* port, eut_lrm_ump* out, int max_count);
int eut_lrm_enable_ump(void* port, int enabled);

#ifdef __cplusplus
}
#endif

#endif
