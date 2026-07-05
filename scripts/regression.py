"""Live regression: exercise every tool read-only / preview-only against a
RUNNING GIANTS Editor. The gate after any restructure, before any new phase.

Run from the repo root with the editor open and the poller armed:
    python -u scripts/regression.py [spline-name]

Touches nothing permanently: write tools run with commit=false only, plus one
create->delete group cycle and one snippet save/run/cleanup. Terrain, foliage
and existing nodes are never modified.
"""

import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from ge_mcp import api as g  # noqa: E402
import ge_mcp.snippets as snip_lib  # noqa: E402

SPLINE = sys.argv[1] if len(sys.argv) > 1 else ""
FAILURES = []


def step(name, fn, *want_any):
    t0 = time.time()
    try:
        r = fn()
    except Exception as exc:
        print(f"  FAIL {name}: raised {exc!r}")
        FAILURES.append(name)
        return None
    txt = r if isinstance(r, str) else f"<{type(r).__name__}, {len(getattr(r, 'data', b''))} bytes>"
    if want_any:
        # explicit expectations win (a wanted [BLOCKED]/REFUSED is a pass)
        ok = any(w in txt for w in want_any)
    else:
        ok = not txt.startswith(("[ERROR]", "[BLOCKED]")) \
            and "Bridge not responding" not in txt and "No response within" not in txt
    print(f"  {'ok  ' if ok else 'FAIL'} {name}  ({time.time()-t0:.1f}s)  {txt.splitlines()[0][:90]}")
    if not ok:
        FAILURES.append(name)
    return txt


print("== core ==")
step("ping_editor", lambda: g.ping_editor(), "pong")
step("refresh_api", lambda: g.refresh_api(), "Loaded")
step("run_lua", lambda: g.run_lua("return tostring(2+2)"), "4")
step("run_lua blocked", lambda: g.run_lua("definitelyNotAFunction(1)"), "[BLOCKED]")
step("search_api", lambda: g.search_api("spline", 5), "documented")
step("api_signature", lambda: g.api_signature("clone"), "cloneId")
step("list_scripts", lambda: g.list_scripts("camera", 5))
step("read_script refuses escape", lambda: g.read_script("../secret.lua"), "Refused")
step("get_events", lambda: g.get_events(5))

print("== splines / scene inspection (read-only) ==")
splines_txt = step("list_splines", lambda: g.list_splines(SPLINE))
target = SPLINE
if not target and splines_txt:
    # listing rows look like "  [43602] name  len=..."; [OK]/[ERR] prefixes don't match \d
    m = re.search(r"^\s*\[(\d+)\]", splines_txt, re.M)
    if m:
        target = m.group(1)
if target:
    step("spline_info", lambda: g.spline_info(target), "length")
step("get_selection", lambda: g.get_selection(), "Selection")
step("get_scene_tree", lambda: g.get_scene_tree("", 1, 50))
step("find_nodes", lambda: g.find_nodes("a", 3))
step("node_info", lambda: g.node_info("terrain"))

print("== write tools, PREVIEW only ==")
if target:
    # source = the spline itself: preview only reads its name/rotation, writes nothing
    step("place preview", lambda: g.spline_place_objects(target, target, spacing=50), "PREVIEW")
    step("paint terrain preview", lambda: g.spline_paint_terrain(target, "0", commit=False), "PREVIEW")
    step("align terrain preview", lambda: g.spline_align_terrain(target, profile="u", depth=1.0), "PREVIEW")
    step("adjust terrain preview", lambda: g.spline_adjust_terrain(target, mode="lower"), "PREVIEW")
step("align_to_terrain preview", lambda: g.align_to_terrain("map", commit=False))
step("safe_delete preview refuses terrain", lambda: g.safe_delete("terrain"), "REFUSED")

