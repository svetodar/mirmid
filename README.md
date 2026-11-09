# Project «mirmid»

Console AI-agent harness written in Free Pascal. This is a placeholder README;
the full user documentation is written in a later phase.

## Tool settings (`[tools]`)

Every built-in tool is switched on or off in `./.mirmid/mirmid.ini`, one key per
tool, `1`/`0`:

```ini
[tools]
file_list=1
exist_file=1
read_text_file=1
read_pascal_interface=1
grep=1
list_windows=1
find_window=1
window_info=1
edit_text_file=0
copy_file=0
shell=0
http_request=0
subagent=0
read_media_file=0
screen_shoot=0
window_shoot=0
revise_plan=1
```

- Read-only inspection tools default to `1`; tools that write files, run shell
  commands, open network connections, spawn a subagent or capture the screen
  default to `0`.
- A disabled tool is absent from the `tools` array of the request **and** its
  handler refuses to run (`ERROR: tool "<name>" is disabled`), because
  subagents, plan steps and MCP share the same registry.
- An unknown key is a startup error (`Error: unknown tool "<name>"; known
  tools: ...` on stderr, exit code 1) — a typo never silently falls back to a
  default.
- `mcp__<server>__<tool>` tools are governed by the `[mcp]` section, not by
  per-tool keys.

Behaviour change: `screen_shoot`, `window_shoot` and `read_media_file` now have
their own keys instead of inheriting the removed global write switch, so a
screenshot needs `screen_shoot=1` (`window_shoot=1` for a window capture) and
reading an image or audio file needs `read_media_file=1`.
