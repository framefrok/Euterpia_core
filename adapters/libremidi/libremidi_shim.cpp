/* adapters/libremidi/libremidi_shim.cpp
 *
 * Реализация C-фасада libremidi (issue #38).
 *
 * Сборка:
 *   g++ -std=c++17 -shared -fPIC -O2 -DEUTERPIA_WITH_LIBREMEDI \
 *       -I<prefix>/include libremidi_shim.cpp -o libeuterpia_libremidi.so
 *
 * Без `EUTERPIA_WITH_LIBREMEDI` (или без заголовков libremidi) собирается
 * заглушка: все функции возвращают «недоступно». Это нужно, чтобы
 * `nimble check`/CI могли собрать фасад на машине без библиотеки, а
 * адаптер честно отдавал `meUnavailable`, а не падал.
 *
 * Версия libremidi зафиксирована в README.md рядом. Обновление библиотеки
 * правит ТОЛЬКО этот файл: Nim-адаптер видит стабильный C ABI.
 */

#include "libremidi_shim.h"

#include <stddef.h>
#include <string.h>

#if defined(EUTERPIA_WITH_LIBREMEDI) && __has_include(<libremidi/libremidi.hpp>)

#include <libremidi/libremidi.hpp>

#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

struct Port {
    bool is_input = false;
    std::unique_ptr<libremidi::midi_in> in;
    std::unique_ptr<libremidi::midi_out> out;
    eut_lrm_ump_cb cb = nullptr;
    void* user = nullptr;
    bool ump_enabled = false;
    std::mutex mutex;
    std::deque<eut_lrm_ump> queue;

    void push(const libremidi::ump& msg, double timestamp) {
        eut_lrm_ump packet{};
        packet.word_count = static_cast<int32_t>(msg.size());
        if (packet.word_count > 4) packet.word_count = 4;
        for (int i = 0; i < packet.word_count; ++i) packet.words[i] = msg[i];
        packet.timestamp = timestamp;
        if (cb) {
            cb(&packet, user);
            return;
        }
        std::lock_guard<std::mutex> lock(mutex);
        if (queue.size() < 4096) queue.push_back(packet);
    }
};

std::vector<std::unique_ptr<Port>>& ports() {
    static std::vector<std::unique_ptr<Port>> value;
    return value;
}

double now_seconds() {
    return static_cast<double>(libremidi::get_current_time_ns()) / 1.0e9;
}

std::unique_ptr<libremidi::observer> g_observer;

extern "C" {

int eut_lrm_init(void) {
    try {
        g_observer = std::make_unique<libremidi::observer>();
        return 0;
    } catch (...) {
        return -1;
    }
}

void eut_lrm_shutdown(void) {
    ports().clear();
    g_observer.reset();
}

int eut_lrm_port_count(int dir) {
    if (!g_observer) return -1;
    const auto& list = dir == 0 ? g_observer->get_input_ports()
                                : g_observer->get_output_ports();
    return static_cast<int>(list.size());
}

int eut_lrm_port_name(int dir, int index, char* buf, int len) {
    if (!g_observer || !buf || len <= 0) return -1;
    const auto& list = dir == 0 ? g_observer->get_input_ports()
                                : g_observer->get_output_ports();
    if (index < 0 || index >= static_cast<int>(list.size())) return -1;
    const auto& info = list[static_cast<size_t>(index)];
    const std::string name =
        info.display_name.empty() ? info.port_name : info.display_name;
    const int written = static_cast<int>(name.size());
    const int copy = written < len - 1 ? written : len - 1;
    memcpy(buf, name.data(), static_cast<size_t>(copy));
    buf[copy] = '\0';
    return written;
}

void* eut_lrm_open(int dir, int index) {
    if (!g_observer) return nullptr;
    try {
        auto port = std::make_unique<Port>();
        port->is_input = dir == 0;
        if (port->is_input) {
            libremidi::input_configuration conf;
            conf.on_message = [raw = port.get()](const libremidi::ump& msg) {
                raw->push(msg, now_seconds());
            };
            port->in = std::make_unique<libremidi::midi_in>(conf);
            port->in->open_port(index);
        } else {
            port->out = std::make_unique<libremidi::midi_out>();
            port->out->open_port(index);
        }
        ports().push_back(std::move(port));
        return ports().back().get();
    } catch (...) {
        return nullptr;
    }
}

void eut_lrm_close(void* raw) {
    if (!raw) return;
    auto& list = ports();
    for (auto it = list.begin(); it != list.end(); ++it) {
        if (it->get() == raw) {
            list.erase(it);
            return;
        }
    }
}

int eut_lrm_send_midi1(void* raw, const uint8_t* data, int len) {
    auto* port = static_cast<Port*>(raw);
    if (!port || !port->out || !data || len <= 0) return -1;
    try {
        port->out->send_message(data, len);
        return 0;
    } catch (...) {
        return -1;
    }
}

int eut_lrm_send_ump(void* raw, const uint32_t* words, int count) {
    auto* port = static_cast<Port*>(raw);
    if (!port || !port->out || !words || count <= 0 || count > 4) return -1;
    try {
        libremidi::ump packet;
        for (int i = 0; i < count; ++i) packet.push_back(words[i]);
        port->out->send_ump(packet);
        return 0;
    } catch (...) {
        return -1;
    }
}

int eut_lrm_set_callback(void* raw, eut_lrm_ump_cb cb, void* user) {
    auto* port = static_cast<Port*>(raw);
    if (!port) return -1;
    std::lock_guard<std::mutex> lock(port->mutex);
    port->cb = cb;
    port->user = user;
    return 0;
}

int eut_lrm_poll(void* raw, eut_lrm_ump* out, int max_count) {
    auto* port = static_cast<Port*>(raw);
    if (!port || !out || max_count <= 0) return -1;
    std::lock_guard<std::mutex> lock(port->mutex);
    int count = 0;
    while (count < max_count && !port->queue.empty()) {
        out[count++] = port->queue.front();
        port->queue.pop_front();
    }
    return count;
}

int eut_lrm_enable_ump(void* raw, int enabled) {
    auto* port = static_cast<Port*>(raw);
    if (!port) return -1;
    port->ump_enabled = enabled != 0;
    if (port->out) {
        try {
            port->out->open_ump(enabled != 0);
        } catch (...) {
            return -1;
        }
    }
    return 0;
}

}  // extern "C"

#else  /* без libremidi — честная заглушка */

extern "C" {

int eut_lrm_init(void) { return -1; }
void eut_lrm_shutdown(void) {}
int eut_lrm_port_count(int) { return -1; }
int eut_lrm_port_name(int, int, char* buf, int len) {
    if (buf && len > 0) buf[0] = '\0';
    return -1;
}
void* eut_lrm_open(int, int) { return nullptr; }
void eut_lrm_close(void*) {}
int eut_lrm_send_midi1(void*, const uint8_t*, int) { return -1; }
int eut_lrm_send_ump(void*, const uint32_t*, int) { return -1; }
int eut_lrm_set_callback(void*, eut_lrm_ump_cb, void*) { return -1; }
int eut_lrm_poll(void*, eut_lrm_ump*, int) { return -1; }
int eut_lrm_enable_ump(void*, int) { return -1; }

}  // extern "C"

#endif


}  // namespace
