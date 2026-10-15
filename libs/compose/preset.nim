# libs/compose/preset.nim
#
# Пресеты инструментов (issue #COMPOSE-021).
#
# Зачем: `song.play(..., nodeType = "euterpia.bell")` + десяток `setParam`
# техничны и повторяются из пьесы в пьесу. Пресет — именованный характер
# (`"dark_bell"`, `"bright_bass"`, `"trap_drums"`), который разворачивается в
# тип ноды + параметры. Параметры — только те, что реально есть у ноды: сверка
# идёт тем же `validate(arr)`, что и для ручных `setParam` (#311).
#
# Композиция остаётся композицией: пресет меняет ТЕМБР, а не ноты.

import compose/pattern
  # Pattern — пресет размещается паттерном.
import compose/melody
  # Melody — и мелодией тоже.
import compose/arrangement
  # Piece/ensureVoice/play — пресет ставится голосу пьесы.

{.push raises: [].}

type
  Preset* = object
    ## Именованный характер инструмента: тип ноды и параметры.
    name*: string
    nodeType*: string
    params*: seq[tuple[name: string; value: float32]]

proc preset*(name: string): Preset =
  ## Пресет по имени. Неизвестное имя — честный fallback: осциллятор с
  ## мягким уровнем (композиция не падает из-за опечатки, но тембр будет
  ## базовым); список имён — `presetNames()`.
  case name
  of "dark_bell":
    Preset(name: name, nodeType: "euterpia.bell",
           params: @[("decay", 9.0f32), ("tone", 0.3f32), ("level", -9.0f32)])
  of "bright_bell":
    Preset(name: name, nodeType: "euterpia.bell",
           params: @[("decay", 3.0f32), ("tone", 0.8f32), ("level", -9.0f32)])
  of "warm_pad":
    Preset(name: name, nodeType: "euterpia.strings",
           params: @[("tone", 0.35f32), ("ensemble", 14.0f32),
                     ("vibrato", 8.0f32), ("level", -12.0f32)])
  of "bright_pad":
    Preset(name: name, nodeType: "euterpia.strings",
           params: @[("tone", 0.7f32), ("ensemble", 9.0f32),
                     ("level", -12.0f32)])
  of "sub_bass":
    Preset(name: name, nodeType: "euterpia.organ",
           params: @[("bars", 0.0f32), ("tone", 0.2f32),
                     ("click", 0.15f32), ("level", -6.0f32)])
  of "dark_bass":
    Preset(name: name, nodeType: "euterpia.organ",
           params: @[("bars", 0.2f32), ("tone", 0.3f32),
                     ("click", 0.6f32), ("level", -7.0f32)])
  of "bright_bass":
    Preset(name: name, nodeType: "euterpia.organ",
           params: @[("bars", 0.75f32), ("tone", 0.8f32),
                     ("click", 0.4f32), ("level", -8.0f32)])
  of "lofi_piano":
    Preset(name: name, nodeType: "euterpia.piano",
           params: @[("tone", 0.3f32), ("decay", 0.9f32),
                     ("hammer", 0.65f32), ("detune", 9.0f32),
                     ("level", -9.0f32)])
  of "clean_piano":
    Preset(name: name, nodeType: "euterpia.piano",
           params: @[("tone", 0.6f32), ("decay", 1.1f32), ("level", -8.0f32)])
  of "trap_drums":
    Preset(name: name, nodeType: "euterpia.drums",
           params: @[("drive", 0.35f32), ("snappy", 1.2f32),
                     ("level", -6.0f32)])
  of "boom_bap_drums":
    Preset(name: name, nodeType: "euterpia.drums",
           params: @[("drive", 0.15f32), ("snappy", 0.9f32),
                     ("tone", 0.4f32), ("level", -6.0f32)])
  of "choir_aah":
    Preset(name: name, nodeType: "euterpia.choir",
           params: @[("vowel", 0.0f32), ("tone", 0.45f32),
                     ("level", -11.0f32)])
  of "harp_soft":
    Preset(name: name, nodeType: "euterpia.harp",
           params: @[("tone", 0.5f32), ("damping", 0.8f32),
                     ("pluck", 0.3f32), ("level", -10.0f32)])
  of "pluck_lead":
    Preset(name: name, nodeType: "euterpia.harp",
           params: @[("tone", 0.7f32), ("damping", 0.5f32),
                     ("pluck", 0.6f32), ("body", 0.3f32),
                     ("level", -10.0f32)])
  else:
    Preset(name: name, nodeType: "euterpia.osc",
           params: @[("level", -9.0f32)])

proc presetNames*(): seq[string] =
  ## Все известные пресеты (для подсказок и тестов).
  @["bright_bass", "bright_bell", "bright_pad", "boom_bap_drums", "choir_aah",
    "clean_piano", "dark_bass", "dark_bell", "harp_soft", "lofi_piano",
    "pluck_lead", "sub_bass", "trap_drums", "warm_pad"]

proc hasPreset*(name: string): bool =
  ## Есть ли пресет с таким именем (иначе `preset` даст fallback).
  name in presetNames()

proc applyPreset*(c: var Piece; trackName, presetName: string): var Piece
    {.discardable.} =
  ## Поставить голосу `trackName` тип ноды и параметры пресета (голос
  ## создаётся, если его ещё нет).
  let p = preset(presetName)
  let i = c.ensureVoice(trackName, p.nodeType)
  c.voices[i].nodeType = p.nodeType
  for kv in p.params:
    c.voices[i].params.add kv
  c

proc playPreset*(c: var Piece; trackName, presetName: string; p: Pattern;
                 role: TrackRole = roleCustom): var Piece {.discardable.} =
  ## Пресет + размещение паттерна одной строкой:
  ## `song.playPreset("bass", "sub_bass", bassLine(bsRoot), roleBass).during("verse")`.
  discard c.applyPreset(trackName, presetName)
  c.play(trackName, p, role)

proc playPreset*(c: var Piece; trackName, presetName: string; m: Melody;
                 role: TrackRole = roleCustom): var Piece {.discardable.} =
  ## То же для мелодии (высоты считаются поверх гармонии пьесы).
  discard c.applyPreset(trackName, presetName)
  c.play(trackName, m, role)

proc `$`*(p: Preset): string =
  ## Читаемый пресет: `dark_bell → euterpia.bell (decay 9, …)`.
  result = p.name & " → " & p.nodeType
  if p.params.len > 0:
    result.add " ("
    for i, kv in p.params:
      if i > 0:
        result.add ", "
      result.add kv.name & " " & $kv.value
    result.add ")"

{.pop.}
