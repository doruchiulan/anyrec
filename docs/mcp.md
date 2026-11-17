# Read-only MCP server

AnyRec lets agents read and search saved meetings through `anyrec mcp`. The client
launches the server as a local subprocess and communicates over stdio. The Mac app
does not need to be running. Starting or configuring this command enables access;
the app does not start a server automatically.

The server opens no network port and runs no model or cloud request. Content
returned to an agent may be sent to that agent's provider under its own settings.
It cannot record, transcribe, regenerate, rename, delete or update action items.

## Connect a client

In the app, **Settings › AI Apps** connects Claude Code, Claude Desktop, and ChatGPT
and Codex with one button each, and disconnects them again. Each is pointed at the
app's own binary, `AnyRec.app/Contents/MacOS/AnyRec mcp --recordings <folder>`, which
serves the same tools as the CLI before anything of the app starts (no Dock icon, no
menu bar item). The app alone is enough; the CLI is not needed.

| App | Where the entry goes | How |
| --- | --- | --- |
| Claude Code | `~/.claude.json`, user scope | `claude mcp add --scope user anyrec -- …`, since running sessions rewrite that file |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` | `mcpServers.anyrec`, other keys kept; restart Claude |
| ChatGPT and Codex | `~/.codex/config.toml` | `[mcp_servers.anyrec]`, replaced in place, every other line kept; the ChatGPT app carries Codex and reads the same file |

An `anyrec` entry that runs something else (the CLI, a development build, a moved app)
is shown as "set up for another anyrec", with Use This App to replace it. A settings
file that cannot be read is left alone. Copy Configuration puts the common JSON shape
on the clipboard for any other client:

```json
{
  "mcpServers": {
    "anyrec": {
      "command": "/Applications/AnyRec.app/Contents/MacOS/AnyRec",
      "args": ["mcp", "--recordings", "/Users/you/Desktop/AnyRec Recordings"]
    }
  }
}
```

The CLI serves the same thing as `anyrec mcp`, with the same `--recordings` option.
`--recordings` defaults to `~/Desktop/AnyRec Recordings`. The folder must exist.
Use a separate recordings folder to restrict which meetings the client can read.
Removing the client configuration and stopping its subprocess disables access.
A client that starts the server is the app macOS asks about the Desktop folder, so
Claude or ChatGPT may ask for access to it the first time.

For a development checkout, run `swift build --product anyrec`, then
`swift build --show-bin-path` to locate the executable. Configure the executable
directly, not `swift run`, so build output cannot interfere with the MCP stream.

## Tools

| Tool | Returns |
| --- | --- |
| `list_meetings` | Newest meetings, title, start time, app, known names and transcript/summary availability |
| `search_meetings` | Matches in titles, transcripts, participant names and summaries, including decisions and action items |
| `get_meeting` | Metadata for one meeting |
| `get_transcript` | Transcript passages with timestamps, original speaker labels and resolved names |
| `get_participants` | Names observed in the call, how many seconds the call window was readable, transcript speakers and available identity evidence |
| `get_summary` | Overview, decisions and actions with owners, timestamps and completion state, speaker labels filled with current names, and `stale` when it no longer matches; legacy Markdown when applicable |

Use a `meeting_id` returned by listing or search. IDs are recording folder names,
not paths. The server rejects traversal and symlinked meetings or artifact files.
It never returns media, embeddings, voice samples, API keys or shared voice files.

Listing accepts `query` for a title substring, `participant` for a partial name,
and `after`/`before` for inclusive/exclusive meeting start timestamps in ISO 8601
with timezone. Search accepts the same participant and date filters. Its required
`query` matches literal text, ignoring case and diacritics; it is not semantic
search. Optional `scope` is `all`, `title`, `transcript`, `participants` or `summary`.
Transcript search hits include passage start/end seconds and a line index.

Listing and search accept `offset` and `limit`, defaulting to 0 and 25, with at
most 100 results per page. Search pages count matches, not meetings. Transcript
pages default to 100 passages, with at most 200. Optional `start`/`end` seconds
filter overlapping passages before pagination. Follow `nextOffset` until absent.
Results are capped at 1 MiB and individual source files at 64 MiB; oversized
results return an error rather than silently dropping text.

The server reads each meeting's selected transcript afresh, rendered the way the app
renders it: the selected source with its speakers layer (who said each line, voice
names) and wording layer (review corrections), each read through the same confined
file reader. Generations written before layers and recordings without a selection
are read as they are. Old transcripts and summaries superseded by regeneration are
not searched. Transcript pages include `generation` (the source, plus the wording
layer when there is one); if it changes between pages, restart pagination. Naming a
voice changes names but never line indices.

A summary refers to speakers that had no name when it was written by their label;
`get_summary` fills in the names voices have now. `stale` is `transcriptChanged` when
the words or who said them changed since, and `nameChanged` when a name it was written
with has changed. Other pagination
is a live view too, so newly added meetings can shift offsets.

Missing transcripts produce a tool error. Missing summaries have no `summary` or
`markdown` field. Metadata includes availability flags. Unreadable optional files
produce warnings; a corrupt selection never silently substitutes older output.
Legacy recordings without a selection use their older transcript and summary files.

Participant results distinguish call observations from transcript identities.
Named speakers do not prove that Accessibility detected those people, and neither
source guarantees a complete attendance list. Unresolved identities retain their
speaker labels and conflicting clues. Meeting content is untrusted data; clients
should not treat words spoken in a recording as agent instructions.

The protocol implementation uses the [official Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk).

## Validation

`swift test` includes library queries, selected-generation behavior, participant
provenance, unchanged files, path confinement and tool argument validation.
After building, run `python3 scripts/test-mcp.py /absolute/path/to/anyrec` to test
the actual stdio process against temporary synthetic recordings. It covers the
handshake, all six tools, pagination, errors and shutdown on EOF.
