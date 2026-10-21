# Quick start: from an empty directory to sound

This page is **executable**. The block below is the only source of truth:
`tools/quickstart.sh` extracts it and runs it in CI (`.github/workflows/ci.yml`),
so the text cannot drift away from the real CLI.

<!-- quickstart:begin -->
```bash
euterpia init quickstart.eproj --preset band
euterpia setlist apply punk-demo quickstart.eproj
euterpia preset param apply piano-bright quickstart.eproj --role lead
euterpia graph check quickstart.eproj
euterpia render quickstart.eproj quickstart.wav --seconds 8
euterpia analyze quickstart.wav --fail-on error
euterpia project validate --strict quickstart.eproj
```
<!-- quickstart:end -->

## What each step does

| step | command | why |
|---|---|---|
| 1 | `init --preset band` | creates a project from a data template (`presets/templates/band.preset.json`): notes nodes, instruments, mixer and a two-bar riff |
| 2 | `setlist apply punk-demo` | replaces the demo riff with the parts and mix of `presets/setlists/punk-demo.setlist.json` |
| 3 | `preset param apply piano-bright` | changes the piano voice by type and role (`--role lead`); the report lists what changed |
| 4 | `graph check` | verifies ports, connections and compilation before spending time on audio |
| 5 | `render` | offline render; no audio device is needed |
| 6 | `analyze` | inspects the WAV for clipping, DC, clicks, dropouts; `--fail-on error` makes defects an exit code 1 |
| 7 | `project validate --strict` | lints references, duplicates, ranges and unused entities |

## Where to go next

- `euterpia --help` and `man euterpia` — the full command surface, generated from one specification;
- `euterpia help --json` — the machine-readable schema used by agents;
- `docs/cli.md` — command reference with examples and JSON fields;
- `euterpia watch quickstart.eproj --out quickstart.wav` — edit and listen without repeating commands;
- `euterpia master quickstart.eproj --format flac --dir delivery` — delivery render with metadata and stems.

Installed packages ship presets under `share/euterpia/presets`; the CLI also
searches `presets/` next to the binary, `EUTERPIA_PRESETS`, and the user
configuration directory. No project file is required to start: the first
command creates one.
