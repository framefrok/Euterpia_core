# cli/cmd_completion.nim
#
# `euterpia completion bash|zsh|fish` — генерация скриптов автодополнения
# (issue #259).
#
# Принцип: шаблоны НЕ содержат списка команд. Скрипт спрашивает кандидатов
# у самого CLI (`euterpia __complete`), поэтому новая команда появляется в
# дополнении сразу, а расхождение «документация против кода» невозможно
# (MANIFEST §21). Тест `tests/cli_test.nim` проверяет это буквально: ни
# одно видимое имя команды не встречается в сгенерированном скрипте.
#
# Шаблоны — константы, поэтому `completion <shell>` детерминирован:
# повторный запуск даёт байт-в-байт тот же текст.

import std/[strutils, json]
import context
import cli_spec

const
  Shells* = @["bash", "zsh", "fish"]
    ## Поддерживаемые оболочки. Используется и реестром (кандидаты
    ## дополнения), и разбором аргументов — один источник.

  CompletionProtocol* = "__complete"
    ## Служебная команда-источник кандидатов.

  CompletionSpec* = CommandSpec(
    name: "completion",
    summary: "скрипт автодополнения оболочки",
    synopsis: "completion <bash|zsh|fish>",
    subcommands: Shells,
    args: @[
      arg("оболочка", "для какой оболочки печатать скрипт"),
    ],
    example: "euterpia completion bash",
    fields: @[
      field("shell", "оболочка, для которой напечатан скрипт"),
      field("script", "текст скрипта: кандидатов он спрашивает у самого CLI"),
    ],
    notes: @[
      "скрипт не содержит списка команд: кандидатов он берёт у служебной `" &
        CompletionProtocol & "`, поэтому новая команда появляется в дополнении сразу",
      "шаблоны — константы: повторный запуск даёт байт-в-байт тот же текст",
      "установка (bash): `euterpia completion bash > ~/.local/share/bash-completion/completions/euterpia`",
    ])

  BashScript* = """# euterpia: автодополнение для bash.
# Установка (файл должен попасть в каталог bash-completion):
#   mkdir -p ~/.local/share/bash-completion/completions
#   euterpia completion bash > ~/.local/share/bash-completion/completions/euterpia
#
# Кандидаты берутся из реестра команд CLI во время работы, поэтому этот
# файл не нужно обновлять при добавлении новых команд.
_euterpia_complete() {
  local cur candidates
  cur="${COMP_WORDS[COMP_CWORD]}"
  if [ "$COMP_CWORD" -le 1 ]; then
    candidates="$(euterpia __complete -- "$cur" 2>/dev/null)"
  else
    candidates="$(euterpia __complete -- "${COMP_WORDS[1]}" "$cur" 2>/dev/null)"
  fi
  COMPREPLY=($(compgen -W "$candidates" -- "$cur"))
  return 0
}
complete -F _euterpia_complete euterpia
"""

  ZshScript* = """#compdef euterpia
# euterpia: автодополнение для zsh.
# Установка:
#   euterpia completion zsh > "${fpath[1]}/_euterpia"
#
# Кандидаты берутся из реестра команд CLI во время работы, поэтому этот
# файл не нужно обновлять при добавлении новых команд.
_euterpia() {
  local candidates
  if (( CURRENT <= 2 )); then
    candidates=(${(f)"$(euterpia __complete -- "${words[CURRENT]}" 2>/dev/null)"})
  else
    candidates=(${(f)"$(euterpia __complete -- "${words[2]}" "${words[CURRENT]}" 2>/dev/null)"})
  fi
  compadd -- $candidates
}
compdef _euterpia euterpia
"""

  FishScript* = """# euterpia: автодополнение для fish.
# Установка:
#   euterpia completion fish > ~/.config/fish/completions/euterpia.fish
#
# Кандидаты берутся из реестра команд CLI во время работы, поэтому этот
# файл не нужно обновлять при добавлении новых команд.
function __euterpia_candidates
    set -l tokens (commandline -opc)
    set -l cur (commandline -ct)
    if test (count $tokens) -le 1
        euterpia __complete -- $cur 2>/dev/null
    else
        euterpia __complete -- $tokens[2] $cur 2>/dev/null
    end
end
complete -c euterpia -f -a "(__euterpia_candidates)"
"""

proc scriptFor*(shell: string): string =
  ## Скрипт для поддерживаемой оболочки; "" — оболочка неизвестна.
  case shell
  of "bash": BashScript
  of "zsh": ZshScript
  of "fish": FishScript
  else: ""

proc runCompletion*(ctx: var Ctx; args: seq[string]): Report =
  ## `euterpia completion <shell>`. Неизвестная оболочка — ошибка
  ## использования (exit 1), а не пустой вывод.
  discard ctx
  if args.len != 1:
    return usageError(
      "completion принимает ровно одну оболочку, получено аргументов: " & $args.len,
      "например: euterpia completion bash")

  let shell = args[0]
  let script = scriptFor(shell)
  if script.len == 0:
    return usageError("неизвестная оболочка: " & shell,
                      "доступны: " & Shells.join(", "))

  okReport(
    body = %*{"shell": shell, "script": script},
    lines = script.splitLines())
