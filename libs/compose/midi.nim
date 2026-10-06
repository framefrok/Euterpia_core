# libs/compose/midi.nim
#
# MIDI для «композиции как код»: раскладка (`compose/song`) → SMF.
#
# Реализация живёт в `libs/midi_export` (там видны и проект Core, и кодек
# Commons). Здесь только удобные обёртки над `Arrangement`, чтобы композиция
# получала MIDI той же командой, что и WAV:
#
#   let rr = arr.render(here / "ensemble.wav")
#   discard arr.writeMidi(here / "ensemble.mid")        # один файл
#   discard arr.writeMidiTracks(here / "midi")          # по файлу на партию

import compose/song
import midi_export

export midi_export

{.push raises: [].}

proc toSmf*(arr: Arrangement): SmfFile =
  ## Раскладка в SMF — через обычный `buildProject`, поэтому MIDI и `.eproj`
  ## описывают ровно одну и ту же музыку (один источник правды).
  midi_export.toSmf(buildProject(arr))

proc writeMidi*(arr: Arrangement; path: string): MidiExportReport
    {.raises: [IOError, OSError].} =
  ## Один MIDI-файл на всю пьесу: дорожка-дирижёр + по дорожке на партию.
  midi_export.writeMidi(buildProject(arr), path)

proc writeMidiTracks*(arr: Arrangement; dir: string): MidiExportReport
    {.raises: [IOError, OSError].} =
  ## По файлу на партию (разбить инструменты на разные MIDI).
  midi_export.writeMidiTracks(buildProject(arr), dir)

{.pop.}
