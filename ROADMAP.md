# GE-MCP Roadmap — to ~200 tool-actions + a shareable release

Written 2026-07-03. Current state: **33 tools** (8 core bridge + 25 toolkit),
single-file server (`giants_mcp_server.py`, ~1500 lines), injected helper
library v6, all live-tested on GE 10.0.13 / FS25.

## The one decision that shapes everything: flat tools vs grouped tools

MCP clients differ in how tool schemas hit the context window:

- **Claude Code**: defers tool schemas (loaded on demand) — 200 flat tools is fine.
- **Claude Desktop**: loads EVERY schema into context EVERY session — 33 tools
  already costs ~8-10k tokens; 200 flat tools would burn 40-60k tokens before
  the first message. For the modders we share this with (mostly Desktop users),
  that defeats the whole token-saving purpose.

**Decision: hybrid, three tiers.**
- The ~45 flagship tools stay first-class flat tools (discoverable, great docstrings).
- Specialist domains become **portmanteau tools** — one tool per domain with an
  `action` param (e.g. `field_ops(action="create_from_spline", ...)`), each
  wrapping many helper functions. Same coverage, fraction of the schema cost.
- **Snippet library** — `save_snippet` / `run_snippet` / `list_snippets` (3 schemas,
  ever): any run_lua that proved itself gets saved server-side with declared
  params (injected as a Lua ARGS table), description, GE version, run/failure
  counts. Unlimited saved scripts at ZERO marginal schema cost; composition is
  paid once per script lifetime, not once per session. `snippets/` is plain
  files → modders can share snippet packs without touching Python.
- **Tool groups toggle via env var** `GE_MCP_GROUPS` (default `all`; e.g.
  `core,splines,terrain,nodes` for a lean setup). Server registers only enabled
  groups at startup.

**Promotion pipeline (demand-driven, replaces speculative tool building):**
run_lua works → save_snippet (free) → high run-count → portmanteau action →
daily workhorse → flat tool with full schema + preview gate + op caps.
Safety-critical writes (terrain, mass placement) always graduate to real tools;
snippets carry no per-param validation or preview machinery of their own.

Counting tool-ACTIONS (flat + portmanteau actions + curated starter snippets),
the target is **~200 ≈ 45 flat + ~12 portmanteaus × 10-15 actions + snippet packs.**

## Phase A — Restructure + share-polish (NO editor needed; can run before 11pm)

Package layout (pip-installable, still zero-dependency beyond `mcp`):

```
GiantsEditor-mcp/
├── README.md              polished: what/why, GIF-able demos, quickstart
├── INSTALL.md             Claude Desktop + Claude Code + env vars
├── CHANGELOG.md           starts at v0.6.0
├── LICENSE                ← user decision (suggest MIT)
├── pyproject.toml         `pip install -e .`, entry point `ge-mcp`
├── ge_mcp/
│   ├── __init__.py        __version__
│   ├── server.py          FastMCP init, group registry, main()
│   ├── bridge.py          mailbox transport (+ appdata autodetect)
│   ├── validation.py      the Lua scanner/validator
│   ├── knowledge.py       scriptBinding/mined-signatures/live-globals index
│   ├── helpers.py         injection machinery (version, [NOHELPERS] retry)
│   └── tools/             one module per group, self-registering
│       ├── core.py        ping, run_lua, search_api, ... (8)
│       ├── splines.py     … existing + Phase E
│       ├── terrain.py     … existing + Phase D
│       ├── nodes.py       … existing v5 set
│       ├── vision.py      screenshot, camera, log
│       └── (new groups land here per phase)
├── lua/
│   ├── ge_mcp_poller.lua
│   └── helpers/           split by domain, concatenated + single version at inject
├── tests/
│   ├── offline/           validator, arg-marshalling, foliage-XML parser (pure py)
│   └── live/              stepwise per-group scripts (the python-import pattern)
├── scripts/
│   ├── docgen.py          auto-generates docs/TOOLS.md from docstrings
│   └── regression.py      runs every read-only tool + preview of every write tool
└── docs/
    ├── TOOLS.md           generated reference, one line per tool/action
    └── ARCHITECTURE.md    mailbox protocol, injection, crash doctrine
```

Also in Phase A:
- **Snippet library machinery** (`ge_mcp/snippets.py` + the 3 tools + `snippets/`
  starter dir) — pure file-side, offline-testable; live smoke test in Session 1.
  Also: my session memory gets a standing rule — check list_snippets before
  composing fresh Lua.
