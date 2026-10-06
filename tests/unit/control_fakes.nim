# tests/unit/control_fakes.nim
#
# Общие подставки для тестов control-слоя (issue #139).
#
# Control-слой не знает типов нод (§54) — описания приходят от хозяина
# документа. Тестам нужен такой хозяин: типы с настоящими по форме параметрами
# (границы, целочисленность, порты), фиксированные часы (чтобы снимок документа
# был детерминированным) и пустой проект.
#
# Модуль НЕ содержит тестов и не подключается в `all_tests` напрямую: его
# импортируют `test_control.nim` и `test_control_history.nim`, чтобы хозяин
# документов в них был один — иначе «один путь исполнения» проверялся бы двумя
# разными подставками.

import std/json

import project
import control/commands
import control/document

const
  TestDocId* = 0x1234ABCD'u32
  FixedStamp* = "2026-01-01T00:00:00"

proc fixedClock*(): string = FixedStamp

proc fakeProvider*(nodeType: string; spec: var NodeTypeSpec): bool =
  ## Хозяин описаний для теста: типы с настоящими по форме параметрами.
  case nodeType
  of "test.gain":
    spec = NodeTypeSpec(id: "test.gain", name: "Gain", audioIn: 1, audioOut: 1)
    spec.params = @[
      ParamSpec(name: "gain", minValue: 0.0f32, maxValue: 2.0f32,
                defaultValue: 1.0f32, step: 0.01f32,
                automatable: true, modulatable: true)
    ]
    true
  of "test.osc":
    spec = NodeTypeSpec(id: "test.osc", name: "Oscillator", audioOut: 1)
    spec.params = @[
      ParamSpec(name: "waveform", minValue: 0.0f32, maxValue: 3.0f32,
                defaultValue: 0.0f32, step: 1.0f32, integerLike: true,
                automatable: true),
      ParamSpec(name: "hiddenOne", minValue: 0.0f32, maxValue: 1.0f32,
                defaultValue: 0.0f32, step: 0.1f32, hidden: true),
      ParamSpec(name: "freq", minValue: 0.01f32, maxValue: 20000.0f32,
                defaultValue: 440.0f32, step: 1.0f32, modulatable: true),
      ParamSpec(name: "level", minValue: -80.0f32, maxValue: 6.0f32,
                defaultValue: -6.0f32, step: 0.1f32),
    ]
    true
  of "test.notes":
    # Нода без аудиопортов: разрыв «всего между нодами» не должен требовать
    # порта, которого у неё нет.
    spec = NodeTypeSpec(id: "test.notes", name: "Notes", eventOut: 1)
    true
  of "test.seq":
    # События в обе стороны — тип, к которому можно подключиться по событиям,
    # не имея аудиопортов.
    spec = NodeTypeSpec(id: "test.seq", name: "Sequencer", eventIn: 1,
                        eventOut: 1)
    true
  else:
    false

proc altProvider*(nodeType: string; spec: var NodeTypeSpec): bool =
  ## Тот же контракт описаний из другого места: типы те же, человеческие имена
  ## свои. Провайдер — единственное, чем различаются хозяева документа.
  if not fakeProvider(nodeType, spec):
    return false
  spec.name = spec.name & " (alt)"
  true

proc emptyProject*(): ProjectFormat =
  ProjectFormat(format: ProjectFormatName, version: ProjectFormatVersion)

proc newDoc*(proj: ProjectFormat = emptyProject();
             types: NodeTypeProvider = fakeProvider): Document =
  ## Документ с фиксированными часами: снимок после сценария не зависит от
  ## времени запуска, и его можно сравнивать с тем, что сделал CLI.
  var doc: Document
  initDocument(doc, proj, TestDocId, types, fixedClock)
  doc

proc snapshot*(doc: Document): string =
  ## Снимок документа для сравнения «до/после»: тем же кодом пишется файл.
  $toJson(doc.proj)

proc snapshotWithoutStamp*(doc: Document): string =
  ## Снимок без отметки времени: отмена и повтор её переставляют, а всё
  ## остальное обязано совпасть побайтово.
  var copy = doc
  copy.proj.metadata.modified = ""
  snapshot(copy)

proc strippedSnapshot*(doc: Document): string =
  ## Снимок без имён нод: хозяева различаются именно именами, а сравнивать надо
  ## структуру и значения.
  var copy = doc
  for node in copy.proj.graph.nodes.mitems:
    node.name = "?"
  snapshot(copy)

proc runScenario*(doc: var Document) =
  ## Один и тот же сценарий для документов с разными хозяевами: две ноды,
  ## связь, значение параметра и удаление. Возвращает документ к одной и той же
  ## структуре — на этом и держится проверка «одна команда — один документ».
  discard doc.applyCommand(createNode("test.gain"))
  discard doc.applyCommand(createNode("test.gain"))
  discard doc.applyCommand(connect(port(1, cpkAudio, 0), port(2, cpkAudio, 0)))
  discard doc.applyCommand(setParameter(2, 220.0f32, "freq"))
  discard doc.applyCommand(deleteNode(1))
