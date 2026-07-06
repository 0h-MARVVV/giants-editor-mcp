# Changelog

## 1.0.1 — 2026-07-05

- **`xml_schema`** (60th tool): browse the game's own 88 XSD schemas from
  `shared/xml/schema` — the complete, version-true reference of every valid
  element, attribute, type, enum and default for any FS25 XML (placeable,
  vehicle, fields, farmlands, ...). Agents are directed here before writing
  XML instead of guessing.
- Docs recommend **fs25-skills** by Paint-a-Farm as the knowledge companion,
  with per-client install commands in the setup flow.
- Bug reports route to the GitHub issues page; release ritual corrections.

## 1.0.0 — 2026-07-04

First public release.

- Everything from the 0.7.x line, verified end-to-end on a completely clean
  second machine: winget Python install, `.mcpb` drag-install into Claude
  Desktop, automated poller placement, full green `setup` chain.
- Install docs restructured as a numbered command crib sheet.
- `docs/RELEASING.md`: the maintainer's release ritual (version, tests,
  artifacts, publish branch, GitHub release).

## 0.7.1 — 2026-07-04

Sharing release.

- **One-click install**: `ge-mcp-<version>.mcpb` bundle — drag into Claude
  Desktop, optional settings UI (tool groups, game dir). Built by
  `scripts/build_mcpb.py`.
- **`setup(install_poller=true)`**: the server copies the in-editor poller
  into GIANTS Editor's scripts folder itself — the last manual file step, automated.
- **Fail fast when the editor is down**: `ping_editor` answers in ~5s, toolkit
  tools in ~8s (was: full 120s timeout) with exact next-step guidance; liveness
  is cached after the first success (no steady-state overhead).
- `mined_signatures.json` renamed **`known_functions.json`**; the shipped file
  carries facts only (signature/arity/call counts). A richer local-only
  variant (`known_functions.full.json`) is preferred automatically when present
  and is never included in releases.
- Docs: assume-nothing INSTALL (Python from scratch, uninstall, expanded
  troubleshooting), README "What can I ask it?" prompt guide.
- Published under MARVVV.

## 0.7.0 — 2026-07-04

The six roadmap build-out sessions, all live-tested on a real 90k-node map.
59 tools in 12 groups (from 36 in 7).

- **Session 1**: `backup_scene` (timestamped map+data copies); closed-spline
  area tools — `terrain_stats`, `paint_terrain_area`, `paint_foliage_area`,
  `terrain_flatten_area`; first starter snippets.
- **Session 2**: `field_ops` / `farmland_ops` / `info_layer_ops` portmanteaus —
  create game-ready fields from splines, ground/fruit painting via engine-side
  polygon rasterization, farmland ownership painting + audit, generic info
  layers. `setup` tool with FS25 game-dir auto-detection (editor.xml).
- **Session 3**: `spline_edit` (13 edit-point actions incl. drape, resample,
  split/join, parallel offset copies), `create_fence_line` (connected posts +
  gap-stretched panels), `align_to_terrain_normal`, `terrain_paint_by_slope`.
- **Session 4**: `audit_ops` (scene / file_refs with png↔dds resolution /
  textures / collisions / lights), `batch_ops` (rename, clean, array,
  distribute, snap, replace_asset), `i3d_query` (XPath).
- **Session 5**: `material_ops` (shader params with revert echo), `traffic_ops`
  (convention-relative direction validation), `camera_topdown` (ortho tiles,
  state-restoring), `camera_orbit`, `debug_view` (39 modes).
- **Session 6**: `asset_ops` ($data catalog: search/info/place), `mod_ops`
  (modDesc + placeable validation, fruit/fill types).
- `list_scripts`/`read_script` now cover the user scripts folder (`user:` prefix).
- README gallery with live-render demo shots.

## 0.6.0 — 2026-07-03

First packaged release ("Phase A" restructure).

- **Restructure**: single-file server split into the `ge_mcp` package
  (bridge / knowledge / validation / helpers / snippets / tools-by-group);
  `giants_mcp_server.py` remains as a compatibility shim, so existing MCP
  configs keep working. Lua moved to `lua/`. Pip-installable (`ge-mcp` entry point).
- **Snippet library** (new): `save_snippet` / `run_snippet` / `list_snippets` —
  proven `run_lua` scripts saved as JSON with typed params (injected as a Lua
  `ARGS` table), GE version and run/failure tracking. Unlimited snippets at the
  schema cost of three tools; `snippets/` packs are shareable files.
- **Group toggles**: `GE_MCP_GROUPS` env var picks which tool groups register.
- Docs: rewritten README, INSTALL, ARCHITECTURE (safety doctrine), generated
  TOOLS reference; MIT license; offline test suite + live regression script.

### Pre-package history (same day, previously unversioned)

- **v5.1**: terrain-height trio — `spline_align_terrain` gained `profile`
  (flat / u riverbed / v ditch) + `depth`; new `spline_adjust_terrain`
  (lower / raise / smooth relative to existing ground). Both two-phase
  (all reads before writes) after a live-verified vertex-aliasing compounding
  bug; relative lower/raise with identical args are inverses.
- **v5**: node lifecycle (`node_info`, `set_transform`, `node_props`,
  `create_group`, `safe_delete`, `reparent`, `randomize_transforms`),
  `import_i3d`, `camera_look`, `select_nodes`, `list_foliage_layers`
  (server-side XML parse), `save_scene` (Ctrl+S + ON_SAVE verification).
  `run_lua` validator false-positive on `word (` inside string literals fixed
  (single-pass scanner). Two native-crash surfaces neutralized
  (`getUserAttributeByIndex` removed; bounding spheres skip spline shapes).
- **v4**: spline toolkit (`list_splines`, `spline_info`, `spline_place_objects`,
  `spline_paint_terrain`, `spline_paint_foliage`, terrain align,
  `align_to_terrain`), scene inspection (`get_selection`, `get_scene_tree`,
  `find_nodes`), `viewport_screenshot` (engine render + OS window capture,
  returns images into chat), `read_log`. Injected helper library with
  version-sentinel auto-reinjection.
- **v3.x**: auto-pump poller (no Play button needed), editor event capture
  (selection via polling + engine hooks), editor-version auto-detection.
