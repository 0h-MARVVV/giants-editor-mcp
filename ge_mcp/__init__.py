"""GIANTS Editor <-> Claude MCP bridge.

Drive a live GIANTS Editor 10.x (FS25) session through MCP tools: run Lua,
place/paint/shape along splines, inspect and edit the scenegraph, see the
viewport, and replay proven snippets.

Package layout:
  bridge.py      file-mailbox transport to the in-editor poller
  knowledge.py   documented bindings + mined signatures + live-globals index
  validation.py  Lua source scanner (comment/string stripping for validation)
  helpers.py     injected Lua helper library machinery (lua/ge_mcp_helpers.lua)
  snippets.py    saved-script library (snippets/)
  tools/         MCP tool functions, one module per group (GE_MCP_GROUPS)
  server.py      FastMCP instance, group registration, entry point
  api.py         flat facade of every tool for direct-python testing
"""

__version__ = "1.0.1"
