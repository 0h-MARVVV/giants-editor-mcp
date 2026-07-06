# Tool reference

Generated from ge-mcp 1.0.0 — do not edit by hand (run `python scripts/docgen.py`).
**60 tools** in 12 groups. Toggle groups with the `GE_MCP_GROUPS` env var.

## Group `assets` (3 tools)

Game-asset catalog ($data) and mod validation -- mostly disk-side.

### `asset_ops(action, query='', path='', x=0.0, z=0.0, y=None, parent='', name='', limit=40)`

Browse and place base-game assets from $data -- one tool, action-routed:

categories                 top-level $data folders with i3d counts
search (query, [limit])    find i3ds by path substring(s), space-separated
                           terms all must match (e.g. 'tree birch', 'fence')
info (path)                one i3d: root nodes, shape/light counts, files
place (path, x, z, [y], [parent], [name])   import into the scene at the
                           position (y defaults to terrain height) -- the
                           catalog-to-map pipeline in one call

`path` is $data-relative as returned by search. The catalog is cached per
session. NOTE: base-game trees use SPECIES names -- search 'betula' not
'birch', 'quercus'/'oak' both exist, 'pinus' for pines; try broad terms.

### `mod_ops(action, path='')`

Mod-level inspection and validation -- one tool, action-routed:

