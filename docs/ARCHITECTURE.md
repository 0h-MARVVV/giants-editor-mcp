# Architecture

## Transport: the mailbox

The server and the editor share no socket — GIANTS Editor's Lua sandbox can
read/write files, so the bridge is two XML files in the editor's AppData folder:

```
Claude → tool call → server writes mcp_request.xml  (id + base64 Lua)
                   → in-editor poller (update-loop listener) reads it,
                     loadstring + pcall, writes mcp_response.xml (id + base64 result)
                   → server matches the id → tool result
```

- base64 both ways because the editor's XML layer folds newlines into spaces.
- One request in flight at a time (tool calls are synchronous) → race-free.
- The poller (`lua/ge_mcp_poller.lua`) is an `addUpdateListener` callback and
  starts the update loop itself — no Play button, keeps running in background.
- The AppData folder name contains the editor version; the server picks the
  highest installed version automatically (`GE_APPDATA`/`GE_VERSION_DIR` override).

## The injected helper library

Heavy Lua lives in `lua/ge_mcp_helpers.lua`, injected once per editor session
into `_G.__geMcpS` (integer-versioned). Every toolkit call is then a one-liner:

```lua
if __geMcpS == nil or (__geMcpS.version or 0) < N then return '[NOHELPERS]' end
return __geMcpS.placeObjects({spline=..., ...})
```

`[NOHELPERS]` (fresh editor, version bump) triggers automatic re-injection and
a single retry. Bump `HELPERS_VERSION` (ge_mcp/helpers.py) and the `version`
field at the top of the Lua file **together**.

## Knowledge layers (what run_lua validates against)

1. `scriptBinding.xml` / `ScriptBindingBuiltins.xml` from the editor install —
   documented functions WITH signatures.
2. The editor's live `_G` — the true set of callable globals (superset).
3. `known_functions.json` — observed signatures for undocumented-but-live
   functions, mined from FS25/editor Lua corpora call-sites.

`run_lua` scans the snippet (comments/strings stripped by a proper scanner —
see validation.py), and refuses unknown bare calls with close-match suggestions.

## Safety doctrine

Learned from real crashes and eaten terrain; every new tool follows it:

1. **Preview-first**: write tools default `commit=false`, printing op estimates
   and exactly what would change. The preview must be cheap and read-only.
2. **Op caps**: estimate the work before doing it; refuse over `max_ops` with
   actionable advice (raise step, chunk with from_t/to_t, or raise the cap).
3. **Deterministic seeds**: randomized tools take a `seed`; preview → commit
   with the same args produces the identical result.
4. **Grouped placements**: every placement run creates one fresh transform
   group — deleting that group is the undo.
5. **Two-phase terrain**: ALL `getTerrainHeightAtWorldPos` reads happen before
   ANY `setTerrainHeightAtWorldPos`. Heightmap vertices are coarser than the
   sampling grid; read-after-write compounds through vertex aliasing (verified:
   a 0.8m relative lower measured 1.7m before this rule). With two-phase +
   per-cell dedupe, relative lower/raise with identical args are inverses.
6. **Deletion guards**: clear the selection before any script delete (deleting
   a selected node crashes GE), refuse root/terrain/active camera, re-check
   ids with `entityExists`.
7. **Native-crash hygiene**: `pcall` cannot catch engine segfaults. Never call
   an undocumented function with guessed arity in a batch; probe a single call
   on a freshly-loaded throwaway scene first. Known crashers: enumerating user
   attributes by index; `getShapeBoundingSphere` on spline-geometry shapes
   (the helpers' bounds walk skips splines).
8. **Honest results**: tools report what actually happened (cells written,
   nodes deleted, drift measured), never just "ok".

## Tool tiers

- **Flat tools**: the daily workhorses; full parameter schemas.
- **Snippets**: unlimited saved scripts behind 3 schemas (save/run/list) —
  params injected as a Lua `ARGS` table, run/failure counts tracked.
  Promotion path: proven snippet → portmanteau action → flat tool.
- **Portmanteau tools** (planned, see ROADMAP.md): one schema per specialist
  domain (`field_ops`, `audit_ops`, ...) with an `action` parameter, keeping
  schema cost flat for Desktop clients that load every schema every session.
- `GE_MCP_GROUPS` trims registration per client.

## Testing model

The bridge is file-based, so tools are plain Python functions testable without
an MCP session:

```python
from ge_mcp import api as g
print(g.ping_editor())          # against the live editor
```

`tests/offline/` runs with no editor (validator, marshalling, snippets,
registration). `scripts/regression.py` exercises every tool read-only /
preview-only against a live editor and is the gate after any restructure.
