"""Scene hygiene: audits (scene graph, file references, textures, collisions,
lights) and batch operations (rename, clean, array, distribute, snap, replace).

The mod-quality pass: run audit_ops before shipping a map; batch_ops does the
mechanical fixes.
"""

import xml.etree.ElementTree as ET
from pathlib import Path

from .. import config
from ..bridge import bridge
from ..helpers import call_helper, int_or_str


def audit_ops(action: str = "scene") -> str:
    """Map-quality audits -- one tool, action-routed. Actions:

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
    """
    if action in ("file_refs", "textures"):
        return _files_audit(action)
    return call_helper("auditScene", {"action": action}, timeout=600.0)


def batch_ops(action: str, node: str = "", pattern: str = "", source: str = "",
              prefix: str = "", match: str = "", start: int = 1,
              mode: str = "line", count: int = 5, count_x: int = 3, count_z: int = 3,
              spacing: float = 5.0, spacing_x: float = None, spacing_z: float = None,
              radius: float = 10.0, step: float = 1.0, terrain_snap: bool = False,
              face_center: bool = False, group_name: str = "", limit: int = 200,
              commit: bool = False) -> str:
    """Mechanical batch edits -- one tool, action-routed. Actions:

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
    """
    return call_helper("batchOps", {
        "action": action, "node": int_or_str(node) if node else None,
        "pattern": pattern or None, "source": int_or_str(source) if source else None,
        "prefix": prefix or None, "match": match or None, "start": start,
        "mode": mode, "count": count, "countX": count_x, "countZ": count_z,
        "spacing": spacing, "spacingX": spacing_x, "spacingZ": spacing_z,
        "radius": radius, "step": step, "terrainSnap": terrain_snap,
        "faceCenter": face_center, "groupName": group_name or None,
        "limit": limit, "commit": commit,
    }, timeout=600.0)


def i3d_query(xpath: str, limit: int = 40, count_only: bool = False) -> str:
    """Read-only XPath query into the OPEN map's i3d XML on disk (zero risk).

    ElementTree XPath subset, e.g.:
      .//Files/File               every file reference
      .//Shape[@name='rock01']    shapes by attribute
      .//UserAttribute            all user attribute elements
      .//Light                    lights as saved in the file
    Returns tag + attributes per match (or just the count). Reads the LAST
    SAVED file -- unsaved editor changes are not in it.
    """
    r = bridge("return getSceneFilename()", timeout=6.0)
    if not r["ok"] or not (r["result"] or "").strip():
        return "Could not get the scene filename from the editor.\n" + r["result"]
    scene = Path(r["result"].strip())
    if not scene.is_file():
        return "Scene file not found on disk: " + str(scene)
    try:
        root = ET.parse(scene).getroot()
    except Exception as exc:
        return "Failed to parse map i3d: " + str(exc)
    try:
        matches = root.findall(xpath)
    except SyntaxError as exc:
        return "[ERR] bad XPath '" + xpath + "': " + str(exc)
    if count_only:
        return str(len(matches)) + " match(es) for " + xpath
    if not matches:
        return "0 matches for " + xpath
    out = [str(len(matches)) + " match(es) for " + xpath + ":"]
    for el in matches[:limit]:
        attrs = " ".join(k + '="' + str(v)[:60] + '"' for k, v in list(el.attrib.items())[:10])
        out.append("  <" + el.tag + (" " + attrs if attrs else "") + ">")
    if len(matches) > limit:
        out.append("  ... (" + str(len(matches) - limit) + " more; raise limit or use count_only)")
    return "\n".join(out)


def _files_audit(action: str) -> str:
    r = bridge("return getSceneFilename()", timeout=6.0)
    if not r["ok"] or not (r["result"] or "").strip():
        return "Could not get the scene filename from the editor.\n" + r["result"]
    scene = Path(r["result"].strip())
    if not scene.is_file():
        return "Scene file not found on disk: " + str(scene)
    try:
        root = ET.parse(scene).getroot()
    except Exception as exc:
        return "Failed to parse map i3d: " + str(exc)
    gd, _src = config.game_dir()
    tex_ext = (".dds", ".png", ".tga")
    # the engine resolves .png <-> .dds interchangeably (i3ds commonly reference
    # .png while GIANTS ships .dds) -- a ref is only missing if NEITHER exists
    swap = {".png": ".dds", ".dds": ".png"}

    def resolve(p):
        if p is None:
            return None
        if p.is_file():
            return p
        alt = swap.get(p.suffix.lower())
        if alt:
            q = p.with_suffix(alt)
            if q.is_file():
                return q
        return None

    total, missing, big, tex_bytes, n_tex = 0, [], [], 0, 0
    for f in root.findall(".//Files/File"):
        raw = (f.get("filename") or "").replace("\\", "/")
        if not raw:
            continue
        total += 1
        if raw.startswith("$data/"):
            p = (gd / "data" / raw[len("$data/"):]) if gd else None
        else:
            p = (scene.parent / raw).resolve()
        hit = resolve(p)
        is_tex = raw.lower().endswith(tex_ext)
        if hit is None:
            missing.append("  " + raw + ("  (game dir not set)" if p is None else ""))
        elif is_tex:
            n_tex += 1
            size = hit.stat().st_size
            tex_bytes += size
            if size > 8 * 1024 * 1024:
                big.append("  %.1f MB  %s" % (size / 1e6, raw))
    if action == "textures":
        out = ["texture audit: %d texture(s) referenced, %.0f MB on disk" % (n_tex, tex_bytes / 1e6)]
        if big:
            out.append("oversized (>8MB):")
            out += big[:25]
        tex_missing = [m for m in missing if m.strip().lower().endswith(tex_ext)]
        if tex_missing:
            out.append("missing texture files:")
            out += tex_missing[:25]
        if not big and not tex_missing:
            out.append("no oversized or missing textures")
        return "\n".join(out)
    out = ["file_refs audit: %d file reference(s), %d MISSING" % (total, len(missing))]
    if missing:
        out += missing[:60]
        if len(missing) > 60:
            out.append("  ... (" + str(len(missing) - 60) + " more)")
        out.append("Missing $data/ paths? Check the game dir via the setup tool.")
    else:
        out.append("all references resolve on disk -- safe to pack")
    return "\n".join(out)


TOOLS = [audit_ops, batch_ops, i3d_query]


def register(mcp):
    for fn in TOOLS:
        mcp.tool()(fn)