desc ([path])              parse modDesc.xml: title, author, version, maps,
                           store items (path = mod folder; default: the
                           open map's mod)
validate ([path])          modDesc sanity + every file it references vs
                           disk (icon, map config, store item XMLs)
placeable_validate (path)  one placeable XML: root/type, base i3d resolves,
                           storeData present, FS22-era elements that FS25
                           REMOVED (e.g. feedingTrough) flagged
fruit_types / fill_types   name lists from the game's maps config XMLs

Built from real FS22->FS25 conversion experience -- run validate before
zipping a mod, placeable_validate on converted placeables. For the full
set of VALID elements/attributes of any FS25 XML type, use xml_schema
(the game's own XSDs) rather than guessing.

### `xml_schema(action='list', name='', element='', depth=4, limit=120)`

The GROUND TRUTH for FS25 XML: the game's own schemas from <game>/shared/xml/schema (88 XSDs -- placeable, vehicle, fields, farmlands, foliageType, fillTypes, fence, ...). CONSULT THIS before writing or editing any FS25 XML instead of guessing element/attribute names. Actions:

list                 every schema file available
show (name)          element tree of one schema: every element with its
                     attributes, types, enums, required flags
show (name, element) just the subtree of elements whose name contains
                     `element` (use for huge schemas like vehicle)

Matching human-readable HTML lives in <game>/shared/xml/documentation.
Types shown are GIANTS' own (Float, Angle, 'String or l10n key', enums
listed inline). depth/limit cap the outline; refine with `element`.

## Group `core` (9 tools)

Core bridge tools: health, setup/diagnostics, arbitrary Lua, API knowledge, shipped scripts, events.

### `setup(game_dir='', install_poller=False)`

One-stop setup check: bridge, editor, game dir, helpers, snippets.

Call with no args to DIAGNOSE the whole chain (the first thing to run when
anything misbehaves, and the last step of installation). Pass game_dir to
SET the Farming Simulator 25 install path (needed for $data/... resolution:
foliage layer discovery, asset catalog) -- it is validated and persisted to
ge-mcp.config.json. Usually unnecessary: the path auto-detects from the
editor's own preferences (editor.xml).

install_poller=true copies lua/ge_mcp_poller.lua into the editor's scripts
folder so it appears in GE's Scripts menu -- the one manual file-copy of
the install, automated. (Re)start the editor afterwards and run
Scripts > GE-MCP Bridge once per session.

### `ping_editor()`

Check that the GIANTS Editor bridge is alive and answering (fast: ~5s max).

### `run_lua(code, force=False)`

Execute Lua inside the running GIANTS Editor and return its result.

Before running, every bare function the snippet calls is checked against what
is ACTUALLY callable in the editor -- its live _G globals plus the documented
bindings (and Lua builtins / locals the snippet defines). Unknown names are
REFUSED with the closest matches instead of executing. When unsure, look a
function up with search_api / api_signature, or read a shipped helper with
list_scripts / read_script, first.

Runs in the editor's global environment via loadstring; end the snippet with
`return <string>` to get text back (tables come back as "table: 0x.."; build
a string yourself). print() output goes to the editor log, not the return.

NOTE: no dry-run safety -- writes (setTranslation, delete, ...) apply
immediately. Read/preview first if a change is risky. If it works and is
worth keeping, save_snippet it.

force=true skips validation (e.g. for a freshly source()'d script whose
globals aren't in the live snapshot yet -- or call refresh_api to re-snapshot).

### `search_api(query, limit=25)`

Search the editor scripting API by keyword.

Returns documented functions WITH exact signatures (params:types -> outputs),
and also lists functions that exist in the live editor but aren't documented
(callable, no signature -- read a shipped script to learn their usage). This
is how to do anything without a dedicated tool: find the function, call it via
run_lua. Examples: search_api("light"), search_api("screenshot"), ("spline").

### `api_signature(name)`

Full signature + parameter docs for one documented API function (exact name).

### `refresh_api()`

Reload the documented spec AND re-snapshot the editor's live globals.

Call this if search says nothing is loaded (server started before the editor),
after updating the editor, or after source()'ing new scripts so their globals
show up.

### `list_scripts(query='', limit=100)`

List Lua scripts from BOTH the editor install and the user scripts folder.

editor: paths under the install (scripts/, shared/, tools/) -- the shipped
helpers. user: %LOCALAPPDATA%/GIANTS Editor .../scripts -- the community
panel scripts the modder actually uses; reading them is the best way to
learn proven engine-API patterns. Shows each file's header Name/Description
when present. Optional query filters by path/name/description. Use
read_script with the exact prefixed path shown here.

### `read_script(path, max_chars=20000)`

Read one Lua script (shipped or user) to learn its functions and usage.

`path` as shown by list_scripts: 'editor:scripts/camera/savebillboard.lua'
or 'user:Spline_Paint_Panel_25_UPDATED.lua'. An unprefixed path is tried
against the editor install first, then the user scripts folder. Read-only,
contained to those two directories. After learning the API, call the
functions via run_lua (or productize with save_snippet).

### `get_events(limit=50, since=0, clear=False)`

Recent editor events captured by the in-editor poller, oldest -> newest.

The poller registers listeners on the editor's hook system (scripts/Hooks.lua)
and keeps a ring buffer of what happens in the editor:
  SELECTION (node selected/deselected), SAVE, NODE_CLONED, NODE_DELETED,
  FILE_OPEN, FILE_IMPORTED.
Use this to OBSERVE what the user is doing in the editor and react, instead of
only acting when asked. Each event has a monotonic seq; poll incrementally with
`since` (return only seq > since). Requires the updated poller to be loaded.
NOTE: script-initiated delete() does not fire NODE_DELETED (UI deletes do).

limit  - max events returned (keeps the most recent if there are more).
since  - only return events whose seq > this value (incremental polling).
clear  - clear the buffer after reading.

## Group `fields` (3 tools)

Fields, farmlands and info layers -- the FS25 gameplay layer.

### `field_ops(action, field='', spline='', name='', fruit='', state=-1, value=-1, point_spacing=15.0, first_channel=0, num_channels=4, commit=False)`

Field management -- one tool, action-routed. Actions:

list                      every field: id, name, hectares, point count
info (field)              one field: area, centroid, farmland id, attributes
create_from_spline (spline, [name], [point_spacing])  closed spline -> a
                          game-ready field: polygonPoints at terrain height,
                          indicators, note, official user attributes
delete (field)            remove a field (preview -> commit)
set_ground (field, [value=2]) / clear_ground (field)  paint/clear the
                          terrainDetail ground state inside the polygon
set_fruit (field, fruit, state) / clear_fruit (field, fruit)  plant/remove
                          a crop (names+states from list_foliage_layers)
align_points (field)      drop all polygon points onto the terrain
rename (field, name)      rename + update the ha note

`field` accepts a field name/id or ANY node inside one. Ground/fruit writes
preview first (commit=true applies; engine-side polygon fill, one call).
Typical new-field flow: create_from_spline -> set_ground -> farmland_ops
paint_field -> set_fruit.

### `farmland_ops(action, field='', spline='', id=-1, x=0.0, z=0.0, commit=False)`

Farmland (ownership) management -- one tool, action-routed. Actions:

list                      farmland definitions from the map's farmlands.xml
                          (id, price factor, NPC) -- parsed on disk
id_at (x, z)              farmland id at a world position
field_id (field)          farmland id under a field's centroid
paint_field (field, id)   paint the field's polygon with a farmland id
paint_polygon (spline, id)  paint any closed-spline area with an id
audit                     every field: unowned land, duplicate farmland
                          assignments, name/id mismatches

Farmland ids live in the 'farmlands' info layer (bit-vector map). Paint
actions preview first. After painting, run audit to confirm consistency.

### `info_layer_ops(action, layer='', field='', spline='', value=-1, x=0.0, z=0.0, commit=False)`

Generic terrain INFO LAYER access (farmlands, indoorMask, placement/tip collision, fieldType, lime/plow/spray levels, ...). Actions:

list                      probe common layer names; show size + channels
read_at (layer, x, z)     value at a world position
paint_polygon (layer, value, field|spline)  fill a polygon with a value

Info layers drive GAME BEHAVIOR (collisions, placement rules, ground
condition) -- paint carefully, preview first, backup_scene when unsure.

## Group `hygiene` (3 tools)

Scene hygiene: audits (scene graph, file references, textures, collisions, lights) and batch operations (rename, clean, array, distribute, snap, replace).

### `audit_ops(action='scene')`

Map-quality audits -- one tool, action-routed. Actions:

scene       one walk over the scenegraph: node/class counts, empty transform
            groups (field structure excluded -- but locator/marker TGs are
            often intentional: REVIEW before clean_empty_groups), duplicate
            sibling names, nodes outside the map bounds, suspicious scales
file_refs   parse the map i3d's <Files> vs the DISK: missing i3ds/XMLs/
            textures -- catches broken references BEFORE the game does
textures    referenced texture files: missing + oversized (>8MB) + totals
collisions  rigid bodies whose collision mask is 0 (collide with nothing)
lights      every light source: range, visibility, large-range flags

All read-only. Start with 'scene' and 'file_refs' before packing a mod.

### `batch_ops(action, node='', pattern='', source='', prefix='', match='', start=1, mode='line', count=5, count_x=3, count_z=3, spacing=5.0, spacing_x=None, spacing_z=None, radius=10.0, step=1.0, terrain_snap=False, face_center=False, group_name='', limit=200, commit=False)`

Mechanical batch edits -- one tool, action-routed. Actions:

rename_pattern (node, prefix, [match], [start])   children -> prefix_1..N
clean_empty_groups ([node])       delete empty TGs (field structure excluded)
array_duplicate (node, mode=line|grid|circle, count/count_x/count_z,
                 spacing/spacing_x/spacing_z, radius, [terrain_snap],
                 [face_center])   clones into one undo-friendly group
distribute (node, [terrain_snap]) space children evenly first->last
snap_to_grid (node, step)         round children X/Z to a grid
replace_asset (pattern, source, [limit])  swap every node matching the name
                 pattern with clones of `source` (transforms kept, originals
                 DELETED; clones grouped)

Everything previews by default; commit=true applies. Deletions clear the
selection first (GE crash guard).

### `i3d_query(xpath, limit=40, count_only=False)`

Read-only XPath query into the OPEN map's i3d XML on disk (zero risk).

ElementTree XPath subset, e.g.:
  .//Files/File               every file reference
  .//Shape[@name='rock01']    shapes by attribute
  .//UserAttribute            all user attribute elements
  .//Light                    lights as saved in the file
Returns tag + attributes per match (or just the count). Reads the LAST
SAVED file -- unsaved editor changes are not in it.

## Group `materials` (1 tools)

Materials and shaders: inventory, shader parameters, material assignment.

### `material_ops(action, node, param='', source='', x=None, y=None, z=None, w=None, shared=False, recursive=True, commit=False)`

Material/shader work -- one tool, action-routed. Actions:

list (node)              unique materials across the subtree's mesh shapes:
                         material id, slot count, example shape, custom
                         shader file + variation
get_param (node, param)  read a shader parameter (e.g. 'colorScale') from
                         shapes under the node
set_param (node, param, x, [y, z, w], [shared], [recursive])  write it;
                         unset components keep their current value; old
                         values are echoed so you can revert by re-setting
assign_from (node, source)  put the source shape's material on every shape
                         slot under node (preview -> commit; old materials
                         are NOT recorded -- save/backup first)

shared=true edits the SHARED material (affects every user of it);
default false = per-shape instance where the engine supports it.

## Group `nodes` (13 tools)

Scenegraph inspection and node lifecycle: inspect, transform, rename, create, delete (safely), reparent, randomize, import, select.

### `get_selection()`

What is selected in the editor right now: ids, names, class, world pos, path.

### `get_scene_tree(node='', depth=3, max_nodes=400)`

Scene-graph outline: name [id] (class) +childCount, indented.

node: start point (id or name; empty = scene root). depth limits recursion,
max_nodes caps output size.

### `find_nodes(pattern, limit=60)`

Find scene nodes by name (case-insensitive substring): id, name, class, path.

### `node_info(node, bounds=False)`

Deep-inspect one node: class, path, world+local transform, rotation, scale, visibility, clip distance, rigid body type, child count and the onCreate attribute. bounds=true additionally walks the subtree's MESH shapes for a merged world bounding sphere (skips spline shapes).

### `set_transform(node, x=None, y=None, z=None, rx_deg=None, ry_deg=None, rz_deg=None, sx=None, sy=None, sz=None, uniform=False, relative=False)`

Set or nudge a node's WORLD position / rotation (degrees) / scale.

Only the components you pass are touched. relative=true adds to the current
values instead of replacing them (e.g. y=0.5, relative=true lifts by 0.5m).
uniform=true with just sx applies the same scale to all axes. The reply
includes the previous values, so any change can be undone by re-calling.
Refuses the scene root and terrain.

### `node_props(node, name='', visible=None, clip_distance=None, recursive=False)`

Rename a node and/or set visibility / clip distance.

recursive=true applies visibility/clip_distance to the whole subtree too
(classic map-optimization pass: set sane clip distances on deco groups).

### `create_group(name, parent='', x=None, y=None, z=None)`

Create an empty transform group (default under the scene root), optionally at a world position. Use as a staging container for placements/imports.

### `safe_delete(nodes, commit=False)`

Delete node(s) with the GE crash guards baked in.

nodes: comma-separated ids/names. The selection is cleared first (deleting a
SELECTED node crashes the editor), root/terrain/active camera are refused,
and every id is validity-checked. commit=false lists what would be deleted.

### `reparent(node, new_parent)`

Move a node to a new parent while PRESERVING its world pose.

Plain link() keeps local values (the node visibly jumps); this bakes world
translation/rotation and the scale product, re-applies them under the new
parent, verifies the result, and auto-reverts if the position drifted
(non-uniform parent scale). Warns when the new parent chain would shear.

### `randomize_transforms(node, yaw_jitter_deg=360.0, tilt_jitter_deg=0.0, scale_min=1.0, scale_max=1.0, y_jitter=0.0, seed=1234, commit=False)`

Naturalize a group's children: random yaw (default full circle), optional tilt, uniform scale range and vertical jitter. The classic pass after placing trees/rocks so clones don't look stamped. Seeded: preview shows exactly what commit applies.

### `import_i3d(path, parent='', name='', x=None, y=None, z=None)`

Load an .i3d asset file into the scene (loadI3DFile + link).

path: absolute path or $data/... game path. Links the loaded root under
`parent` (default scene root), optionally renames and positions it. Returns
the new root id + its direct children.

### `select_nodes(nodes='', clear=False)`

Set the editor's selection to the given comma-separated ids/names (or clear=true to deselect everything). Useful to show the user a result or to stage a manual editor operation.

### `align_to_terrain_normal(node, children=True, max_tilt_deg=30.0, sample_dist=1.0, commit=False)`

Pitch/roll node(s) to match the terrain SLOPE under them -- rocks, stumps, props, small sheds that should sit flush on a hillside (complement of align_to_terrain, which only fixes height).

Heading (yaw) and scale are preserved; tilt is capped at max_tilt_deg so
steep slopes don't flip things over. children=true tilts each direct child
of a group. commit=false lists the tilt each node would get.

## Group `scene` (2 tools)

Scene-level operations: saving, on-disk backups (and, in future sessions, audits).

### `save_scene(timeout_s=45)`

Save the scene: focuses the GIANTS Editor window, sends Ctrl+S, then waits for the editor's ON_SAVE event to confirm the save actually happened.

There is NO scriptable save binding, so this briefly steals window focus.
If no SAVE event arrives (e.g. a modal dialog was open), it says so --
verify manually in that case. Use after any committed paint/terrain work
(crash = unsaved work lost).

### `backup_scene(note='', include_data=True)`

Timestamped on-disk backup of the open map -- the crash insurance.

Copies map.i3d, its sibling cache files, and (by default) the maps data/
folder (DEM, density/weight maps -- everything terrain and foliage paints
touch) to map_backups/<mod>-<timestamp>[-note]/ next to this package
(override location with a "backup_dir" key in ge-mcp.config.json).

Backs up the files as LAST SAVED: run save_scene first to snapshot current
edits -- the report shows how stale the last save is. Restore = close the
map in GE, copy the backed-up files over the originals, reopen.

## Group `snippets` (3 tools)

The snippet library: save proven run_lua scripts once, replay them forever.

### `save_snippet(name, lua, description='', params='', overwrite=False)`

Save a Lua script that just proved itself, for cheap replay via run_snippet.

name: 2-64 chars, a-z 0-9 _ - (e.g. 'select-high-clip-nodes').
description: one line -- what it does and returns (shown by list_snippets).
params: comma spec of the ARGS the script reads, defaults optional --
e.g. 'width=3.0, layer=decoBush, count' (bare name = required). The script
accesses them as ARGS.width etc.; run_snippet injects `local ARGS = {...}`.
Records the GE version and tracks run/failure counts. Save deliberately:
scripts that worked and will plausibly be wanted again -- not one-off probes.

### `run_snippet(name, args='')`

Run a saved snippet by name. args: 'width=5, layer=decoBush' or a JSON object; merged over the snippet's declared defaults (missing required args are refused). Bypasses the run_lua validator (the script was validated when saved); failures are recorded and flagged in list_snippets.

### `list_snippets(query='')`

List saved snippets: name(params) -- description [run stats].

Check here BEFORE composing fresh Lua for a familiar-sounding task.
Optional query filters name+description (case-insensitive).

## Group `splines` (5 tools)

Spline discovery and object placement.

### `list_splines(query='')`

List every spline in the scene: id, name, length, CV count, closed flag, path.

Optional query filters by name (case-insensitive substring). Start here to
find the spline to feed into the other spline_* tools (by id or name).

### `spline_info(spline)`

Details for one spline: length, CVs, closed, endpoints, bbox, curvature, attributes.

`spline` is a node id or a name (exact, then case-insensitive substring);
a transform group containing a spline also works.

### `spline_place_objects(spline, source, spacing=5.0, count=0, lateral=0.0, lateral_jitter=0.0, yaw_mode='spline', yaw_jitter_deg=0.0, yaw_add_deg=0.0, terrain_snap=True, y_offset=0.0, seed=1234, group_name='', commit=False, max_count=2000)`

Clone `source` along `spline` -- fences, trees, poles, rocks, lamps, etc.

Placement is DETERMINISTIC for a given seed: call with commit=false (default)
to preview count/positions, then the same args with commit=true to place
exactly that. Clones go into a fresh transform group under the scene root
(named group_name or auto) so one delete undoes the whole placement.

spacing: meters between clones (arc-length). count>=2 overrides spacing to
fit exactly that many. lateral: signed sideways offset from the spline
(+left); lateral_jitter: random extra sideways spread (+-meters).
yaw_mode: 'spline' = face along the spline tangent, 'keep' = source's
rotation, 'random' = random yaw. yaw_add_deg compensates assets modeled
facing sideways; yaw_jitter_deg adds random variation. terrain_snap drops
each clone to terrain height (y_offset applies after). Source pitch/roll are
preserved in world space, so flipped-axis assets stay face-up.
Prefer LEAF meshes as source, not big prefab groups (a warning appears).

### `spline_edit(action, spline='', spline2='', points='', name='', index=-1, x=None, y=None, z=None, dx=0.0, dy=0.0, dz=0.0, mode='drape', value=None, y_offset=0.0, iterations=2, spacing=10.0, offset=0.0, t=0.0, closed=None, linear=False)`

Spline editing -- one tool, action-routed. Actions:

get_points (spline)                dump the edit points (0-based indices)
create_from_points (points, [name], [closed], [linear])  'x,y,z; x,y,z; ...'
                                   or 'x,z; x,z; ...' (y from terrain)
move_point (spline, index, x/y/z or dx/dy/dz)   nudge one point in place
add_point (spline, x, z, [y], [index])          insert after index (default end)
delete_point (spline, index)
set_heights (spline, mode=drape|constant|smooth, [value], [y_offset], [iterations])
                                   drape onto terrain / flatten / relax bumps
resample (spline, spacing)         rebuild with evenly spaced points
reverse (spline)                   flip direction (traffic/AI splines care)
set_closed (spline, closed)        open <-> closed loop
split_at (spline, t)               one spline -> _part1 + _part2 at t (0..1)
join (spline, spline2)             new _joined spline; originals kept
offset_copy (spline, offset, [spacing])  parallel copy offset m to the left
                                   (negative = right) -- lanes, verges, fence runs
attributes (spline)                list spline attribute names

Edits work on EDIT POINTS. Structural actions REBUILD the spline -- the
NODE ID CHANGES and is reported; move_point/set_heights keep the id.

### `create_fence_line(spline, post_source, panel_source='', post_spacing=2.5, panel_length=0.0, terrain_snap=True, y_offset=0.0, post_yaw_add_deg=0.0, panel_yaw_add_deg=0.0, group_name='', commit=False, max_count=1500)`

Build a CONNECTED fence along a spline: posts at exact spacing, panels stretched to fill each gap precisely (scaled on their length axis, pitched to follow the slope). Unlike spline_place_objects (scatter), the segments meet: fences, guard rails, walls, hedgerow runs, power lines w/o sag.

post_source / panel_source: nodes to clone (panel optional = posts only).
panel_length: the panel asset's natural length in meters -- pass it for an
exact fit (otherwise estimated from bounds with a warning). Everything goes
into one group; delete it to undo. Preview first (commit=false default).

## Group `terrain` (11 tools)

Everything that writes the terrain: texture paint, foliage paint, height shaping (absolute + relative), plus foliage layer discovery.

### `spline_paint_terrain(spline, layer, width=4.0, offset=0.0, edge_layer='', edge_width=2.0, step_across=0.5, step_along=0.0, commit=False, max_ops=400000)`

Paint a terrain TEXTURE layer in a band along a spline (roads, paths, verges).

layer / edge_layer: terrain layer name or index (unknown names list the
available layers). width: centre band in meters; edge_layer+edge_width add a
shoulder texture each side. offset shifts the whole band sideways (+left).
The along-spline step adapts to curvature so tight bends have no gaps.
commit=false (default) previews the op count; commit=true paints.
NO scripted undo -- save first if unsure.

### `spline_paint_foliage(spline, layer, state, width=3.0, offset=0.0, spacing=0.5, lateral_jitter=0.0, state_min=-1, state_max=-1, seed=1234, from_t=0.0, to_t=1.0, first_channel=0, num_channels=4, commit=False, max_ops=20000)`

Paint a FOLIAGE layer band along a spline via DensityMapModifier (grass, bushes).

layer: exact foliage layer name from the map's FoliageSystem -- discover names
AND state meanings with list_foliage_layers. state: the value to write.
width: band width in meters; spacing: distance between paint steps along the
spline (lower to ~0.25 if coverage looks striped). state_min/state_max >=0
randomize the state per step. Long splines: paint in chunks with from_t/to_t
(heavy executeSet loops in one call have crashed GE before -- the max_ops cap
refuses oversized jobs). commit=false previews. NO scripted undo -- save first.

### `spline_align_terrain(spline, width=6.0, edge_width=4.0, y_offset=0.0, offset=0.0, step=0.5, profile='flat', depth=0.0, commit=False, max_ops=400000)`

Shape the terrain to follow a spline's HEIGHT -- road beds, riverbeds, ditches.

profile='flat' (default): classic road bed -- the core band (width m) takes the
spline's own Y (+y_offset). profile='u' + depth: RIVERBED -- a cosine bowl
`depth` meters deep at the centerline rising to the spline's Y at the band
edge; draw the spline at the intended WATERLINE and the bed is carved below
it. profile='v' + depth: ditch/creek V-cut. In all profiles the edge band
(edge_width each side) blends back into the existing terrain.
For quick carving relative to the current ground instead (no careful spline
heights needed), use spline_adjust_terrain.
commit=false previews the op count. NO scripted undo -- save first.

### `spline_adjust_terrain(spline, mode='lower', depth=1.5, strength=0.5, width=6.0, edge_width=4.0, offset=0.0, step=0.5, radius=0.0, commit=False, max_ops=400000)`

Adjust terrain RELATIVE to the existing ground along a spline.

mode='lower': dig `depth` meters down along the path -- the quick way to carve
a river/creek without drawing the spline at careful heights (the bed follows
the landscape). mode='raise': levee/berm/dam. mode='smooth': relax each cell
toward its neighbours (soften jagged banks; strength 0..1, radius = sample
distance, default 3*step). Full effect across `width`, cosine falloff over
`edge_width` each side. Cells are deduped per call so bends/overlaps do not
compound -- which also means lower and raise with IDENTICAL args undo each
other (aside from heightmap quantization).
commit=false previews. NO scripted undo beyond that inverse trick -- save first.

### `align_to_terrain(node, children=True, y_offset=0.0, commit=False)`

Drop node(s) onto the terrain surface (fix floating/buried trees, props).

node: id or name. children=true (default) moves each DIRECT CHILD of the node
(the usual case: a transform group full of trees); children=false moves the
node itself. Only Y changes; rotation/scale untouched. commit=false lists
what would move and by how much.

### `list_foliage_layers()`

Foliage layer names + their paintable states for the OPEN map, parsed from the map i3d + foliage XMLs on disk (no editor round-trips).

Use before spline_paint_foliage: it gives the exact layer name and the
meaning of each state value (state 0 always = remove). $data foliage XMLs
resolve via the game dir (auto-detected from the editor's preferences;
check/override with the setup tool).

### `terrain_stats(spline, step=2.0)`

Read-only stats for the area inside a CLOSED spline: area (m2/ha), height min/max/avg/range, slope avg/max, bbox.

Draw a closed spline around any area (an open spline is auto-closed
end-to-start) and get the numbers before deciding to flatten/paint. Also the
quick way to measure a field's real hectares. step: sample grid in meters.

### `paint_terrain_area(spline, layer, step=0.5, commit=False, max_ops=600000)`

Fill the area inside a CLOSED spline with a terrain TEXTURE layer.

The polygon-fill counterpart of spline_paint_terrain (which paints bands
along the spline): scanline fill of the enclosed area -- fields, yards,
meadows, parking lots. layer: name or index (unknown names list all layers).
Open splines are auto-closed end-to-start. commit=false previews area + op
count. NO scripted undo -- backup_scene first if unsure.

### `paint_foliage_area(spline, layer, state, row_step=0.5, first_channel=0, num_channels=4, commit=False, max_ops=20000)`

Fill the area inside a CLOSED spline with a FOLIAGE layer state (grass a meadow, bushes a thicket) -- or CLEAR foliage with state=0.

Uses one DensityMapModifier rectangle strip per scanline row, so even a
multi-hectare field stays well under the op cap. layer/state: see
list_foliage_layers. Open splines are auto-closed. commit=false previews.
NO scripted undo -- backup_scene first if unsure.

### `terrain_flatten_area(spline, height=None, height_mode='avg', step=0.5, commit=False, max_ops=600000)`

Flatten the area inside a CLOSED spline to one height -- building pads, yards, silo platforms.

height: explicit target, or omit it and height_mode picks from the boundary:
'avg' (default), 'min', 'max'. Edges are SHARP by design -- run
spline_adjust_terrain mode=smooth on the same spline afterwards to blend the
rim into the surroundings. commit=false previews. NO scripted undo --
backup_scene first if unsure.

### `terrain_paint_by_slope(spline, layer, min_slope_deg=20.0, max_slope_deg=90.0, step=1.0, commit=False, max_ops=600000)`

Auto-texture by STEEPNESS inside a closed spline: paint `layer` on every cell whose slope falls in [min_slope_deg, max_slope_deg] -- rock faces on cliffs, scree on banks, worn ground on steep tracks.

Draw a rough closed spline around the region (it only bounds the scan);
the slope test picks the actual cells. commit=false previews the scan size.
NO scripted undo -- backup_scene first if unsure.

## Group `traffic` (1 tools)

Traffic / AI spline validation (read-only).

### `traffic_ops(action='validate', node='traffsplines', gap_tolerance=1.0)`

Traffic-spline checks -- read-only. Actions:

list      every spline under the traffic root: length, closed flag
validate  left/right pairing (missing partners), length mismatches >15%,
          direction DEVIANTS (the map's own majority pair-direction
          convention is detected first; only pairs that break it are
          flagged), and open endpoints with no other endpoint within
          gap_tolerance meters (dead ends that break AI traffic chains)

node: the traffic root (default 'traffsplines'). Splines that fail these
checks are the classic causes of in-game traffic vanishing or jamming.

## Group `vision` (6 tools)

See the editor: screenshots (engine render or OS window capture), camera control, and the editor log (where print() and script errors go).

### `viewport_screenshot(mode='window', width=1280, height=720)`

Grab an image of the GIANTS Editor so Claude can SEE the scene.

mode='window' (default): OS capture of the whole editor window -- shows
everything the user sees, INCLUDING splines, gizmos, selection outlines and
UI panels. The window must be visible on screen (not minimized).
mode='render': the engine's own renderScreenshot of the active camera --
clean meshes/terrain only (NO splines or UI), works even with the editor in
the background, and honors the requested width/height.

### `camera_look(target='', x=None, y=None, z=None, distance=0.0, yaw_deg=45.0, pitch_deg=35.0)`

Aim the active viewport camera at a node (by id/name) or world position, then take a viewport_screenshot to actually see it.

distance<=0 auto-frames from the target's bounding sphere. yaw_deg is the
compass direction the camera sits at, pitch_deg the down-angle.

### `camera_topdown(x, z, size=200.0, height=400.0, width=1024)`

Orthographic TOP-DOWN render of an area -- a minimap tile on demand.

Frames `size` meters (north up) centered on (x, z), renders, then restores
the camera exactly as it was (position, rotation, FOV, projection). Great
for checking paint coverage, field shapes, road layouts from above.

### `camera_orbit(target, shots=4, distance=0.0, pitch_deg=35.0, width=800)`

Orbit a node and return one render per angle -- see something from all sides in a single call. shots=4 -> N/E/S/W views. distance<=0 auto-frames. The camera stays at the last angle (use camera_look to reframe).

### `debug_view(mode='NONE')`

Switch the viewport's DEBUG RENDER mode, then screenshot to see it.

Handy modes: TERRAIN_SLOPES (steepness heatmap), MESH_LOD, TRIANGLE_DENSITY,
DRAWCALLS, SHADOW_CASTERS, NORMALS, ALBEDO ... 39 total (bad mode lists them).
Affects the live viewport -- ALWAYS debug_view NONE afterwards.

### `read_log(lines=60, mode='new')`

Read the editor's log (editor_log.txt) -- where print() output and native 'Script error in X' lines actually go.

mode='new' (default): only lines appended since the previous read_log call
(first call behaves like tail). mode='tail': last `lines` lines regardless.
mode='errors': last `lines` lines matching error/warning patterns.
