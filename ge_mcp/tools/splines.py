"""Spline discovery and object placement."""

from ..helpers import call_helper, int_or_str


def list_splines(query: str = "") -> str:
    """List every spline in the scene: id, name, length, CV count, closed flag, path.

    Optional query filters by name (case-insensitive substring). Start here to
    find the spline to feed into the other spline_* tools (by id or name).
    """
    return call_helper("listSplines", {"query": query})


def spline_info(spline: str) -> str:
    """Details for one spline: length, CVs, closed, endpoints, bbox, curvature, attributes.

    `spline` is a node id or a name (exact, then case-insensitive substring);
    a transform group containing a spline also works.
    """
    return call_helper("splineInfo", {"spline": int_or_str(spline)})


def spline_place_objects(spline: str, source: str, spacing: float = 5.0, count: int = 0,
                         lateral: float = 0.0, lateral_jitter: float = 0.0,
                         yaw_mode: str = "spline", yaw_jitter_deg: float = 0.0,
                         yaw_add_deg: float = 0.0, terrain_snap: bool = True,
                         y_offset: float = 0.0, seed: int = 1234, group_name: str = "",
                         commit: bool = False, max_count: int = 2000) -> str:
    """Clone `source` along `spline` -- fences, trees, poles, rocks, lamps, etc.

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
    """
    return call_helper("placeObjects", {
        "spline": int_or_str(spline), "source": int_or_str(source),
        "spacing": spacing, "count": count if count and count >= 2 else None,
        "lateral": lateral, "lateralJitter": lateral_jitter,
        "yawMode": yaw_mode, "yawJitterDeg": yaw_jitter_deg, "yawAddDeg": yaw_add_deg,
        "terrainSnap": terrain_snap, "yOffset": y_offset, "seed": seed,
        "groupName": group_name or None, "commit": commit, "maxCount": max_count,
    })


def spline_edit(action: str, spline: str = "", spline2: str = "", points: str = "",
                name: str = "", index: int = -1, x: float = None, y: float = None,
                z: float = None, dx: float = 0.0, dy: float = 0.0, dz: float = 0.0,
                mode: str = "drape", value: float = None, y_offset: float = 0.0,
                iterations: int = 2, spacing: float = 10.0, offset: float = 0.0,
                t: float = 0.0, closed: bool = None, linear: bool = False) -> str:
    """Spline editing -- one tool, action-routed. Actions:

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
    """
    return call_helper("splineEdit", {
        "action": action, "spline": int_or_str(spline) if spline else None,
        "spline2": int_or_str(spline2) if spline2 else None,
        "points": points or None, "name": name or None,
        "index": index if index >= 0 else None,
        "x": x, "y": y, "z": z,
        "dx": dx if dx != 0 else None, "dy": dy if dy != 0 else None,
        "dz": dz if dz != 0 else None,
        "mode": mode, "value": value, "yOffset": y_offset,
        "iterations": iterations, "spacing": spacing,
        "offset": offset if offset != 0 else None,
        "t": t if t > 0 else None, "closed": closed, "linear": linear,
    }, timeout=300.0)


def create_fence_line(spline: str, post_source: str, panel_source: str = "",
                      post_spacing: float = 2.5, panel_length: float = 0.0,
                      terrain_snap: bool = True, y_offset: float = 0.0,
                      post_yaw_add_deg: float = 0.0, panel_yaw_add_deg: float = 0.0,
                      group_name: str = "", commit: bool = False,
                      max_count: int = 1500) -> str:
    """Build a CONNECTED fence along a spline: posts at exact spacing, panels
    stretched to fill each gap precisely (scaled on their length axis, pitched
    to follow the slope). Unlike spline_place_objects (scatter), the segments
    meet: fences, guard rails, walls, hedgerow runs, power lines w/o sag.

    post_source / panel_source: nodes to clone (panel optional = posts only).
    panel_length: the panel asset's natural length in meters -- pass it for an
    exact fit (otherwise estimated from bounds with a warning). Everything goes
    into one group; delete it to undo. Preview first (commit=false default).
    """
    return call_helper("createFenceLine", {
        "spline": int_or_str(spline), "postSource": int_or_str(post_source),
        "panelSource": int_or_str(panel_source) if panel_source else None,
        "postSpacing": post_spacing, "panelLength": panel_length,
        "terrainSnap": terrain_snap, "yOffset": y_offset,
        "postYawAddDeg": post_yaw_add_deg, "panelYawAddDeg": panel_yaw_add_deg,
        "groupName": group_name or None, "commit": commit, "maxCount": max_count,
    }, timeout=300.0)


TOOLS = [list_splines, spline_info, spline_place_objects, spline_edit, create_fence_line]


def register(mcp):
    for fn in TOOLS:
        mcp.tool()(fn)
