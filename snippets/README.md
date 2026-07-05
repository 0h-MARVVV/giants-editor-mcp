# Snippet packs

Each `.json` file here is one saved, replayable Lua script. Claude manages them
with the `save_snippet` / `run_snippet` / `list_snippets` tools, but they're
plain files — copy them between machines, share packs with other modders,
delete what you don't want.

Format:

```json
{
  "name": "find-high-clip",
  "description": "list nodes under ARGS.root with clipDistance above ARGS.limit",
  "lua": "local out = {} ... return table.concat(out, '\n')",
  "params": [{"name": "limit", "default": 800}, {"name": "root", "default": "map"}],
  "created": "2026-07-03 22:10:00",
  "ge_version": "10.0.13",
  "runs": 4, "failures": 0, "last_ok": true, "last_run": "..."
}
```

The script reads its parameters from a Lua table called `ARGS`
(`run_snippet` prepends `local ARGS = {limit=800, ...}`). End the script with
`return <string>` — that string is the tool result.

Files named `*.local.json` are gitignored (personal snippets that shouldn't
ship with the repo).
