"""MCP tool functions, one module per group.

Each module defines plain functions (importable and directly callable for
testing -- the bridge is file-based, so `from ge_mcp.tools import nodes;
nodes.node_info("terrain")` works against a live editor with no MCP session),
a TOOLS list, and register(mcp) which wraps them with FastMCP.

Groups are toggled via the GE_MCP_GROUPS env var (comma list, default: all).
"""

from . import (core, splines, terrain, nodes, fields, hygiene, materials,
               traffic, assets, vision, scene, snippets)

GROUPS = {
    "core": core,
    "splines": splines,
    "terrain": terrain,
    "nodes": nodes,
    "fields": fields,
    "hygiene": hygiene,
    "materials": materials,
    "traffic": traffic,
    "assets": assets,
    "vision": vision,
    "scene": scene,
    "snippets": snippets,
}
