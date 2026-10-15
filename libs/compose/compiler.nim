# libs/compose/compiler.nim
#
# Компилятор композиции (issue #COMPOSE-047).
#
# Зачем: превратить `CompositionIR` в раскладку и проект Core — это
# единственное место, где IR встречается с `song`/`project`. Резолвер
# (`resolve` в `arrangement`) живёт выше и в Core не заглядывает; здесь имена
# дорожек становятся нодами, решённые события — клипами, автоматизация —
# дорожками параметров. Второго секвенсора нет: на выходе те же
# `Arrangement`/`ProjectFormat`, что читает ядро.
#
# Пайплайн: Piece → (`resolve`) → CompositionIR → (`compile`) → Arrangement →
# (`buildProject`) → ProjectFormat → рендер/MIDI/файл (#COMPOSE-046/047).

import project
  # ProjectFormat — результат `compileProject`.
import compose/ir
import compose/song
  # Arrangement/instrument/add/buildProject — формат проекта ядра.

{.push raises: [].}

proc compile*(ir: CompositionIR; sampleRate: float32 = 0.0f32): Arrangement =
  ## IR → `Arrangement`: дорожки (части из решённых событий), инструменты,
  ## mute и автоматизация. Клип каждой дорожки покрывает всю форму, поэтому
  ## абсолютные тики событий совпадают с `build`.
  let sr = if sampleRate > 0.0f32: sampleRate else: ir.sampleRate
  result = arrangement(ir.title, ir.tempo, sr)
  let bars = ir.endBar
  for t in ir.tracks:
    var inst = instrument(t.nodeType, t.name, t.notesName)
    for pv in t.params:
      inst.params.add pv
    result.add(inst, t.partFromEvents(bars, ir.beatsPerBar), mute = t.mute)
  result.automation = ir.automation

proc compileProject*(ir: CompositionIR;
                     sampleRate: float32 = 0.0f32): ProjectFormat =
  ## IR → проект Core одной командой (раскладка собирается внутри).
  buildProject(compile(ir, sampleRate))

proc writeProjectChecked*(ir: CompositionIR; path: string;
                          problems: var seq[string]): bool {.raises: [IOError].} =
  ## Проверка раскладки и запись проекта из IR — тот же контракт, что у
  ## `song.writeProjectChecked`: при ошибках файл не создаётся.
  writeProjectChecked(compile(ir), path, problems)

{.pop.}
