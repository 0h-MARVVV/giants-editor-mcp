#!/usr/bin/env python3
"""Compatibility shim -- the server now lives in the ge_mcp package.

Existing MCP configs that launch `python giants_mcp_server.py` keep working:
this file puts its own directory on sys.path, re-exports every tool via the
flat api facade (so `import giants_mcp_server as g; g.node_info(...)` still
works for direct-python testing), and runs the packaged server.

New configs should prefer:  "command": "python", "args": ["-m", "ge_mcp.server"]
(with cwd set to this directory), or the `ge-mcp` script after `pip install -e .`.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ge_mcp.api import *          # noqa: F401,F403  (flat re-export for tests)
from ge_mcp.api import _bridge    # noqa: F401       (underscore names aren't in *)
from ge_mcp.helpers import HELPERS_VERSION, HELPERS_PATH  # noqa: F401
from ge_mcp.server import main, mcp  # noqa: F401

if __name__ == "__main__":
    main()