print("== lifecycle (create -> mutate -> delete, self-cleaning) ==")
step("create_group", lambda: g.create_group("MCP_regress", x=0.0, y=300.0, z=0.0), "created")
step("set_transform", lambda: g.set_transform("MCP_regress", y=1.0, relative=True), "updated")
step("node_props", lambda: g.node_props("MCP_regress", name="MCP_regress2"), "renamed")
step("randomize preview", lambda: g.randomize_transforms("map", seed=1), "PREVIEW")
step("select_nodes", lambda: g.select_nodes("MCP_regress2"), "selected")
step("select clear", lambda: g.select_nodes(clear=True), "cleared")
step("safe_delete commit", lambda: g.safe_delete("MCP_regress2", commit=True), "deleted")
step("gone", lambda: g.find_nodes("MCP_regress", 3), "No nodes match")

print("== vision / logs / foliage ==")
step("read_log", lambda: g.read_log(5, "tail"), "log lines")
step("list_foliage_layers", lambda: g.list_foliage_layers(), "Foliage layers")
step("camera_look", lambda: g.camera_look("map"), "camera")
step("screenshot render", lambda: g.viewport_screenshot("render", 640, 360))
step("screenshot window", lambda: g.viewport_screenshot("window", 800, 450))

print("== v0.7 groups (read-only / preview; backup_scene excluded -- it copies the whole map) ==")
step("setup", lambda: g.setup(), "setup status")
if target:
    step("terrain_stats", lambda: g.terrain_stats(target, 4.0), "terrain stats")
    step("paint area preview", lambda: g.paint_terrain_area(target, "0"), "PREVIEW", "REFUSED")
    step("flatten preview", lambda: g.terrain_flatten_area(target), "PREVIEW", "REFUSED")
    step("slope paint preview", lambda: g.terrain_paint_by_slope(target, "0"), "PREVIEW", "REFUSED")
    step("spline_edit get_points", lambda: g.spline_edit("get_points", spline=target), "edit points")
    step("fence preview", lambda: g.create_fence_line(target, target, post_spacing=25.0), "PREVIEW")
step("field_ops list", lambda: g.field_ops("list"), "fields root", "no fields root")
step("farmland audit", lambda: g.farmland_ops("audit"), "audit", "farmlands")
step("info layers list", lambda: g.info_layer_ops("list"), "info layer")
step("audit scene", lambda: g.audit_ops("scene"), "scene audit")
step("audit file_refs", lambda: g.audit_ops("file_refs"), "file_refs audit")
step("audit collisions", lambda: g.audit_ops("collisions"), "collision audit")
step("traffic validate", lambda: g.traffic_ops("validate"), "traffic validation", "no node", "no splines")
step("material list (root)", lambda: g.material_ops("list", "map"), "material", "no mesh shapes")
step("normal align preview", lambda: g.align_to_terrain_normal("map"), "TILT")
step("asset categories", lambda: g.asset_ops("categories"), "i3d", "game dir")
step("mod desc", lambda: g.mod_ops("desc"), "mod", "modDesc")
step("i3d_query count", lambda: g.i3d_query(".//Files/File", count_only=True), "match(es)")
step("debug_view reset", lambda: g.debug_view("NONE"), "NONE")
step("camera_topdown", lambda: g.camera_topdown(0.0, 0.0, 200.0, width=512))

print("== snippets (save -> run -> cleanup) ==")
step("save_snippet", lambda: g.save_snippet(
    "regress-echo", "return 'echo ' .. tostring(ARGS.x)", "regression echo", "x=1"), "saved")
step("run_snippet", lambda: g.run_snippet("regress-echo", "x=42"), "echo 42")
step("list_snippets", lambda: g.list_snippets("regress"), "regress-echo")
(snip_lib.SNIPPETS_DIR / "regress-echo.json").unlink(missing_ok=True)
print("  ok   snippet cleanup")

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILURE(S): " + ", ".join(FAILURES))
    sys.exit(1)
print("REGRESSION PASSED — package matches pre-restructure behavior.")
