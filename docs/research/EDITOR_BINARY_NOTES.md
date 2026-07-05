# GIANTS Editor `editor.exe` (10.0.12) — RE notes for the MCP

Source: live Ghidra analysis of `editor.exe` (PID was 16924), image base `0x140000000`,
`.text` ~30 MB. **The binary is stripped** — no symbols, so everything below is located by
strings + xrefs and named `FUN_<addr>`. Date: 2026-06-14.

Goal of this pass: find native functions/subsystems we could use to make the
`giants-editor` MCP faster or more capable than its current file-mailbox transport.

---

## TL;DR

- **The editor exposes no always-on IPC/command server.** The only listening socket on the
  live process was `:::8080` — that's the *Ghidra* plugin, not the editor. So the MCP's
  file-mailbox design is a reasonable choice, not a missed obvious socket.
- The editor **does** contain a full **native network Lua debugger** (the protocol GIANTS
  Studio uses): UDP broadcast discovery, then an outbound TCP session with remote code
  execution. Powerful, but heavy to reuse and fronted by an interactive dialog.
- **Lua does not expose raw sockets**, and the dev console is **not** Lua-extensible or
  remote. So a "Lua-side socket server in the poller" is **not** feasible without native code.
- The MCP already enumerates the full live `_G` API, so re-cataloguing engine function
  *names* from the binary is redundant (the binary has no signatures anyway — it's stripped).
- **The real wins are design-side** (capture `print()`, cut latency, loop-dependency) plus
  exposing a few high-value engine bindings (screenshots for visual feedback).

---

## 1. Current MCP transport and its costs (from `giants_mcp_server.py`)

File "mailbox" in `%LOCALAPPDATA%\GIANTS Editor 64bit 10.0.12\`:
Python writes `mcp_request.xml` (base64 Lua) → in-editor poller `ge_mcp_poller.lua` (runs on
the editor **update loop**) reads it, `loadstring`-executes, writes `mcp_response.xml` (base64)
→ Python polls `RESP_PATH` every `POLL_INTERVAL = 0.05` s.

Costs:
1. **Latency** ≈ 50 ms Python poll + one editor-loop tick, every `run_lua`.
2. **Requires the editor loop to be "playing"** — no tick, no poller, requests time out.
3. **Filesystem churn** (write/replace/read/unlink + base64) per call.
4. **`print()` is not captured** — only `return <string>` comes back; tables stringify to
   `table: 0x..`.
5. **Manual setup** — poller must be loaded from the Scripts menu each session.

---

## 2. What the binary offers for transport

### 2a. Native network Lua debugger — the ONLY socket path (high effort)

This is the GIANTS "Remote Debugger" / GIANTS Studio protocol, fully present:

| Addr | What it is |
|---|---|
| `FUN_14036cd30` | **UDP discovery beacon.** `socket(AF_INET, SOCK_DGRAM, UDP)`, `SO_BROADCAST`, broadcasts payload **`"Lua debug server"`** (16 bytes) on port **`0xEFE0` = 61408** (value passed to the bind wrapper `FUN_1404633a0`; verify endianness). Loops ~100 ticks waiting for a debugger to answer, then calls the connect path. |
| `FUN_14036c890` | **DebuggerManager connect (TCP).** `getaddrinfo(host)` on a stored hostname → picks AF_INET → connects to host:port → allocates a 0x1e8-byte debugger object → spawns comms thread `FUN_14036d130`. Logs `"Remote Debugger: %s %s"`. Gated by "debugging enabled" flag at `manager+0x64`. |
| `FUN_14036d1f0` | **Lua binding `startDebugging(addr)`.** Pops a MessageBox *"Click OK to connect to GIANTS Studio or Cancel to continue"*, then connects **outward** to `addr`; retries with a "Connection Failed" dialog. Gated by flags `+0x64` and `+0x66`. |
| `FUN_14036d130` | Debugger comms thread proc. |

Supporting evidence (strings / RTTI):
- Thread jobs **`GIANTS LuaDebuggerNetworkSend`** / **`GIANTS LuaDebuggerNetworkRecv`** → bidirectional.
- **`"break into debugger (EXEC)"`** / `"(non-EXEC)"` → supports **remote code execution**, not just inspection.
- `"Debugger connected:"`, `"  Debugger hook: %s"`, `"Remote Debugger: connection closed"`.
- RTTI: `DebuggerManager`, `StopDebuggingListener@DebuggerManager`, `INetSocket`, `DPU_Debugger`.
- Lua binding name string: **`startDebugging`** (`0x14218d0d0`).

**Assessment.** To use this the MCP would have to (a) ensure the editor is in debug-enabled
mode, (b) get `startDebugging("127.0.0.1")` called (and dismiss the MessageBox), and (c)
implement the GIANTS Studio side of the wire protocol in Python. That's a large, brittle
project. Worth it **only** if you want live streaming / breakpoints / variable inspection.
Keep as the "deep integration" option, not the next step.

### 2b. Things that are NOT available (ruled out)

- **No general IPC server.** Live `netstat` on the editor PID showed no editor-owned listener
  (only the Ghidra plugin's `:8080`). The beacon above is *outbound* UDP, only while debugging.
- **No Lua socket binding.** The only `INetSocket` (RTTI `.?AVINetSocket@@`) is native, used by
  the debugger; the other "socket" strings are OpenSSL/libcurl (HTTP *client*). Lua can't open
  a socket → can't host a TCP server inside the poller.
- **No remote/Lua-extensible console.** `open_console`/`close_console`/`echo_console`/
  `noecho_console` (`0x141fad4c0`–`0x141fad528`) are the hardcoded engine dev console; the only
  *console-command* strings otherwise are wxWidgets' `wxConsoleStderr` stderr helper.

### 2c. Notable platform facts (context)

- GUI is **wxWidgets 3.2.2.1** (`C:\src\bin\wxWidgets-3.2.2.1\...`); has a legacy `wxDDEServer`
  (single-instance / file-open — not a useful command channel).
- HTTP via **libcurl + OpenSSL** (client only; HTTP/2, SOCKS, FTP strings present).
- Lua is GIANTS-extended / Luau-style: `table.create/find/freeze`, `string.split/startsWith/trim`,
  `math.clamp/round/sign/noise`, `bit32.*`. Output helper globals: `print_r`, `printError`, etc.

---

## 3. High-value engine Lua bindings worth surfacing in the MCP

Confirmed as real camelCase bindings in the binary. **The MCP already auto-discovers live
`_G`,** so treat this as "worth a dedicated tool / highlight," not a list to hardcode:

- **Screenshots → visual feedback for the agent:** `saveScreenshot`, `renderScreenshot`,
  `render360Screenshot`, `renderMultiviewportScreenshot`, `setEnableHDRScreenshot`
  (`0x14218cc40`–`0x14218ce78`). `renderScreenshot` is the undocumented-but-live one already
  noted in the server docstring.
- Scene/IO: `loadI3DFile` (`0x14218da30`), `LoadI3DFailedReason`.
- Rendering: `setDebugRenderingMode` / `getDebugRenderingMode` (`0x14211f1f0`).

Source-of-truth note: the binding registration carries no signatures (stripped), so the
binary can't improve on the live `_G` snapshot + `scriptBinding.xml` + `known_functions.json`
the MCP already uses. Don't bother scraping API names from `.rdata`.

---

## 4. Recommendations to make the MCP more efficient (prioritized)

**P1 — capture `print()` output (cheap, closes a real gap).** In `ge_mcp_poller.lua`, override
`print` (and `printError`/`printWarning`) for the duration of each request to tee into a buffer,
and append that buffer to the response alongside the `return` value. No binary work needed.

**P1 — cut transport latency (cheap).** Replace the 50 ms `POLL_INTERVAL` sleep loop on the
Python side with an event-driven wait on `RESP_PATH` (`ReadDirectoryChangesW` /
`watchdog`), and/or shrink the interval. On the Lua side, make sure the poller checks the
mailbox every frame.

**P2 — add a `screenshot` tool.** Call `renderScreenshot`/`saveScreenshot` via the bridge,
return the saved path; lets the agent *see* the result of an edit. Highest capability-per-effort.

**P2 — return tables as data.** Add a small Lua table→JSON (or `print_r`) serializer the poller
can apply, so `run_lua` can hand back structured results instead of `table: 0x..`.

**P2 — address the loop-dependency.** Document that the editor loop must be playing, or
investigate a hook that ticks the poller regardless of play state (the MCP already uses
`scripts/Hooks.lua` for events).

**P3 — network-debugger transport (big).** Only if you want live streaming/breakpoints: §2a.

---

## Appendix — address quick-reference

```
Debugger / transport
  FUN_14036cd30   UDP discovery beacon ("Lua debug server", port 0xEFE0/61408, SO_BROADCAST)
  FUN_14036c890   DebuggerManager TCP connect (getaddrinfo→connect→spawn comms thread)
  FUN_14036d1f0   Lua `startDebugging(addr)` — MessageBox + outbound connect (flags +0x64/+0x66)
  FUN_14036d130   debugger comms thread proc

Strings
  0x142147700  "Lua debug server"
  0x1421476e8  "GIANTS DebuggerManager"
  0x1421476d0  "Remote Debugger: %s %s\n"
  0x14215b940  "GIANTS LuaDebuggerNetworkSend"
  0x14215b960  "GIANTS LuaDebuggerNetworkRecv"
  0x1421604e0  "break into debugger (EXEC)"
  0x14218d0d0  "startDebugging"
  0x14218ce48  "renderScreenshot"   0x14218cc40 "saveScreenshot"
  0x14218da30  "loadI3DFile"
  0x141fad4c0..528  open_/close_/echo_/noecho_console (engine dev console)
  RTTI: INetSocket, DebuggerManager, StopDebuggingListener, DPU_Debugger
```
