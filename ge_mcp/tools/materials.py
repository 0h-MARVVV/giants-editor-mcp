"""Materials and shaders: inventory, shader parameters, material assignment."""

from ..helpers import call_helper, int_or_str


def material_ops(action: str, node: str, param: str = "", source: str = "",
                 x: float = None, y: float = None, z: float = None, w: float = None,
                 shared: bool = False, recursive: bool = True,
                 commit: bool = False) -> str:
    """Material/shader work -- one tool, action-routed. Actions:

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
    """
    return call_helper("materialOps", {
        "action": action, "node": int_or_str(node),
        "param": param or None, "source": int_or_str(source) if source else None,
        "x": x, "y": y, "z": z, "w": w,
        "shared": shared, "recursive": recursive, "commit": commit,
    }, timeout=300.0)


TOOLS = [material_ops]


def register(mcp):
    for fn in TOOLS:
        mcp.tool()(fn)
