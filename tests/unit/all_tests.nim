# tests/unit/all_tests.nim
#
# Агрегатор юнит-тестов: `nimble unit`.
#
# Каждый тестовый модуль выполняет свои suite при импорте, поэтому
# достаточно перечислить файлы. Провал где-либо даёт ненулевой код
# выхода процесса — этого достаточно для CI.

# Тесты запускают suite при импорте и не используют символы из
# импортированных модулей — предупреждение ожидаемо и бесполезно.
{.warning[UnusedImport]: off.}

import test_signal_types
import test_transport
import test_native_abi
import test_ring_buffer
import test_midi_api
import test_midi_smf
import test_backend_contract
import test_backend_registry
import test_input_path
import test_plugin_api
import test_clap_host_extensions
import test_clap_plugin_extensions
import test_clap_events
import test_oscillator
import test_biquad
import test_svf
import test_noise
import test_gain
import test_pan
import test_saturate
import test_compressor
import test_delay
import test_graph_compiler
import test_pdc
import test_scheduler_stop
import test_scheduler_pool
import test_rt_guard
import test_engine_retire
import test_realtime_gcsafe
import test_recorder
import test_sequencer
import test_project
import test_param_registry
import test_memory_pool
import test_logger
import test_undo_redo
import test_waveform_cache
import test_audio_file_io
import test_instruments
import test_mix
import test_graph_check
