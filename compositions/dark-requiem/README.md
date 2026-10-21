# A Requiem for the Hollow Crown — dark-fantasy CLI test piece

A 42-second dark-fantasy miniature in D minor, written for the **CLI only**.
There is no generator script and no `libs/compose`: every node, connection,
parameter, automation point, score import, render, inspection and delivery
step is a command from `docs/cli.md`. It is the end-to-end proof that the CLI
can carry a real piece from an empty directory to a finished master.

## What it exercises

| stage | commands | what it proves |
|---|---|---|
| project and graph | `init`, `node add --id`, `connect` | a custom 14-node graph (6 voices, delay, mixer) can be built without a GUI |
| voices | `param set` | parameter validation and ranges are enforced while editing |
| score | `notation check`, `notation import` | six text scores become tracks/clips; track order matches note-node order |
| structure | `graph check`, `project validate --strict` | ports, connections, compilation, references, duplicates and ranges |
| automation | `automation add` | three lanes (mix, choir, bell) make the piece breathe |
| change control | `project diff --exit-code` | automation is visible as differences, and the exit code is a CI gate |
| sound | `render`, `analyze --html` | 24-bit offline render; inspector verdict and a standalone HTML report |
| iteration | `watch --once` | the edit → listen loop without repeating commands |
| gate | `ci check` | validate → graph → render → analyze as one command |
| delivery | `master --format flac` | 24-bit FLAC master with metadata and a manifest |
| reproducibility | `script record`, `script plan --build` | the build is recorded as data; a rebuild plan needs no file writes |

## Build

```bash
./build.sh                 # uses ../../build/euterpia
./build.sh /path/to/euterpia
```

Artefacts go to `build/` (ignored by git): `requiem.eproj`, `requiem.wav`,
`delivery/requiem.flac`, `delivery/requiem.manifest.json`, `report.html`,
`preview.wav` and the recorded `requiem.eus`.

## The piece

12 bars of 4/4 at 72 BPM (~40 s plus a 2 s tail).

| section | bars | material |
|---|---|---|
| I. Procession | 1–4 | low strings drone, choir fifths, distant bell, no timpani |
| II. Lament | 5–8 | harp arpeggios (Dm–B♭–Gm–A), flute enters with a descending line |
| III. Hollow Crown | 9–12 | full ensemble, timpani heartbeat, choir swells, bell marks the cadence |

The "crypt" delay on the harp is a send to a separate echo mixed back into the
master, which is why the graph has 14 audio inputs rather than 8. The piece is
intentionally quiet at the start and opens up at bar 9 through automation, not
through a second project.

Scores are plain text (`score/*.notes`), so the melody can be diffed and
reviewed like code.
