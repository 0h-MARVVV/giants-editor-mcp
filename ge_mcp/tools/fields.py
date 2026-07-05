"""Fields, farmlands and info layers -- the FS25 gameplay layer.

Portmanteau tools (one schema, many actions) wrapping the official
MapToolkitField patterns: field node structure (polygonPoints + indicators +
user attributes), engine-side polygon rasterization via DensityMapModifier
addPolygonPointWorldCoords, and the farmlands/info-layer bit-vector maps.
"""

import xml.etree.ElementTree as ET
from pathlib import Path

from ..bridge import bridge
from ..helpers import call_helper, int_or_str


def field_ops(action: str, field: str = "", spline: str = "", name: str = "",
              fruit: str = "", state: int = -1, value: int = -1,
              point_spacing: float = 15.0, first_channel: int = 0,
              num_channels: int = 4, commit: bool = False) -> str:
    """Field management -- one tool, action-routed. Actions:

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
    """
    return call_helper("fieldOps", {
        "action": action, "field": _f(field), "spline": _f(spline),
        "name": name or None, "fruit": fruit or None,
        "state": state if state >= 0 else None,
        "value": value if value >= 0 else None,
        "pointSpacing": point_spacing, "firstChannel": first_channel,
        "numChannels": num_channels, "commit": commit,
    }, timeout=300.0)


def farmland_ops(action: str, field: str = "", spline: str = "", id: int = -1,
                 x: float = 0.0, z: float = 0.0, commit: bool = False) -> str:
    """Farmland (ownership) management -- one tool, action-routed. Actions:

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
    """
    if action == "list":
        return _farmlands_xml_list()
    return call_helper("farmlandOps", {
        "action": action, "field": _f(field), "spline": _f(spline),
        "id": id if id >= 0 else None,
        "x": x if action == "id_at" else None,
        "z": z if action == "id_at" else None,
        "commit": commit,
    }, timeout=300.0)


def info_layer_ops(action: str, layer: str = "", field: str = "", spline: str = "",
                   value: int = -1, x: float = 0.0, z: float = 0.0,
                   commit: bool = False) -> str:
    """Generic terrain INFO LAYER access (farmlands, indoorMask, placement/tip
    collision, fieldType, lime/plow/spray levels, ...). Actions:

    list                      probe common layer names; show size + channels
    read_at (layer, x, z)     value at a world position
    paint_polygon (layer, value, field|spline)  fill a polygon with a value

    Info layers drive GAME BEHAVIOR (collisions, placement rules, ground
    condition) -- paint carefully, preview first, backup_scene when unsure.
    """
    return call_helper("infoLayerOps", {
        "action": action, "layer": layer or None, "field": _f(field),
        "spline": _f(spline), "value": value if value >= 0 else None,
        "x": x if action == "read_at" else None,
        "z": z if action == "read_at" else None,
        "commit": commit,
    }, timeout=300.0)


def _f(v):
    return int_or_str(v) if v else None


def _farmlands_xml_list() -> str:
    """Find and parse the map's farmlands.xml (server-side, no editor calls
    beyond the scene filename)."""
    r = bridge("return getSceneFilename()", timeout=6.0)
    if not r["ok"] or not (r["result"] or "").strip():
        return "Could not get the scene filename from the editor.\n" + r["result"]
    scene = Path(r["result"].strip())
    candidates = [scene.parent / "config" / "farmlands.xml",
                  scene.parent / "farmlands.xml"]
    candidates += sorted(scene.parent.rglob("farmlands.xml"))
    seen = set()
    for c in candidates:
        c = c.resolve()
        if c in seen or not c.is_file():
            continue
        seen.add(c)
        try:
            root = ET.parse(c).getroot()
        except Exception:
            continue
        lands = root.findall(".//farmland")
        if not lands:
            continue
        rows = []
        for fl in lands:
            rows.append("  id %s  priceScale=%s  npc=%s%s" % (
                fl.get("id"), fl.get("priceScale") or fl.get("priceFactor") or "?",
                fl.get("npcName") or fl.get("npcIndex") or "?",
                "  defaultFarmProperty" if (fl.get("defaultFarmProperty") or "").lower() == "true" else ""))
        return (str(len(lands)) + " farmland(s) in " + str(c) + ":\n" + "\n".join(rows)
                + "\n(ids are painted into the 'farmlands' info layer; see audit / paint_field)")
    return ("No farmlands.xml found under " + str(scene.parent)
            + " -- the map may keep it elsewhere; farmland ids still work via id_at/audit.")


TOOLS = [field_ops, farmland_ops, info_layer_ops]


def register(mcp):
    for fn in TOOLS:
        mcp.tool()(fn)
