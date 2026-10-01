# EUTERPIA

EUTERPIA DAW core assembled from the source provided in the conversation.

## Layout

- `core/` — EUTERPIA engine/kernel modules
- `tests/integration_test.nim` — supplied full integration test

## Core modules

`signal_types`, `node_interface`, `ipc_bus`, `graph_compiler`, `core_nodes`, `dsp_nodes`, `audio_engine`, `audio_backend`, `eut_plugin`, `transport`, `sequencer`, `project`, `memory_pool`, `undo_redo`, `audio_file_io`, `dsp_scheduler`, `midi_io`, `plugin_host`, `audio_recorder`, `waveform_cache`, `metronome`, `mixer_console`.

The code is packaged as supplied; no DSP/engine fixes were silently applied.
# Euterpia_core
