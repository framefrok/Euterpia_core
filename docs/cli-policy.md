# CLI compatibility policy

This document is the contract for changing the command line interface
(issue #350). It applies to command names, options, human output, the JSON
envelope, script files, presets and man pages.

The policy is enforced, not just written:

- `libs/cli_spec.validateSpecs` rejects malformed specifications (aliases
  without a version, `replacedBy` pointing at an unknown command, duplicate
  keys);
- `tests/cli_test.nim` checks that every declared option is accepted, that
  aliases still execute the canonical command, and that an old `--script`
  line keeps working;
- `__man --check` compares committed man pages with the registry, so a new
  command cannot ship without a manual page;
- `docs/cli.md` and `help --json` are generated from the same specification.

## 1. Version numbers

There are four independent versions. They are not interchangeable:

| version | where | meaning |
|---|---|---|
| package `X.Y.Z` | `euterpia_version.nim`, `--version`, release tag | product release; CLI and package cannot disagree |
| JSON envelope `schema` | every `--json` answer | shape of the response envelope and error fields |
| project format `format`/`version` | `.eproj` / `.eut` | on-disk project format (MANIFEST §58/§59) |
| script / preset `format`/`version` | `.eus`, `.preset.json`, `.setlist.json`, `.params.json` | reproducible inputs |

`euterpia --version` and the tag must match (checked by `tools/package.sh`
and the release workflow).

## 2. What can change without a schema bump

These changes are **additive** and keep the same `schema`/`format` version:

- a new command, a new subcommand, a new option with a safe default;
- a new field in a JSON response (readers must ignore unknown fields);
- a new error reason with a documented `errorCode`/`exitCode` row;
- help text, examples, notes, man pages, completion scripts;
- a new alias for an existing command (see §3);
- performance improvements and diagnostics that do not change meaning.

An old client must still work: unknown fields are ignored, unknown options
are not sent, and defaults preserve the previous behavior.

## 3. Deprecation and renames

A rename is never a hard break:

1. add the new canonical name;
2. keep the old name as `aliases: @["old-name"]` and set
   `aliasesDeprecatedSince` to the release where it became legacy;
3. every use of the alias prints a warning to **stderr** (stdout stays a
   single parseable JSON envelope in `--json`);
4. `help <alias>` resolves to the canonical page; completion advertises only
   the canonical name;
5. remove the alias only after at least two minor releases, and only with a
   new major/minor line; removal is a breaking change.

The same rule applies to a whole command: `deprecatedSince` + `replacedBy`
in the specification keeps it working and says what to use instead.
`validateSpecs` requires `replacedBy` for a deprecated command.

Scripts are protected by design: `libs/script` stores **control commands**
(`node.create`, `param.set`, …), not CLI command lines, so a CLI rename does
not rewrite a `.eus` file. Batch lines (`--script`, stdin, REPL) go through
the same alias table as argv.

## 4. Breaking changes

A change is breaking when it removes or renames a command/option/field,
changes a type or unit, makes an optional argument required, or changes the
meaning of an existing value. Breaking changes require:

- a new `schema` for JSON output and/or a new `format` version for files;
- a deprecation window for the old form (§3);
- a note in `CHANGELOG.md` that says what breaks and how to migrate;
- a reader-side rule: a client that sees a newer `schema` must warn and
  refuse to interpret unknown semantics, not guess. A script with a newer
  `version` is rejected with a clear error and `exitCode` 1.

Additive changes are not breaking even if they appear in a new release; do
not bump `schema` for them, because that would force every client to update
for no reason.

## 5. Scripts and presets

- `euterpia.script` v1: commands are control-layer commands with stable
  names; unknown commands are rejected with a reason and a position.
- Preset/setlist/param-preset v1: fields are validated against the node
  registry before application; an unknown node type is `not_found`, an
  out-of-range parameter is `invalid_argument`.
- A future version is always rejected with a hint to update the binary; it
  is never read as a best-effort subset.

## 6. Release checklist

1. `nimble unit`, `nimble cliSmoke`, `nimble integration`;
2. `tools/script_scenario.sh build/euterpia` (golden render);
3. `tools/quickstart.sh build/euterpia` (documentation is executable);
4. `euterpia __man --check man` and `git diff --exit-code docs/cli.md man/`;
5. `python3 tools/check_architecture.py`;
6. version bump in `euterpia_version.nim` + `touch euterpia.nimble`;
7. tag `vX.Y.Z` matching the version; the release workflow builds three
   platforms and publishes checksums.
