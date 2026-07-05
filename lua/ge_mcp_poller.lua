-- ============================================================================
--  GIANTS Editor <-> Claude (MCP) bridge : in-editor poller  (v3.1 AUTOMATIC)
--  Target: GIANTS Editor 10.0.12 (FS25)
--
--  AUTO-PUMP MODEL (confirmed on this build):
--    * addUpdateListener("funcName") -> int id. The editor calls that named
--      global EVERY FRAME while the update loop runs. It resolves the name in
--      the GLOBAL table, so the callback MUST live in _G (see publish step).
--    * startUpdateLoop() turns the loop on from Lua (no Play button), and it
--      keeps running while GIANTS Editor is in the background.
--    * removeUpdateListener(intId) detaches by the integer id.
--
--  IMPORTANT - LOADING:
--    Run this from the console OR the Scripts menu. Either works now, because
--    the callback is explicitly published to _G below. (When run from a Scripts
--    file, a plain `function foo` would NOT be visible to addUpdateListener;
--    the `_G.geMcpUpdate = geMcpUpdate` line is what makes the menu route work.)
--
--    DO NOT set the header to AlwaysLoaded: yes -- that loads the script during
--    early startup, before the editor's systems exist, and GE fails to open.
--    Keep it `no`; we'll wire true auto-start a safer way later.
--
--  Payloads are base64-encoded both ways: the editor's XML layer preserves
--  < > & " ' but turns newlines into spaces (which would break Lua comments);
--  base64 output has no newlines or special chars, so it round-trips cleanly.
-- ============================================================================

-- Author:MARVVV
-- Name:GE-MCP Bridge
-- Description: Claude <-> GIANTS Editor bridge poller (auto-pump)
-- AlwaysLoaded: no

-- ---- configuration ---------------------------------------------------------
local MAILBOX_DIR     = getAppDataPath()          -- confirmed writable; trailing slash
local REQ_PATH        = MAILBOX_DIR .. "mcp_request.xml"
local RESP_PATH       = MAILBOX_DIR .. "mcp_response.xml"
local POLL_EVERY      = 6                          -- check the mailbox every Nth frame
local AUTO_START_LOOP = true                       -- call startUpdateLoop() ourselves
-- ----------------------------------------------------------------------------

-- ---- base64 (pure Lua, 5.1-safe: arithmetic only, no bitwise operators) ----
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64DEC = {}
for i = 1, #B64 do B64DEC[B64:sub(i, i)] = i - 1 end

