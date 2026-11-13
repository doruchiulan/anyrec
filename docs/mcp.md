# Read-only MCP server

AnyRec lets agents read and search saved meetings through `anyrec mcp`. The client
launches the server as a local subprocess and communicates over stdio. The Mac app
does not need to be running. Starting or configuring this command enables access;
the app does not start a server automatically.

The server opens no network port and runs no model or cloud request. Content
returned to an agent may be sent to that agent's provider under its own settings.
It cannot record, transcribe, regenerate, rename, delete or update action items.

## Connect a client

Use an absolute path to the `anyrec` CLI built from this version:

```json
{
  "mcpServers": {
    "anyrec": {
      "command": "/absolute/path/to/anyrec",
      "args": ["mcp", "--recordings", "/Users/you/Desktop/AnyRec Recordings"]
    }
  }
}
```

This is the common JSON configuration shape; adapt it to your client's format.
`--recordings` defaults to `~/Desktop/AnyRec Recordings`. The folder must exist.
Use a separate recordings folder to restrict which meetings the client can read.
Removing the client configuration and stopping its subprocess disables access.

For a development checkout, run `swift build --product anyrec`, then
`swift build --show-bin-path` to locate the executable. Configure the executable
directly, not `swift run`, so build output cannot interfere with the MCP stream.
The published 0.4.0 CLI predates this feature; it needs a new build.

## Tools

| Tool | Returns |
| --- | --- |
| `list_meetings` | Newest meetings, title, start time, app, known names and transcript/summary availability |
| `search_meetings` | Matches in titles, transcripts, participant names and summaries, including decisions and action items |
| `get_meeting` | Metadata for one meeting |
| `get_transcript` | Transcript passages with timestamps, original speaker labels and resolved names |
| `get_participants` | Names observed in the call, transcript speakers and available identity evidence |
| `get_summary` | Overview, decisions and actions with owners, timestamps and completion state; legacy Markdown when applicable |

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

The server reads each meeting's selected generation afresh. Old transcripts and
summaries superseded by regeneration are not searched. Transcript pages include
`generation`; if it changes between pages, restart pagination. Other pagination
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
