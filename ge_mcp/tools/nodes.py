"""Scenegraph inspection and node lifecycle: inspect, transform, rename,
create, delete (safely), reparent, randomize, import, select."""

from ..helpers import call_helper, int_or_str


def get_selection() -> str:
    """What is selected in the editor right now: ids, names, class, world pos, path."""
    return call_helper("selectionInfo", {})


def get_scene_tree(node: str = "", depth: int = 3, max_nodes: int = 400) -> str:
    """Scene-graph outline: name [id] (class) +childCount, indented.

    node: start point (id or name; empty = scene root). depth limits recursion,
    max_nodes caps output size.
    """
    return call_helper("sceneTree", {
        "node": int_or_str(node) if node else None,
        "depth": depth, "maxNodes": max_nodes,
    })


def find_nodes(pattern: str, limit: int = 60) -> str:
    """Find scene nodes by name (case-insensitive substring): id, name, class, path."""
    return call_helper("findNodes", {"pattern": pattern, "limit": limit})


def node_info(node: str, bounds: bool = False) -> str:
    """Deep-inspect one node: class, path, world+local transform, rotation, scale,
    visibility, clip distance, rigid body type, child count and the onCreate
    attribute. bounds=true additionally walks the subtree's MESH shapes for a
    merged world bounding sphere (skips spline shapes)."""
    return call_helper("nodeInfo", {"node": int_or_str(node), "bounds": bounds})


def set_transform(node: str, x: float = None, y: float = None, z: float = None,
                  rx_deg: float = None, ry_deg: float = None, rz_deg: float = None,
                  sx: float = None, sy: float = None, sz: float = None,
                  uniform: bool = False, relative: bool = False) -> str:
    """Set or nudge a node's WORLD position / rotation (degrees) / scale.

    Only the components you pass are touched. relative=true adds to the current
    values instead of replacing them (e.g. y=0.5, relative=true lifts by 0.5m).
    uniform=true with just sx applies the same scale to all axes. The reply
    includes the previous values, so any change can be undone by re-calling.
    Refuses the scene root and terrain.
    """
    return call_helper("setTransform", {
        "node": int_or_str(node), "x": x, "y": y, "z": z,
        "rxDeg": rx_deg, "ryDeg": ry_deg, "rzDeg": rz_deg,
        "sx": sx, "sy": sy, "sz": sz, "uniform": uniform, "relative": relative,
    })


def node_props(node: str, name: str = "", visible: bool = None,
               clip_distance: float = None, recursive: bool = False) -> str:
    """Rename a node and/or set visibility / clip distance.

    recursive=true applies visibility/clip_distance to the whole subtree too
    (classic map-optimization pass: set sane clip distances on deco groups).
    """
    return call_helper("nodeProps", {
        "node": int_or_str(node), "name": name or None,
        "visible": visible, "clipDistance": clip_distance, "recursive": recursive,
    })


def create_group(name: str, parent: str = "", x: float = None, y: float = None,
                 z: float = None) -> str:
    """Create an empty transform group (default under the scene root), optionally
    at a world position. Use as a staging container for placements/imports."""
    return call_helper("createGroup", {
        "name": name, "parent": int_or_str(parent) if parent else None,
        "x": x, "y": y, "z": z,
    })


def safe_delete(nodes: str, commit: bool = False) -> str:
    """Delete node(s) with the GE crash guards baked in.

    nodes: comma-separated ids/names. The selection is cleared first (deleting a
    SELECTED node crashes the editor), root/terrain/active camera are refused,
    and every id is validity-checked. commit=false lists what would be deleted.
    """
    return call_helper("safeDelete", {"nodes": nodes, "commit": commit})


def reparent(node: str, new_parent: str) -> str:
    """Move a node to a new parent while PRESERVING its world pose.

    Plain link() keeps local values (the node visibly jumps); this bakes world
    translation/rotation and the scale product, re-applies them under the new
    parent, verifies the result, and auto-reverts if the position drifted
    (non-uniform parent scale). Warns when the new parent chain would shear."""
    return call_helper("reparentWorld", {
        "node": int_or_str(node), "parent": int_or_str(new_parent),
    })


def randomize_transforms(node: str, yaw_jitter_deg: float = 360.0,
                         tilt_jitter_deg: float = 0.0, scale_min: float = 1.0,
                         scale_max: float = 1.0, y_jitter: float = 0.0,
                         seed: int = 1234, commit: bool = False) -> str:
    """Naturalize a group's children: random yaw (default full circle), optional
    tilt, uniform scale range and vertical jitter. The classic pass after placing
    trees/rocks so clones don't look stamped. Seeded: preview shows exactly what
    commit applies."""
    return call_helper("randomizeTransforms", {
        "node": int_or_str(node), "yawJitterDeg": yaw_jitter_deg,
        "tiltJitterDeg": tilt_jitter_deg, "scaleMin": scale_min,
        "scaleMax": scale_max, "yJitter": y_jitter, "seed": seed, "commit": commit,
    })


def import_i3d(path: str, parent: str = "", name: str = "", x: float = None,
               y: float = None, z: float = None) -> str:
    """Load an .i3d asset file into the scene (loadI3DFile + link).

    path: absolute path or $data/... game path. Links the loaded root under
    `parent` (default scene root), optionally renames and positions it. Returns
    the new root id + its direct children."""
    return call_helper("importI3d", {
        "path": path, "parent": int_or_str(parent) if parent else None,
        "name": name or None, "x": x, "y": y, "z": z,
    })


def select_nodes(nodes: str = "", clear: bool = False) -> str:
    """Set the editor's selection to the given comma-separated ids/names (or
    clear=true to deselect everything). Useful to show the user a result or to
    stage a manual editor operation."""
    return call_helper("selectNodes", {"nodes": nodes or None, "clear": clear})


def align_to_terrain_normal(node: str, children: bool = True,
                            max_tilt_deg: float = 30.0, sample_dist: float = 1.0,
                            commit: bool = False) -> str:
    """Pitch/roll node(s) to match the terrain SLOPE under them -- rocks, stumps,
    props, small sheds that should sit flush on a hillside (complement of
    align_to_terrain, which only fixes height).

    Heading (yaw) and scale are preserved; tilt is capped at max_tilt_deg so
    steep slopes don't flip things over. children=true tilts each direct child
    of a group. commit=false lists the tilt each node would get.
    """
    return call_helper("alignToTerrainNormal", {
        "node": int_or_str(node), "children": children,
        "maxTiltDeg": max_tilt_deg, "sampleDist": sample_dist, "commit": commit,
    })


TOOLS = [get_selection, get_scene_tree, find_nodes, node_info, set_transform,
         node_props, create_group, safe_delete, reparent, randomize_transforms,
         import_i3d, select_nodes, align_to_terrain_normal]


def register(mcp):
    for fn in TOOLS:
        mcp.tool()(fn)