local function b64encode(data)
    local out = {}
    local n = #data
    local i = 1
    while i <= n do
        local b1 = string.byte(data, i)
        local b2 = (i + 1 <= n) and string.byte(data, i + 1) or nil
        local b3 = (i + 2 <= n) and string.byte(data, i + 2) or nil
        local num = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)
        local c1 = math.floor(num / 262144) % 64
        local c2 = math.floor(num / 4096) % 64
        local c3 = math.floor(num / 64) % 64
        local c4 = num % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1)
        out[#out + 1] = B64:sub(c2 + 1, c2 + 1)
        out[#out + 1] = b2 and B64:sub(c3 + 1, c3 + 1) or "="
        out[#out + 1] = b3 and B64:sub(c4 + 1, c4 + 1) or "="
        i = i + 3
    end
    return table.concat(out)
end

local function b64decode(data)
    data = data:gsub("%s", "")
    local out = {}
    local i = 1
    while i <= #data do
        local s1 = data:sub(i, i)
        local s2 = data:sub(i + 1, i + 1)
        local s3 = data:sub(i + 2, i + 2)
        local s4 = data:sub(i + 3, i + 3)
        local num = (B64DEC[s1] or 0) * 262144
                  + (B64DEC[s2] or 0) * 4096
                  + (B64DEC[s3] or 0) * 64
                  + (B64DEC[s4] or 0)
        out[#out + 1] = string.char(math.floor(num / 65536) % 256)
        if s3 ~= "=" and s3 ~= "" then out[#out + 1] = string.char(math.floor(num / 256) % 256) end
        if s4 ~= "=" and s4 ~= "" then out[#out + 1] = string.char(num % 256) end
        i = i + 4
    end
    return table.concat(out)
end
-- ----------------------------------------------------------------------------

-- ---- read one request, run it, write one response --------------------------
local function handleRequest()
    local xmlId = loadXMLFile("mcpReq", REQ_PATH)
    if xmlId == nil or xmlId == 0 then return end
    local reqId   = getXMLString(xmlId, "mcp.id")
    local codeB64 = getXMLString(xmlId, "mcp.code")
    delete(xmlId)

    if reqId == nil then reqId = "0" end
    local code = codeB64 and b64decode(codeB64) or ""

    local okStr, resultStr
    local fn, compileErr = loadstring(code)
    if fn == nil then
        okStr, resultStr = "false", "compile error: " .. tostring(compileErr)
    else
        local ranOk, ret = pcall(fn)
        if ranOk then
            okStr = "true"
            resultStr = (ret == nil) and "" or tostring(ret)
        else
            okStr, resultStr = "false", "runtime error: " .. tostring(ret)
        end
    end

    local respId = createXMLFile("mcpResp", RESP_PATH, "mcpResponse")
    setXMLString(respId, "mcpResponse.id", reqId)
    setXMLString(respId, "mcpResponse.ok", okStr)
    setXMLString(respId, "mcpResponse.result", b64encode(resultStr))
    saveXMLFile(respId)
    delete(respId)

    deleteFile(REQ_PATH)   -- consume it so it is not run twice
    local okt, tnow = pcall(getDate, "%H:%M:%S")
    print("[GE-MCP] handled a command (" .. (okStr == "true" and "successful" or "failed")
          .. ") Time=" .. ((okt and tnow) and tnow or "?"))
end
-- ----------------------------------------------------------------------------

-- ---- event capture (editor hook system: scripts/Hooks.lua) -----------------
-- The editor calls global onSave/onSelectionChanged/onNodeDeleted/onNodeCloned/
-- onFileOpen/onFileImported, which fan out via _publish() to anything registered
-- with addEventListener(HookType.X, fn). We add listeners (without clobbering the
-- editor's own) and append to a ring buffer that the get_events tool reads.
local EVENT_BUFFER_MAX = 300
-- IMPORTANT: scripts run from the Scripts menu get a PRIVATE env -- bare-global
-- writes do NOT land in _G (same reason geMcpUpdate is published via _G.* below).
-- Event state must live in _G so the get_events loadstring chunk (which runs in
-- _G) sees the same buffer the listeners write to.
_G.__geMcpEvents = _G.__geMcpEvents or {}   -- persists across reloads (keeps history)
_G.__geMcpSeq    = _G.__geMcpSeq or 0

local function geMcpStamp()
    local ok, s = pcall(getDate, "%Y-%m-%d %H:%M:%S")
    if ok and s then return s end
    return ""
end

local function geMcpRecordEvent(kind, detail)
    _G.__geMcpSeq = (_G.__geMcpSeq or 0) + 1
    local ev = _G.__geMcpEvents
    ev[#ev + 1] = { seq = _G.__geMcpSeq, t = geMcpStamp(), kind = kind, detail = detail or "" }
    while #ev > EVENT_BUFFER_MAX do table.remove(ev, 1) end
end

local function geMcpNodeName(id)
    if id == nil or getName == nil then return "" end
    -- entityExists() is the safe validity check: it returns false for a deleted
    -- id WITHOUT logging. getName() on a dead id, by contrast, prints
    -- "Script error in getName: Unknown entity id N" to the editor log BEFORE it
    -- raises -- so the pcall below catches the error but cannot suppress that log
    -- line. Guard with entityExists so getName only ever sees a live node. (This
    -- is the path hit when you delete a selected object: next poll, the id is
    -- still in the previous selection set but the node is already gone.)
    if entityExists ~= nil and not entityExists(id) then return "" end
    local ok, r = pcall(getName, id)
    return (ok and r ~= nil) and tostring(r) or ""
end

-- Selection polling: the engine does NOT fire ON_SELECTION_CHANGED in 10.0.12,
-- so we read the selection set each tick and synthesize +/- SELECTION events.
local function geMcpPollSelection()
    if getNumSelected == nil then return end
    local n = getNumSelected()
    local cur = {}
    for i = 0, n - 1 do
        local id = getSelection(i)
        if id ~= nil and id ~= 0 then cur[id] = true end
    end
    local prev = _G.__geMcpSelSet
    -- Cache each selected node's name WHILE it is alive, so when it leaves the
    -- selection because it was deleted we can still report the name (by then the
    -- node is gone and geMcpNodeName would correctly return "").
    local names = _G.__geMcpSelNames
    if names == nil then names = {}; _G.__geMcpSelNames = names end
    if prev == nil then                                    -- silent initial snapshot
        for id in pairs(cur) do names[id] = geMcpNodeName(id) end
        _G.__geMcpSelSet = cur
        return
    end
    for id in pairs(prev) do
        if not cur[id] then
            local nm = names[id] or geMcpNodeName(id)      -- last-known name survives deletion
            geMcpRecordEvent("SELECTION", "-" .. tostring(id) .. (nm ~= "" and (" (" .. nm .. ")") or ""))
            names[id] = nil
        end
    end
    for id in pairs(cur) do
        if not prev[id] then
            local nm = geMcpNodeName(id)
            names[id] = nm
            geMcpRecordEvent("SELECTION", "+" .. tostring(id) .. (nm ~= "" and (" (" .. nm .. ")") or ""))
        end
    end
    _G.__geMcpSelSet = cur
end
-- ----------------------------------------------------------------------------

-- ---- per-frame callback ----------------------------------------------------
-- Defined as a local closure (keeps its access to the locals above), then
-- PUBLISHED to _G by name so addUpdateListener's by-name lookup can find it
-- no matter whether this file was run from the console or the Scripts menu.
local function geMcpUpdateImpl(dt)
    __geMcpFrame = (__geMcpFrame or 0) + 1
    if (__geMcpFrame % POLL_EVERY) ~= 0 then return end
    if fileExists(REQ_PATH) then
        local ok, err = pcall(handleRequest)
        if not ok then print("[GE-MCP] handler error: " .. tostring(err)) end
    end
    local sok, serr = pcall(geMcpPollSelection)   -- observe selection via polling
    if not sok then print("[GE-MCP] selpoll error: " .. tostring(serr)) end
end
_G.geMcpUpdate = geMcpUpdateImpl   -- <-- the fix: visible in the global table
-- ----------------------------------------------------------------------------

-- ---- (re)install -----------------------------------------------------------
-- detach a previous listener if this script is run again in one session
if __geMcpListenerId ~= nil then
    pcall(removeUpdateListener, __geMcpListenerId)
    __geMcpListenerId = nil
end
-- clear any stale mailbox files from a previous run
if fileExists(REQ_PATH) then deleteFile(REQ_PATH) end
if fileExists(RESP_PATH) then deleteFile(RESP_PATH) end

__geMcpFrame = 0
__geMcpListenerId = addUpdateListener("geMcpUpdate")

-- (re)register editor event listeners; detach any from a previous run first
if _G.__geMcpEventHandles ~= nil then
    for _, h in ipairs(_G.__geMcpEventHandles) do
        if removeEventListener ~= nil and h.hookType ~= nil and h.ref ~= nil then
            pcall(removeEventListener, h.hookType, h.ref)
        end
    end
end
_G.__geMcpEventHandles = {}
-- selection is observed by POLLING (see geMcpPollSelection / per-frame callback):
-- the engine does NOT fire ON_SELECTION_CHANGED in 10.0.12. Drop any temporary
-- poll listener left by a live-injected session, and re-snapshot silently.
if _G.__geMcpSelPollId ~= nil then
    pcall(removeUpdateListener, _G.__geMcpSelPollId)
    _G.__geMcpSelPollId = nil
end
_G.__geMcpSelSet = nil
_G.__geMcpSelNames = nil
-- the remaining hooks ARE dispatched by the engine (editor core uses
-- ON_FILE_OPEN / ON_SAVE); harmless if a given build doesn't fire one.
if HookType ~= nil and addEventListener ~= nil then
    local function reg(hookType, fn)
        if hookType == nil then return end
        local ref = addEventListener(hookType, fn)
        local hs = _G.__geMcpEventHandles
        hs[#hs + 1] = { hookType = hookType, ref = ref }
    end
    reg(HookType.ON_FILE_OPEN,     function(filepath) geMcpRecordEvent("FILE_OPEN", tostring(filepath)) end)
    reg(HookType.ON_FILE_IMPORTED, function(filepath) geMcpRecordEvent("FILE_IMPORTED", tostring(filepath)) end)
    reg(HookType.ON_SAVE,          function(filepath) geMcpRecordEvent("SAVE", tostring(filepath)) end)
    reg(HookType.ON_NODE_CLONED,   function(cloneNodeId)
        geMcpRecordEvent("NODE_CLONED", tostring(cloneNodeId) .. " (" .. geMcpNodeName(cloneNodeId) .. ")")
    end)
    reg(HookType.ON_NODE_DELETED,  function(deletedNodeId)
        local nm = geMcpNodeName(deletedNodeId)
        geMcpRecordEvent("NODE_DELETED", tostring(deletedNodeId) .. (nm ~= "" and (" (" .. nm .. ")") or ""))
    end)
end
-- selection polling is always active (folded into the per-frame callback above)
_G.__geMcpEventsArmed = true

-- start the editor's update loop ourselves so we get ticks with no Play button
if AUTO_START_LOOP and startUpdateLoop ~= nil then
    if getIsUpdateLoopPlaying == nil or not getIsUpdateLoopPlaying() then
        startUpdateLoop()
    end
end

local playing = getIsUpdateLoopPlaying and getIsUpdateLoopPlaying()
print("[GE-MCP] bridge armed. listener id=" .. tostring(__geMcpListenerId)
      .. "  loop playing=" .. tostring(playing))
print("[GE-MCP] mailbox: " .. REQ_PATH)
print("[GE-MCP] event capture: selection (polled) + " .. tostring(#_G.__geMcpEventHandles) .. " engine hooks (save/clone/delete/file).")
if playing then
    print("[GE-MCP] AUTOMATIC mode active -- commands will run on their own.")
else
    print("[GE-MCP] loop not running; press Play once and it's live.")
end
-- ----------------------------------------------------------------------------

-- Manual detach (paste in console if you ever want to stop the bridge):
function geMcpStop()
    if __geMcpListenerId ~= nil then pcall(removeUpdateListener, __geMcpListenerId); __geMcpListenerId = nil end
    if _G.__geMcpSelPollId ~= nil then pcall(removeUpdateListener, _G.__geMcpSelPollId); _G.__geMcpSelPollId = nil end
    if _G.__geMcpEventHandles ~= nil then
        for _, h in ipairs(_G.__geMcpEventHandles) do
            if removeEventListener ~= nil and h.hookType ~= nil and h.ref ~= nil then
                pcall(removeEventListener, h.hookType, h.ref)
            end
        end
        _G.__geMcpEventHandles = {}
        _G.__geMcpEventsArmed = false
    end
    print("[GE-MCP] detached.")
end