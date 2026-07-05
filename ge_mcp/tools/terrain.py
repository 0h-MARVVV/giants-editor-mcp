"""Everything that writes the terrain: texture paint, foliage paint, height
shaping (absolute + relative), plus foliage layer discovery.

All write tools default to commit=false previews with op estimates, refuse
oversized jobs via max_ops, and the height tools are two-phase (all reads
before any write -- heightmap-vertex aliasing compounds otherwise).
"""

import xml.etree.ElementTree as ET
from pathlib import Path

from .. import config
from ..bridge import bridge
from ..helpers import call_helper, int_or_str


def spline_paint_terrain(spline: str, layer: str, width: float = 4.0, offset: float = 0.0,
                         edge_layer: str = "", edge_width: float = 2.0,
                         step_across: float = 0.5, step_along: float = 0.0,
                         commit: bool = False, max_ops: int = 400000) -> str:
    """Paint a terrain TEXTURE layer in a band along a spline (roads, paths, verges).

    layer / edge_layer: terrain layer name or index (unknown names list the
    available layers). width: centre band in meters; edge_layer+edge_width add a
    shoulder texture each side. offset shifts the whole band sideways (+left).
    The along-spline step adapts to curvature so tight bends have no gaps.
    commit=false (default) previews the op count; commit=true paints.
    NO scripted undo -- save first if unsure.
    """
    return call_helper("paintTerrain", {
        "spline": int_or_str(spline), "layer": int_or_str(layer),
        "width": width, "offset": offset,
        "edgeLayer": int_or_str(edge_layer) if edge_layer else None,
        "edgeWidth": edge_width, "stepAcross": step_across,
        "stepAlong": step_along if step_along > 0 else None,
        "commit": commit, "maxOps": max_ops,
    }, timeout=300.0)


def spline_paint_foliage(spline: str, layer: str, state: int, width: float = 3.0,
                         offset: float = 0.0, spacing: float = 0.5,
                         lateral_jitter: float = 0.0, state_min: int = -1, state_max: int = -1,
                         seed: int = 1234, from_t: float = 0.0, to_t: float = 1.0,
                         first_channel: int = 0, num_channels: int = 4,
                         commit: bool = False, max_ops: int = 20000) -> str:
    """Paint a FOLIAGE layer band along a spline via DensityMapModifier (grass, bushes).

    layer: exact foliage layer name from the map's FoliageSystem -- discover names
    AND state meanings with list_foliage_layers. state: the value to write.
    width: band width in meters; spacing: distance between paint steps along the
    spline (lower to ~0.25 if coverage looks striped). state_min/state_max >=0
    randomize the state per step. Long splines: paint in chunks with from_t/to_t
    (heavy executeSet loops in one call have crashed GE before -- the max_ops cap
    refuses oversized jobs). commit=false previews. NO scripted undo -- save first.
    """
    return call_helper("paintFoliage", {
        "spline": int_or_str(spline), "layer": layer, "state": state,
        "width": width, "offset": offset, "spacing": spacing,
        "lateralJitter": lateral_jitter,
        "stateMin": state_min if state_min >= 0 else None,
        "stateMax": state_max if state_max >= 0 else None,
        "seed": seed, "fromT": from_t, "toT": to_t,
        "firstChannel": first_channel, "numChannels": num_channels,
        "commit": commit, "maxOps": max_ops,
    }, timeout=300.0)


def spline_align_terrain(spline: str, width: float = 6.0, edge_width: float = 4.0,
                         y_offset: float = 0.0, offset: float = 0.0, step: float = 0.5,
                         profile: str = "flat", depth: float = 0.0,
                         commit: bool = False, max_ops: int = 400000) -> str:
    """Shape the terrain to follow a spline's HEIGHT -- road beds, riverbeds, ditches.

    profile='flat' (default): classic road bed -- the core band (width m) takes the
    spline's own Y (+y_offset). profile='u' + depth: RIVERBED -- a cosine bowl
    `depth` meters deep at the centerline rising to the spline's Y at the band
    edge; draw the spline at the intended WATERLINE and the bed is carved below
    it. profile='v' + depth: ditch/creek V-cut. In all profiles the edge band
    (edge_width each side) blends back into the existing terrain.
    For quick carving relative to the current ground instead (no careful spline
    heights needed), use spline_adjust_terrain.
    commit=false previews the op count. NO scripted undo -- save first.
    """
    return call_helper("alignTerrainToSpline", {
        "spline": int_or_str(spline), "width": width, "edgeWidth": edge_width,
        "yOffset": y_offset, "offset": offset, "step": step,
        "profile": profile, "depth": depth,
        "commit": commit, "maxOps": max_ops,
    }, timeout=300.0)


