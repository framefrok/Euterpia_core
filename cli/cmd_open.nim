# cli/cmd_open.nim
#
# `euterpia open <project>` — the entry point used by file associations
# (#348). It opens a project read-only, prints what is inside, and points at
# the next command. The desktop/registry helper `euterpia-open` changes the
# working directory to the project before calling this command, so a click on
# a `.eproj`/`.eut` file behaves like opening the project in a terminal.
#
# This command deliberately does not modify the project: opening is a read,
# not an edit. Editing stays explicit (`project set`, `node add`, ...).

import std/[json, os, strutils]

import context
import cli_spec
import cmd_project
import control/query
import control/document
import control_bridge

const
  OpenSpec* = CommandSpec(
    name: "open",
    summary: "open a project and show what it contains",
    synopsis: "open [проект.eproj]",
    args: @[
      arg("проект.eproj", "project file; default: " & DefaultProjectFile),
    ],
    options: @[
      opt("--file", "project path when it is not positional",
          value = projectSuffixesHint()),
    ],
    example: "euterpia open demo.eproj",
    fields: @[
      field("path", "opened project file"),
      field("documentId", "document identifier used by entity addresses"),
      field("metadata", "name, author, tempo, sample rate, time signature"),
      field("graph", "nodes and connections"),
      field("sequencer", "tracks, clips and automation"),
      field("summary", "counts: nodes, connections, tracks, clips, notes"),
      field("next", "suggested next command"),
    ],
    notes: @[
      "read-only: `open` never changes the project file",
      "file associations call `euterpia-open`, which changes to the project directory and then runs `open`",
      "a bare project path as the first argument is treated as `open <path>` (#348)",
    ])

  OpenKeys* = OpenSpec.optionKeys

proc scanOpen(args: seq[string]): tuple[ok: bool; rep: Report; path: string] =
  result.path = DefaultProjectFile
  var positional: seq[string] = @[]
  let tokens = splitInline(args)
  var i = 0
  while i < tokens.len:
    let token = tokens[i]
    if token == "--file":
      if i + 1 >= tokens.len:
        return (false, usageError("--file: project path is required"), "")
      result.path = tokens[i + 1]
      inc i, 2
      continue
    if token.startsWith("--"):
      return (false, usageError("unknown open option: " & token,
                                "options: " & OpenKeys.join(", ")), "")
    positional.add token
    inc i
  if positional.len > 1:
    return (false, usageError("open accepts one project, got: " &
                              positional.join(" ")), "")
  if positional.len == 1:
    result.path = positional[0]
  (true, okReport(), result.path)

proc runOpen*(ctx: var Ctx; args: seq[string]): Report =
  ## Load the project, print metadata and contents, suggest the next command.
  discard ctx
  let scan = scanOpen(args)
  if not scan.ok:
    return scan.rep
  let loaded = loadAt(scan.path)
  if not loaded.ok:
    return loaded.rep
  let doc = openDocument(scan.path, loaded.proj)
  let meta = queryMetadata(doc)
  let summary = querySummary(doc)

  var body = projectBody(doc, scan.path)
  body["next"] = %("euterpia render " & scan.path & " " &
    scan.path.changeFileExt(".wav"))
  var lines: seq[string] = @[
    "project: " & scan.path,
    "name: " & (if meta.name.len > 0: meta.name else: "(not set)"),
    "tempo: " & $meta.tempo & " BPM, sample rate: " & $meta.sampleRate &
      " Hz, time signature: " & $meta.tsNumerator & "/" & $meta.tsDenominator,
    "nodes: " & $summary.nodes & ", connections: " & $summary.connections &
      ", tracks: " & $summary.tracks & ", clips: " & $summary.clips &
      ", notes: " & $summary.notes,
    "",
    "Next:",
    "  euterpia render " & scan.path & " " & scan.path.changeFileExt(".wav"),
    "  euterpia graph check " & scan.path,
    "  euterpia --help",
  ]
  okReport(body = body, lines = lines)
