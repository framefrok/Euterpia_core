# cli/type_registry.nim
#
# Описатели типов нод, которых нет в каталоге builtin (issue #95).
#
# Зачем отдельный модуль: описатель нужен control-слою (`openDocument`)
# и хосту плагинов (`plugin_host`). Держать его в `control_bridge` значило бы,
# что `plugin_host` и `control_bridge` импортируют друг друга циклом.
#
# Регистрация контекстная: тип `plugin:<id>` описывается по самому проекту
# (в нём лежит `pluginPath`). `control_bridge.openDocument` вызывает
# `runContextRegistrar`, а конкретную реализацию ставит `plugin_host` при
# импорте — CLI, которому плагины не нужны, ничего не сканирует.

import std/tables

import project
import control/document

var
  extraTypeSpecs*: Table[string, NodeTypeSpec]
  contextRegistrar*: proc(proj: ProjectFormat) {.nimcall.}
    ## Поднять описатели типов, зависящие от проекта (плагины).

proc registerControlTypeSpec*(spec: NodeTypeSpec) =
  extraTypeSpecs[spec.id] = spec

proc clearControlTypeSpecs*() =
  extraTypeSpecs.clear()

proc lookupControlTypeSpec*(nodeType: string; spec: var NodeTypeSpec): bool =
  if extraTypeSpecs.hasKey(nodeType):
    spec = extraTypeSpecs[nodeType]
    return true
  false

proc setContextRegistrar*(registrar: proc(proj: ProjectFormat) {.nimcall.}) =
  contextRegistrar = registrar

proc runContextRegistrar*(proj: ProjectFormat) =
  if contextRegistrar != nil:
    contextRegistrar(proj)
