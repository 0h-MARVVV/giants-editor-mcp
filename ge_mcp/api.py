"""Flat facade: every tool function importable from one place.

For direct-python testing against a live editor (the bridge is file-based, so
no MCP session is needed):

    import sys; sys.path.insert(0, r"D:\\path\\to\\GiantsEditor-mcp")
    from ge_mcp import api as g
    print(g.ping_editor())
    print(g.node_info("terrain"))

Internals commonly needed by tests are re-exported too (bridge, helpers, ...).
"""

from .bridge import bridge as _bridge, GE_APPDATA, ge_version   # noqa: F401
from .helpers import (call_helper as _call_helper, inject_helpers as _inject_helpers,  # noqa: F401
                      lua_args as _lua_args, lua_val as _lua_val,
                      HELPERS_VERSION, HELPERS_PATH)
from .knowledge import validate_lua as _validate_lua            # noqa: F401
from . import knowledge, snippets as _snippets_lib              # noqa: F401

from .tools.core import (setup, ping_editor, run_lua, search_api, api_signature,  # noqa: F401
                         refresh_api, list_scripts, read_script, get_events)
from .tools.splines import (list_splines, spline_info, spline_place_objects,  # noqa: F401
                            spline_edit, create_fence_line)
from .tools.terrain import (spline_paint_terrain, spline_paint_foliage,     # noqa: F401
                            spline_align_terrain, spline_adjust_terrain,
                            align_to_terrain, list_foliage_layers,
                            terrain_stats, paint_terrain_area, paint_foliage_area,
                            terrain_flatten_area, terrain_paint_by_slope)
from .tools.nodes import (get_selection, get_scene_tree, find_nodes, node_info,  # noqa: F401
                          set_transform, node_props, create_group, safe_delete,
                          reparent, randomize_transforms, import_i3d, select_nodes,
                          align_to_terrain_normal)
from .tools.fields import field_ops, farmland_ops, info_layer_ops     # noqa: F401
from .tools.hygiene import audit_ops, batch_ops, i3d_query            # noqa: F401
from .tools.materials import material_ops                             # noqa: F401
from .tools.traffic import traffic_ops                                # noqa: F401
from .tools.assets import asset_ops, mod_ops, xml_schema              # noqa: F401
from .tools.vision import (viewport_screenshot, camera_look, camera_topdown,  # noqa: F401
                           camera_orbit, debug_view, read_log)
from .tools.scene import save_scene, backup_scene                     # noqa: F401
from .tools.snippets import save_snippet, run_snippet, list_snippets  # noqa: F401
