# Installing ge-mcp

Complete instructions, assuming nothing. Two install routes — the one-click
bundle for Claude Desktop, or the manual route for Claude Code / other MCP
clients. Both end at the same place.

## Requirements

- **Windows 10/11**
- **GIANTS Editor 10.x** (FS25) installed and able to open your map
- **Farming Simulator 25** installed (for `$data` assets/foliage — Steam, Epic or GIANTS launcher)
- **Python 3.10 or newer** (step 0 below if you don't have it)
- **Claude Desktop** or **Claude Code**

## Step 0 — Python (command crib sheet)

All commands go in Command Prompt or PowerShell.

**0. Check current installation:**

```
python --version
```

[anything 3.10 or above = skip to step 2.2]

**1. Install Python:**

```
winget install -e --id Python.Python.3.12 --override "/quiet InstallAllUsers=0 PrependPath=1"
```

[the `--override` forces "Add to PATH". Once step 1 finishes, CLOSE the
terminal and open a fresh one for step 2]

**2. Python MCP support:**

2.1:

```
python --version
```

[checks Python installed correctly — should print 3.12.x]

2.2:

```
python -m pip install mcp
```

[installs MCP support; finishing without red text = ready]

**Manual alternative** if winget is missing: download from
<https://www.python.org/downloads/> (any 3.10+) and **tick "Add python.exe to
PATH"** in the installer — the most-missed checkbox in modding.

**Avoid the Microsoft Store Python** (what opens if you type `python` on a
bare machine): it runs sandboxed and can redirect the very file writes this
bridge depends on. If that alias hijacks the command, turn it off under
*Settings → Apps → Advanced app settings → App execution aliases → python.exe*.

## Option A — one-click bundle (Claude Desktop, easiest)

1. Do Step 0 (Python + `pip install mcp`)
2. **Drag `ge-mcp-<version>.mcpb` into Claude Desktop** (or double-click it).
   It appears under *Settings → Extensions* with two optional settings:
   *Tool groups* (default `all`) and *FS25 install folder* (normally auto-detected — leave empty)
3. In a new chat, ask Claude:
   > run setup with install_poller
   Claude copies the in-editor poller into GIANTS Editor's scripts folder for you
4. Start **GIANTS Editor**, load your map, run **Scripts → GE-MCP Bridge**
   (the editor log prints `[GE-MCP] bridge armed`)
5. Ask Claude:
   > run setup
   Expect `bridge: OK` and a green chain. You're done — see
   "[Your first session](#your-first-session)" below.

## Option B — manual (Claude Code, or any MCP client)

### B1. Get the files

Unzip `ge-mcp-<version>.zip` (or clone the repo) somewhere permanent,
e.g. `D:\Tools\GiantsEditor-mcp`. Don't move it afterwards — your Claude
config will point at this path.

### B2. Register the MCP server

**Claude Desktop** — add to `%APPDATA%\Claude\claude_desktop_config.json`
under `mcpServers`, then fully quit and restart Claude Desktop:

```json
"giants-editor": {
  "command": "python",
  "args": ["D:\\Tools\\GiantsEditor-mcp\\giants_mcp_server.py"]
}
```

**Claude Code** (terminal):

```
claude mcp add giants-editor -- python D:\Tools\GiantsEditor-mcp\giants_mcp_server.py
```

If your Python isn't on PATH, use the full path to `python.exe` as the command.

### B3. Install the in-editor poller (once)

Either ask Claude to `run setup with install_poller`, or copy it yourself:
`lua\ge_mcp_poller.lua` → `%LOCALAPPDATA%\GIANTS Editor 64bit <your version>\scripts\`

### B4. Each editor session

Open your map, then run **Scripts → GE-MCP Bridge**. The editor log should show:

```
[GE-MCP] bridge armed. listener id=1  loop playing=true
[GE-MCP] AUTOMATIC mode active -- commands will run on their own.
```

The poller keeps running even with the editor in the background. The Lua
helper library injects itself automatically on the first toolkit call —
nothing else to load.

### B5. First test

Ask Claude to run **`setup`**:

```
ge-mcp setup status
  bridge:         OK (editor answering)
  editor appdata: C:\Users\you\AppData\Local\GIANTS Editor 64bit 10.0.13  (GE 10.0.13)
  game dir:       C:/.../Farming Simulator 25  [editor.xml (GE preferences)]
  helper library: not injected yet (auto-injects on first toolkit call)
  snippets:       2 saved
  tool groups:    GE_MCP_GROUPS=all
```

The FS25 game dir auto-detects from the editor's own preferences. If it shows
"not found", ask Claude: `run setup with game_dir "D:\path\to\Farming Simulator 25"` —
validated and remembered.

## Recommended companion — the FS25 knowledge pack

ge-mcp gives Claude *hands* in the editor; **[fs25-skills by
Paint-a-Farm](https://github.com/Paint-a-Farm/fs25-skills)** gives it FS25
*knowledge* (modDesc standards, Lua patterns, i3d/DDS formats, packaging,
debugging). They're made for each other — install both and Claude knows the
conventions AND can act on them.

**Claude Code** (two slash commands, once):

```
/plugin marketplace add paint-a-farm/fs25-skills
/plugin install fs25-modding
```

**Cursor**: Rules & Command → Project Rules → Add Rule → Remote Rule (GitHub) →
`https://github.com/paint-a-farm/fs25-skills.git`

**Other agents** (needs bun): `bunx skills add paint-a-farm/fs25-skills`

(Claude Desktop has no skills installer today — Desktop users lose nothing:
ge-mcp's tool descriptions carry the editor knowledge Claude needs to drive it.)

## Your first session

Things to say to Claude once `setup` is green (also see the README's
"What can I ask it?" list):

- *"Take a screenshot of my editor"* — proves vision works
- *"Back up my map"* — do this before any painting session
- *"List my splines"* / *"Audit my map for broken file references"*
- *"Carve a 1.5m deep creek along ‹spline name› and smooth the banks"* —
  every write tool shows a **preview first** and only applies when you confirm

Two safety facts worth knowing from day one: terrain/foliage painting has
**no undo** in the editor (that's why `backup_scene` exists and why every
paint tool previews first), and object placements always land in **one new
group** — deleting that group reverts the whole placement.

## Each time you update ge-mcp

Replace the files (or re-drag the new `.mcpb`), then **restart your Claude
session** — the server is spawned once per session. The helper library
re-injects itself automatically; if a release notes a poller change, run
`setup with install_poller` again and restart the editor.

## Uninstall

- **Option A**: Claude Desktop → Settings → Extensions → remove *ge-mcp*
- **Option B**: remove the `giants-editor` block from
  `claude_desktop_config.json` (or `claude mcp remove giants-editor`), delete the folder
- Both: delete `ge_mcp_poller.lua` from
  `%LOCALAPPDATA%\GIANTS Editor 64bit <version>\scripts\`
- Nothing else is touched: no registry, no services, no game-file changes.
  Map backups you made live in `map_backups/` next to the install — keep or
  delete as you like.

## Environment variables (all optional)

| Var | Purpose |
| --- | --- |
| `GE_MCP_GROUPS` | comma list of tool groups to register (default `all`): `core,splines,terrain,nodes,fields,hygiene,materials,traffic,assets,vision,scene,snippets` |
| `GE_APPDATA` | full path to the editor's AppData folder (skip auto-detection) |
| `GE_VERSION_DIR` | just the folder name under `%LOCALAPPDATA%` |
| `GE_GAME_DIR` | FS25 install dir override; normally auto-detected from GE preferences or set once via the `setup` tool |
| `GE_EDITOR_DIR` | editor install dir (skip `getEditorDirectory()` lookup) |

## Troubleshooting

Ask Claude to run `setup` first for any problem — it pinpoints which link is broken.

| Symptom | Likely cause / fix |
| --- | --- |
| `ping_editor`: "Bridge not responding (checked for 5s)" | editor not open, or the poller wasn't run this session — Scripts → GE-MCP Bridge |
| every tool: "Editor not answering (8s probe)" | same as above; if the editor is mid-load on a big map, just retry |
| `run_lua` times out with the editor open | poller not loaded in THIS session (it dies with the editor) — run it again from the Scripts menu |
| toolkit tool says `[ERROR] helper injection failed` | a corrupted `lua/ge_mcp_helpers.lua` — re-extract the download, then retry (check `read_log` for the compile error) |
| `viewport_screenshot` window mode errors | editor minimized or on another virtual desktop; use `mode="render"` instead |
| `setup` shows game dir "not found" | set it once: `setup(game_dir=...)` pointing at the folder that contains `data\` |
| server won't start / extension errors at once | `mcp` not installed in the Python that runs the server → `pip install mcp`; multiple Pythons → use the full python.exe path |
| tools missing after updating ge-mcp | restart the Claude session (server is spawned per session) |
| `get_events` says NOT armed | reload the poller from the Scripts menu |
| Windows SmartScreen/antivirus complains about `save_scene` | it sends Ctrl+S to the editor window via WScript — allow it, or save manually in GE |

## What this thing never does

No network calls (everything is local files + the editor mailbox), no game
file modification outside your own mod map, no writes without a preview or an
explicit commit, and deletions refuse the scene root, terrain and camera.
