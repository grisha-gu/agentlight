# hook-capture

A logging HTTP server that records exactly what Claude Code sends with `http` hooks.
Findings: [docs/05-host-macos.md §5.3](../../docs/05-host-macos.md#53-receiving-hooks-over-http).

## Usage

```bash
python3 hookcap.py            # listens on 127.0.0.1:48879, writes hooks.log
```

Stop the AgentLight daemon first if it is running (it uses the same port). Then add to
a project's `.claude/settings.json`:

```json
{ "hooks": { "PreToolUse": [ { "hooks": [
  { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 5 }
] } ] } }
```

Changes to `settings.json` are picked up live; no session restart is needed.

## Contents

* `hookcap.py` — the logging server: method, path, headers, body. Replies 204.
* `samples.jsonl` — real captured requests (paths anonymised).

## Why it is in the repository

`samples.jsonl` is a test fixture for `AgentLightKit`: the `HookEvent` decoder must
parse these bodies and ignore unknown fields. When Claude Code changes the format,
re-run the capture and update the fixture.