- `git init` + first commit + `.gitignore` (backups/, __pycache__, *.bak)
- Versioning: server v0.6.0; helpers stay integer-versioned (v6 → v7 on next change)
- Codify the **safety doctrine** in ARCHITECTURE.md (it's the selling point):
  1. every write tool previews by default (`commit=false`) with op estimates
  2. op caps refuse oversized jobs (GE crash history)
  3. terrain height ops are two-phase (reads before writes — vertex aliasing)
  4. never call undocumented-arity natives in batch; probe singles on fresh scenes
  5. never delete selected nodes (clearSelection first); refuse root/terrain/camera
  6. deterministic seeds: preview → commit places exactly what was shown
- Exit criteria: `pip install -e .` works, all 33 tools import + register, offline
  tests pass, docgen produces TOOLS.md. Live regression deferred to Session 1.

## Tool build-out by phase (each = one ~5h session, live GE)

Every session: probe unknowns first (types → single call → batch), stepwise
`python -u` tests, self-reverting where possible, end with regression + save +
`backups/` copy + memory update.

### Session 1 (tonight 11pm) — Regression + area painting + crash insurance
Priority: prove the restructure broke nothing, then the highest-value additions.
- **regression.py** over all 33 existing tools against live GE
- `backup_scene` — copy map.i3d + data/ to a timestamped folder, server-side
  (crash insurance BEFORE the paint tools make it matter). Flat tool.
- `paint_terrain_area` / `paint_foliage_area` — fill a CLOSED spline polygon
  (scanline over the polygon, reuses band-paint internals). Flat tools; this is
  the fields/meadows workhorse.
- `terrain_flatten_area` (building pads) + `terrain_stats` (min/max/avg/slope in area)
- `clear_foliage_area` (state 0 fill)
- Stretch: `terrain_paint_by_slope` (auto-texture cliffs where slope > threshold)
≈ +8 flat tools

### Session 2 — Fields & farmlands (`field_ops`, `farmland_ops` portmanteaus)
Research first: MapToolkitField API (memory: fieldUtil.lua deleted in 10.0.13;
fields root via onCreate=="FieldUtil.onCreate" or MapToolkitField.getFieldsRootNode()).
- field_ops: list, info (area ha, perimeter, corners), create_from_spline,
  delete_field, set_fruit, set_ground_state (cultivated/plowed/stubble),
  clear_area, regenerate_perimeter, add/move/remove corner
- farmland_ops: list, info, paint_id_area (infoLayer), assign_field, owner audit
- info_layer_ops: read_at, paint_area, list_layers (generic infoLayer access)
≈ +3 portmanteau tools ≈ 25 actions

### Session 3 — Splines II (`spline_edit` portmanteau + a few flat)
- spline_edit: create_from_points, add/move/delete CV, set_heights (drape to
  terrain / constant / smooth), resample (even CV spacing), reverse, close/open,
  join, split_at, offset_copy (parallel lanes), attributes get/set,
  export_csv, import_csv
- Flat: `create_fence_line` (connected posts + stretched panels — not scatter),
  `align_to_terrain_normal` (pitch/roll to slope for props/buildings)
≈ +3 tools ≈ 16 actions

### Session 4 — Scene hygiene & audit (`audit_ops`, `batch_ops` portmanteaus)
The mod-quality pass modders will love:
- audit_ops: full_scene (orphans, empty TGs, dupe names, silly clip distances,
  missing onCreate), broken_file_refs (parse map i3d vs disk — catches missing
  textures/i3ds BEFORE game load), collision_masks (FS25 scheme check from the
  TWC conversion recipe), lights, lod_distances, texture_sizes
- batch_ops: rename_pattern (with numbering), replace_asset (swap instances,
  keep transforms), clean_empty_groups, array_duplicate (line/grid/circle),
  distribute_evenly, mirror, snap_to_grid, set_collision_by_role
- `i3d_query` flat tool: read-only XPath into the map i3d (zero-risk info)
≈ +3 tools ≈ 20 actions

### Session 5 — Materials/render + traffic + vision extras
- material_ops: list (subtree), info, set_shader_param, get_shader_param,
  assign_from_node, lod_get/set, texture audit
- traffic_ops: list_traffic_splines, validate (direction/connectivity/naming),
  parallel-pair check, ai spawn audit
- vision extras (flat): `camera_orbit` (N shots around target), `camera_topdown`
  (ortho area render), `debug_view` (setDebugRenderingMode wrapper),
  `before_after` (screenshot pair around any commit)
≈ +6 tools ≈ 25 actions

### Session 6 — Game-data integration (server-side, mostly no editor needed)
- asset_ops: browse $data i3ds by category/search, asset_info (shapes/materials
  from XML), place_from_catalog (search → import_i3d → snap)
- mod_ops: modDesc info/validate, placeable_xml_validate (FS25 schema checks
  from the conversion recipes), fruit/fill type lists from game XMLs
≈ +2 portmanteaus ≈ 15 actions

### Running total after Session 6
33 existing + ~8 + ~25 + ~16 + ~20 + ~25 + ~15 ≈ **142 actions**, ~55 flat tools.
Remaining headroom to 200 = demand-driven: heightmap region import/export,
terrain noise/erosion, seasonal/visibility-condition tools, spline_to_road mesh
generation, PDA/minimap render, savegame-compat checks. Add when a real map
needs them, not for the number.

## Sharing checklist (Phase A + polish through sessions)

- [ ] LICENSE — **user decision** (MIT recommended)
- [ ] README: 90-second pitch, quickstart, 3 killer demos (river carve,
      tree line along spline, audit report), tool table link, safety doctrine
- [ ] INSTALL.md: Claude Desktop config JSON, Claude Code `claude mcp add`,
      poller install, env vars (GE_APPDATA, GE_VERSION_DIR, GE_GAME_DIR, GE_MCP_GROUPS)
- [ ] docs/TOOLS.md auto-generated; CHANGELOG.md
- [ ] GitHub repo — **user decision**: name (`giants-editor-mcp`?), account, public/private
- [ ] Screenshots/GIFs for README (Session 1, editor live)
- [ ] Version/compat statement: GE 10.0.x / FS25; editor-version autodetect explained
- [ ] Optional later: PyPI package, GIANTS forum / modding Discord announcement post

## Open decisions for the user
1. License (MIT?) and GitHub repo name/visibility
2. Portmanteau-vs-flat sign-off (plan assumes hybrid as argued above)
3. Priority order of Sessions 2-6 — which domain hurts most day-to-day?
4. Default GE_MCP_GROUPS for the shared build (`all` vs lean `core+splines+terrain`)