def spline_adjust_terrain(spline: str, mode: str = "lower", depth: float = 1.5,
                          strength: float = 0.5, width: float = 6.0,
                          edge_width: float = 4.0, offset: float = 0.0,
                          step: float = 0.5, radius: float = 0.0,
                          commit: bool = False, max_ops: int = 400000) -> str:
    """Adjust terrain RELATIVE to the existing ground along a spline.

    mode='lower': dig `depth` meters down along the path -- the quick way to carve
    a river/creek without drawing the spline at careful heights (the bed follows
    the landscape). mode='raise': levee/berm/dam. mode='smooth': relax each cell
    toward its neighbours (soften jagged banks; strength 0..1, radius = sample
    distance, default 3*step). Full effect across `width`, cosine falloff over
    `edge_width` each side. Cells are deduped per call so bends/overlaps do not
    compound -- which also means lower and raise with IDENTICAL args undo each
    other (aside from heightmap quantization).
    commit=false previews. NO scripted undo beyond that inverse trick -- save first.
    """
    return call_helper("adjustTerrainAlongSpline", {
        "spline": int_or_str(spline), "mode": mode, "depth": depth,
        "strength": strength, "width": width, "edgeWidth": edge_width,
        "offset": offset, "step": step, "radius": radius if radius > 0 else None,
        "commit": commit, "maxOps": max_ops,
    }, timeout=300.0)


def align_to_terrain(node: str, children: bool = True, y_offset: float = 0.0,
                     commit: bool = False) -> str:
    """Drop node(s) onto the terrain surface (fix floating/buried trees, props).

    node: id or name. children=true (default) moves each DIRECT CHILD of the node
    (the usual case: a transform group full of trees); children=false moves the
    node itself. Only Y changes; rotation/scale untouched. commit=false lists
    what would move and by how much.
    """
    return call_helper("alignToTerrain", {
        "node": int_or_str(node), "children": children,
        "yOffset": y_offset, "commit": commit,
    })


# ---- closed-spline polygon area tools (v7) --------------------------------------
_call = call_helper            # (fn, args, timeout=...) -- shorthand for this section
_i = int_or_str


def terrain_stats(spline: str, step: float = 2.0) -> str:
    """Read-only stats for the area inside a CLOSED spline: area (m2/ha), height
    min/max/avg/range, slope avg/max, bbox.

    Draw a closed spline around any area (an open spline is auto-closed
    end-to-start) and get the numbers before deciding to flatten/paint. Also the
    quick way to measure a field's real hectares. step: sample grid in meters.
    """
    return _call("terrainStats", {"spline": _i(spline), "step": step}, 300.0)


def paint_terrain_area(spline: str, layer: str, step: float = 0.5,
                       commit: bool = False, max_ops: int = 600000) -> str:
    """Fill the area inside a CLOSED spline with a terrain TEXTURE layer.

    The polygon-fill counterpart of spline_paint_terrain (which paints bands
    along the spline): scanline fill of the enclosed area -- fields, yards,
    meadows, parking lots. layer: name or index (unknown names list all layers).
    Open splines are auto-closed end-to-start. commit=false previews area + op
    count. NO scripted undo -- backup_scene first if unsure.
    """
    return _call("paintTerrainArea", {
        "spline": _i(spline), "layer": _i(layer), "step": step,
        "commit": commit, "maxOps": max_ops,
    }, 600.0)


def paint_foliage_area(spline: str, layer: str, state: int, row_step: float = 0.5,
                       first_channel: int = 0, num_channels: int = 4,
                       commit: bool = False, max_ops: int = 20000) -> str:
    """Fill the area inside a CLOSED spline with a FOLIAGE layer state
    (grass a meadow, bushes a thicket) -- or CLEAR foliage with state=0.

    Uses one DensityMapModifier rectangle strip per scanline row, so even a
    multi-hectare field stays well under the op cap. layer/state: see
    list_foliage_layers. Open splines are auto-closed. commit=false previews.
    NO scripted undo -- backup_scene first if unsure.
    """
    return _call("paintFoliageArea", {
        "spline": _i(spline), "layer": layer, "state": state, "rowStep": row_step,
        "firstChannel": first_channel, "numChannels": num_channels,
        "commit": commit, "maxOps": max_ops,
    }, 600.0)


def terrain_flatten_area(spline: str, height: float = None, height_mode: str = "avg",
                         step: float = 0.5, commit: bool = False,
                         max_ops: int = 600000) -> str:
    """Flatten the area inside a CLOSED spline to one height -- building pads,
    yards, silo platforms.

    height: explicit target, or omit it and height_mode picks from the boundary:
    'avg' (default), 'min', 'max'. Edges are SHARP by design -- run
    spline_adjust_terrain mode=smooth on the same spline afterwards to blend the
    rim into the surroundings. commit=false previews. NO scripted undo --
    backup_scene first if unsure.
    """
    return _call("flattenArea", {
        "spline": _i(spline), "height": height, "heightMode": height_mode,
        "step": step, "commit": commit, "maxOps": max_ops,
    }, 600.0)


