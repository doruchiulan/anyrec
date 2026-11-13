#!/usr/bin/env python3
"""Exercise the built CLI over stdio using a temporary, synthetic meeting library."""

import hashlib
import json
from pathlib import Path
import select
import subprocess
import sys
import tempfile


def write(path, value):
    path.write_text(json.dumps(value), encoding="utf-8")


def fixture(root):
    meeting = root / "rec-2026-11-01-120000"
    meeting.mkdir()
    write(meeting / "recording.json", {
        "title": "MCP smoke meeting", "bundleID": "com.tinyspeck.slackmacgap",
        "width": 1280, "height": 720, "fps": 30,
    })
    write(meeting / ".transcription.json", {
        "transcript": "transcript-reviewed-smoke.json", "voices": "voices-smoke.json",
        "summary": "summary-reviewed-smoke.json",
    })
    write(meeting / "transcript-reviewed-smoke.json", {
        "engine": "reviewed", "language": "en", "notes": [], "utterances": [
            {"start": 0, "end": 4, "text": "Ship on Friday.", "speaker": {"voice": {"_0": "A"}}},
            {"start": 5, "end": 9, "text": "Prepare the checklist.", "speaker": {"voice": {"_0": "A"}}},
        ],
    })
    write(meeting / "voices-smoke.json", {"voices": [{
        "letter": "A", "name": "Alex", "print": [1, 0], "sample": "Ship on Friday.", "start": 0, "end": 4,
    }]})
    write(meeting / "call-participants.json", {"observations": [{
        "at": 1, "source": "slack", "participants": ["Alex", "Guest"], "speaking": ["Alex"],
    }]})
    write(meeting / "summary-reviewed-smoke.json", {
        "overview": "Release planning", "decisions": ["Ship Friday"], "provider": "fixture",
        "actions": [{"task": "Prepare checklist", "owner": "Alex", "at": 5, "done": False}],
    })
    return meeting.name


def hashes(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob("*") if p.is_file()}


class Connection:
    def __init__(self, executable, root):
        self.process = subprocess.Popen([executable, "mcp", "--recordings", str(root)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.sequence = 0
        self.pending = b""

    def send(self, method, params, request_id=None):
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if request_id is not None:
            message["id"] = request_id
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()

    def request(self, method, params):
        self.sequence += 1
        self.send(method, params, self.sequence)
        while True:
            while b"\n" not in self.pending:
                ready, _, _ = select.select([self.process.stdout], [], [], 10)
                assert ready, f"Timed out waiting for {method}"
                chunk = self.process.stdout.read1(65536)
                assert chunk, f"Server exited during {method}"
                self.pending += chunk
            line, self.pending = self.pending.split(b"\n", 1)
            message = json.loads(line)
            if message.get("id") == self.sequence:
                return message

    def tool(self, name, **arguments):
        reply = self.request("tools/call", {"name": name, "arguments": arguments})
        result = reply["result"]
        assert not result.get("isError"), result
        data = json.loads(result["content"][0]["text"])
        assert data == result["structuredContent"]
        return data

    def close(self):
        self.process.stdin.close()
        assert self.process.wait(timeout=10) == 0, self.process.stderr.read().decode()
        assert not self.pending and not self.process.stdout.read(), "Non-protocol output on stdout"


def exercise(connection, meeting_id):
    response = connection.request("initialize", {
        "protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"},
    })["result"]
    assert response["serverInfo"]["name"] == "anyrec"
    assert "tools" in response["capabilities"]
    connection.send("notifications/initialized", {})
    tools = connection.request("tools/list", {})["result"]["tools"]
    assert len(tools) == 6 and all(t["annotations"]["readOnlyHint"] for t in tools)
    assert connection.tool("list_meetings")["items"][0]["id"] == meeting_id
    assert connection.tool("get_meeting", meeting_id=meeting_id)["title"] == "MCP smoke meeting"
    assert connection.tool("search_meetings", query="Friday", scope="transcript")["items"][0]["start"] == 0
    first = connection.tool("get_transcript", meeting_id=meeting_id, limit=1)
    assert first["nextOffset"] == 1 and first["lines"][0]["speakerName"] == "Alex"
    last = connection.tool("get_transcript", meeting_id=meeting_id, offset=1)
    assert "nextOffset" not in last and last["lines"][0]["index"] == 1
    assert connection.tool("get_summary", meeting_id=meeting_id)["summary"]["actions"][0]["at"] == 5
    participants = connection.tool("get_participants", meeting_id=meeting_id)
    assert participants["observedInCall"] == ["Alex", "Guest"]
    assert '"print"' not in json.dumps(participants)
    bad = connection.request("tools/call", {"name": "get_meeting", "arguments": {"meeting_id": "../secret"}})
    assert bad["result"]["isError"]
    unknown = connection.request("tools/call", {"name": "delete_meeting", "arguments": {}})
    assert unknown["error"]["code"] == -32602


def main():
    executable = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="anyrec-mcp-smoke-") as path:
        root = Path(path)
        meeting_id = fixture(root)
        before = hashes(root)
        connection = Connection(executable, root)
        try:
            exercise(connection, meeting_id)
            connection.close()
            assert hashes(root) == before, "Server modified the library"
        finally:
            if connection.process.poll() is None:
                connection.process.kill()
                connection.process.wait()
    print("MCP stdio smoke passed: handshake, all six tools, pagination, errors, read-only files and clean EOF.")


if __name__ == "__main__":
    main()