# ---- foliage layer discovery (server-side XML parse, no editor round-trips) -----
_FOLIAGE_CACHE = {}


def _resolve_map_path(raw, map_dir):
    raw = (raw or "").replace("\\", "/")
    if raw.startswith("$data/"):
        gd, _src = config.game_dir()   # env var / saved config / editor.xml / probes
        if gd is None:
            return None
        p = gd / "data" / raw[len("$data/"):]
        return p if p.is_file() else None
    p = (map_dir / raw).resolve()
    return p if p.is_file() else None


def list_foliage_layers() -> str:
    """Foliage layer names + their paintable states for the OPEN map, parsed from
    the map i3d + foliage XMLs on disk (no editor round-trips).

    Use before spline_paint_foliage: it gives the exact layer name and the
    meaning of each state value (state 0 always = remove). $data foliage XMLs
    resolve via the game dir (auto-detected from the editor's preferences;
    check/override with the setup tool)."""
    r = bridge("return getSceneFilename()", timeout=6.0)
    if not r["ok"] or not (r["result"] or "").strip():
        return "Could not get the scene filename from the editor.\n" + r["result"]
    scene = Path(r["result"].strip())
    if not scene.is_file():
        return "Scene file not found on disk: " + str(scene)
    cache_key = (str(scene), scene.stat().st_mtime)
    if cache_key in _FOLIAGE_CACHE:
        return _FOLIAGE_CACHE[cache_key]
    try:
        root = ET.parse(scene).getroot()
    except Exception as exc:
        return "Failed to parse map i3d: " + str(exc)
    files = {f.get("fileId"): f.get("filename") for f in root.findall(".//Files/File")}
    out = []
    for ml_i, ml in enumerate(root.findall(".//FoliageMultiLayer")):
        for ft in ml.findall("FoliageType"):
            nm = ft.get("name") or "?"
            fxml = _resolve_map_path(files.get(ft.get("foliageXmlId")), scene.parent)
            states, extra = [], ""
            if fxml is not None:
                try:
                    froot = ET.parse(fxml).getroot()
                    layers = froot.findall("foliageLayer")
                    if layers:
                        states = [fs.get("name") or "?" for fs in layers[0].findall("foliageState")]
                        if len(layers) > 1:
                            extra = "  (+" + str(len(layers) - 1) + " extra layer(s), e.g. haulm)"
                except Exception:
                    extra = "  (foliage xml unreadable)"
            else:
                extra = "  (foliage xml not resolved -- set GE_GAME_DIR for $data paths)"
            if states:
                srt = ", ".join(str(i + 1) + "=" + s for i, s in enumerate(states))
                out.append("  " + nm + "  [multiLayer " + str(ml_i) + "]: 0=remove, " + srt + extra)
            else:
                out.append("  " + nm + "  [multiLayer " + str(ml_i) + "]: states unknown" + extra)
    if not out:
        return "No FoliageMultiLayer entries found in " + scene.name
    result = ("Foliage layers in " + scene.name + " (use the name + a state value with "
              "spline_paint_foliage):\n" + "\n".join(out))
    _FOLIAGE_CACHE[cache_key] = result
    return result


def terrain_paint_by_slope(spline: str, layer: str, min_slope_deg: float = 20.0,
                           max_slope_deg: float = 90.0, step: float = 1.0,
                           commit: bool = False, max_ops: int = 600000) -> str:
    """Auto-texture by STEEPNESS inside a closed spline: paint `layer` on every
    cell whose slope falls in [min_slope_deg, max_slope_deg] -- rock faces on
    cliffs, scree on banks, worn ground on steep tracks.

    Draw a rough closed spline around the region (it only bounds the scan);
    the slope test picks the actual cells. commit=false previews the scan size.
    NO scripted undo -- backup_scene first if unsure.
    """
    return _call("paintBySlope", {
        "spline": _i(spline), "layer": _i(layer),
        "minSlopeDeg": min_slope_deg, "maxSlopeDeg": max_slope_deg,
        "step": step, "commit": commit, "maxOps": max_ops,
    }, 600.0)


TOOLS = [spline_paint_terrain, spline_paint_foliage, spline_align_terrain,
         spline_adjust_terrain, align_to_terrain, list_foliage_layers,
         terrain_stats, paint_terrain_area, paint_foliage_area, terrain_flatten_area,
         terrain_paint_by_slope]


def register(mcp):
    for fn in TOOLS:
        mcp.tool()(fn)
