-- ============================================================================
--  GIANTS Editor <-> Claude (MCP) bridge : injected helper library
--
--  NOT a Scripts-menu script. giants_mcp_server.py injects this file via the
--  mailbox (loadstring in _G) the first time a spline/scene tool is used, and
--  re-injects automatically after an editor restart. All functions live in
--  _G.__geMcpS and return STRINGS (the bridge tostring()s return values).
--
--  Engine calls used here are the proven set from the shipped spline panels
--  (Spline_Paint_Panel_25, Paint Foliage by Spline, Spline_Height Panel,
--  Align trees to terrain) plus the documented Spline bindings:
--  getSplinePositionWithDistance (true arc-length stepping), getSplineCurvature
--  (adaptive paint step on bends), getSplineOrientation, DensityMapModifier.
--
--  Lua 5.1 only: no goto, no bit ops, math.atan2 available.
-- ============================================================================

__geMcpS = { version = 12 }
local S = __geMcpS

-- ---- small utilities --------------------------------------------------------
local function fnum(v)            -- compact number formatting for reports
    if v == nil then return "?" end
    local a = math.abs(v)
    if a >= 100 then return string.format("%.1f", v) end
    return string.format("%.2f", v)
end

local function seedRng(seed)
    math.randomseed(seed or 1234)
    math.random(); math.random(); math.random()   -- warm up the LCG
end

-- world-scale product up the parent chain (link() keeps LOCAL transforms, so a
-- clone under an identity group needs the source's accumulated scale applied)
local function worldScale(node)
    local sx, sy, sz = 1, 1, 1
    local n = node
    while n ~= nil and n ~= 0 do
        local ok, ax, ay, az = pcall(getScale, n)
        if ok and ax ~= nil then sx, sy, sz = sx * ax, sy * ay, sz * az end
        local okp, p = pcall(getParent, n)
        if not okp or p == nil or p == 0 or p == n then break end
        n = p
    end
    return sx, sy, sz
end

local function classStr(id)
    local parts = {}
    local function has(cid) local ok, r = pcall(getHasClassId, id, cid); return ok and r end
    if has(ClassIds.SHAPE) then
        local ok, g = pcall(getGeometry, id)
        if ok and g ~= nil and g ~= 0 then
            local ok2, isSp = pcall(getHasClassId, g, ClassIds.SPLINE)
            if ok2 and isSp then parts[#parts + 1] = "SPLINE" else parts[#parts + 1] = "SHAPE" end
        else
            parts[#parts + 1] = "SHAPE"
        end
    end
    if has(ClassIds.LIGHT_SOURCE) then parts[#parts + 1] = "LIGHT" end
    if has(ClassIds.CAMERA) then parts[#parts + 1] = "CAMERA" end
    if #parts == 0 then parts[#parts + 1] = "TG" end
    return table.concat(parts, "+")
end

local function nodePath(id)
    local segs, n, hops = {}, id, 0
    while n ~= nil and n ~= 0 and hops < 64 do
        table.insert(segs, 1, getName(n) or "?")
        local ok, p = pcall(getParent, n)
        if not ok or p == nil or p == 0 or p == n then break end
        n = p
        hops = hops + 1
    end
    return table.concat(segs, "/")
end

-- ---- node / spline / terrain resolution -------------------------------------
-- spec: numeric id, numeric string, or a name (exact match first, then
-- case-insensitive substring). Returns id or nil, errMsg.
function S.resolveNode(spec)
    if type(spec) == "number" then
        if entityExists(spec) then return spec end
        return nil, "no entity with id " .. tostring(spec)
    end
    local s = tostring(spec or "")
    if s == "" then return nil, "empty node spec" end
    local idn = tonumber(s)
    if idn ~= nil and entityExists(idn) then return idn end
    local wanted = string.lower(s)
    local exact, sub = nil, nil
    local function walk(n)
        local nm = getName(n) or ""
        if nm == s then exact = n return true end
        if sub == nil and string.find(string.lower(nm), wanted, 1, true) then sub = n end
        for i = 0, getNumOfChildren(n) - 1 do
            if walk(getChildAt(n, i)) then return true end
        end
        return false
    end
    walk(getRootNode())
    local found = exact or sub
    if found ~= nil then return found end
    return nil, "no node named (or containing) '" .. s .. "'"
end

local function isSplineShape(id)
    local ok, isShape = pcall(getHasClassId, id, ClassIds.SHAPE)
    if not ok or not isShape then return false end
    local okg, g = pcall(getGeometry, id)
    if not okg or g == nil or g == 0 then return false end
    local ok2, isSp = pcall(getHasClassId, g, ClassIds.SPLINE)
    return ok2 and isSp
end

-- resolve spec to a spline shape: the node itself, or the first spline found
-- underneath it (so a TG containing one spline works too)
local function needSpline(spec)
    local id, err = S.resolveNode(spec)
    if id == nil then return nil, err end
    if isSplineShape(id) then return id end
    local found = nil
    local function walk(n)
        if found then return end
        if isSplineShape(n) then found = n return end
        for i = 0, getNumOfChildren(n) - 1 do walk(getChildAt(n, i)) end
    end
    walk(id)
    if found then return found end
    return nil, "'" .. (getName(id) or tostring(id)) .. "' is not a spline (and contains none)"
end

local function findTerrain()
    if g_terrainNode ~= nil and entityExists(g_terrainNode) then return g_terrainNode end
    local root = getRootNode()
    for i = 0, getNumOfChildren(root) - 1 do
        local c = getChildAt(root, i)
        if getName(c) == "terrain" then return c end
    end
    return nil
end

-- ---- arc-length spline walk --------------------------------------------------
-- Calls fn(t, x,y,z, dirX,dirY,dirZ) every stepMeters along the spline,
-- including both endpoints. Returns the number of samples.
local function walkSpline(sp, stepMeters, maxSteps, fn)
    local len = getSplineLength(sp) or 0
    if len <= 0 then return 0 end
    local t, n, finished = 0.0, 0, false
    while n < maxSteps do
        local x, y, z = getSplinePosition(sp, t)
        local dx, dy, dz = getSplineDirection(sp, t)
        fn(t, x, y, z, dx, dy, dz)
        n = n + 1
        if finished then break end
        local _, _, _, nt = getSplinePositionWithDistance(sp, t, stepMeters, true, 0.0005)
        if nt == nil or nt <= t then nt = t + stepMeters / len end
        t = nt
        if t >= 1.0 then t = 1.0 finished = true end
    end
    return n
end

-- XZ-normalized left vector for a spline direction
local function leftVec(dx, dz)
    local l = math.sqrt(dx * dx + dz * dz)
    if l < 1e-6 then return nil end
    return -dz / l, dx / l
end

-- ---- scene inspection ---------------------------------------------------------
function S.selectionInfo()
    local n = getNumSelected()
    if n == 0 then return "Selection: empty" end
    local out = { "Selection: " .. n .. " node(s)" }
    for i = 0, n - 1 do
        local id = getSelection(i)
        if id ~= nil and id ~= 0 and entityExists(id) then
            local x, y, z = getWorldTranslation(id)
            out[#out + 1] = string.format("  [%d] %s  (%s)  world=(%s, %s, %s)  path=%s",
                id, getName(id) or "?", classStr(id), fnum(x), fnum(y), fnum(z), nodePath(id))
        end
    end
    return table.concat(out, "\n")
end

function S.sceneTree(a)
    local rootSpec = a.node
    local root
    if rootSpec == nil or rootSpec == "" then
        root = getRootNode()
    else
        local id, err = S.resolveNode(rootSpec)
        if id == nil then return "[ERR] " .. err end
        root = id
    end
    local maxDepth = a.depth or 3
    local maxNodes = a.maxNodes or 400
    local out, count, clipped = {}, 0, false
    local function walk(n, depth, indent)
        if count >= maxNodes then clipped = true return end
        count = count + 1
        local kids = getNumOfChildren(n)
        out[#out + 1] = string.format("%s%s  [%d] (%s)%s", indent, getName(n) or "?",
            n, classStr(n), kids > 0 and ("  +" .. kids) or "")
        if depth < maxDepth then
            for i = 0, kids - 1 do walk(getChildAt(n, i), depth + 1, indent .. "  ") end
        end
    end
    walk(root, 0, "")
    if clipped then out[#out + 1] = ("... clipped at " .. maxNodes .. " nodes (raise maxNodes or lower depth)") end
    return table.concat(out, "\n")
end

function S.findNodes(a)
    local pat = string.lower(tostring(a.pattern or ""))
    if pat == "" then return "[ERR] empty pattern" end
    local limit = a.limit or 60
    local out, count, total = {}, 0, 0
    local function walk(n)
        local nm = getName(n) or ""
        if string.find(string.lower(nm), pat, 1, true) then
            total = total + 1
            if count < limit then
                count = count + 1
                out[#out + 1] = string.format("  [%d] %s  (%s)  %s", n, nm, classStr(n), nodePath(n))
            end
        end
        for i = 0, getNumOfChildren(n) - 1 do walk(getChildAt(n, i)) end
    end
    walk(getRootNode())
    if total == 0 then return "No nodes match '" .. tostring(a.pattern) .. "'" end
    local head = total .. " node(s) match '" .. tostring(a.pattern) .. "'"
    if total > count then head = head .. " (showing " .. count .. ")" end
    return head .. "\n" .. table.concat(out, "\n")
end

function S.listSplines(a)
    local q = string.lower(tostring(a.query or ""))
    local out, count = {}, 0
    local function walk(n)
        if isSplineShape(n) then
            local nm = getName(n) or "?"
            if q == "" or string.find(string.lower(nm), q, 1, true) then
                count = count + 1
                local len = getSplineLength(n) or 0
                local ncv = getSplineNumOfCV(n) or 0
                local closed = getIsSplineClosed(n)
                out[#out + 1] = string.format("  [%d] %s  len=%sm  CVs=%d%s  %s",
                    n, nm, fnum(len), ncv, closed and "  closed" or "", nodePath(n))
            end
        end
        for i = 0, getNumOfChildren(n) - 1 do walk(getChildAt(n, i)) end
    end
    walk(getRootNode())
    if count == 0 then
        return q == "" and "No splines in the scene." or ("No splines match '" .. tostring(a.query) .. "'")
    end
    return count .. " spline(s):\n" .. table.concat(out, "\n")
end

function S.splineInfo(a)
    local sp, err = needSpline(a.spline)
    if sp == nil then return "[ERR] " .. err end
    local len = getSplineLength(sp) or 0
    local ncv = getSplineNumOfCV(sp) or 0
    local closed = getIsSplineClosed(sp)
    local x0, y0, z0 = getSplinePosition(sp, 0)
    local x1, y1, z1 = getSplinePosition(sp, 1)
    -- sampled bbox + curvature profile
    local minx, miny, minz = math.huge, math.huge, math.huge
    local maxx, maxy, maxz = -math.huge, -math.huge, -math.huge
    local maxCurv, sumCurv, samples = 0, 0, 40
    for i = 0, samples do
        local t = i / samples
        local x, y, z = getSplinePosition(sp, t)
        if x < minx then minx = x end
        if y < miny then miny = y end
        if z < minz then minz = z end
        if x > maxx then maxx = x end
        if y > maxy then maxy = y end
        if z > maxz then maxz = z end
        local ok, c = pcall(getSplineCurvature, sp, t)
        if ok and c ~= nil then
            c = math.abs(c)
            sumCurv = sumCurv + c
            if c > maxCurv then maxCurv = c end
        end
    end
    local attrs = {}
    local okA, nA = pcall(getNumSplineAttributes, sp)
    if okA and nA ~= nil and nA > 0 then
        for i = 0, nA - 1 do
            local okN, nm = pcall(getSplineAttributeName, sp, i)
            attrs[#attrs + 1] = okN and tostring(nm) or "?"
        end
    end
    return string.format(
        "[%d] %s\npath: %s\nlength: %sm   CVs: %d   closed: %s\nstart: (%s, %s, %s)   end: (%s, %s, %s)\n" ..
        "bbox: (%s, %s, %s) .. (%s, %s, %s)\ncurvature: max %.4f rad/m (r_min~%sm), avg %.4f\nattributes: %s",
        sp, getName(sp) or "?", nodePath(sp), fnum(len), ncv, tostring(closed),
        fnum(x0), fnum(y0), fnum(z0), fnum(x1), fnum(y1), fnum(z1),
        fnum(minx), fnum(miny), fnum(minz), fnum(maxx), fnum(maxy), fnum(maxz),
        maxCurv, maxCurv > 1e-4 and fnum(1 / maxCurv) or "inf", sumCurv / (samples + 1),
        #attrs > 0 and table.concat(attrs, ", ") or "(none)")
end

-- ---- object placement along a spline ------------------------------------------
-- Deterministic (seeded): run with commit=false to preview, then the SAME args
-- with commit=true place exactly what was previewed.
function S.placeObjects(a)
    local sp, err = needSpline(a.spline)
    if sp == nil then return "[ERR] " .. err end
    local src, err2 = S.resolveNode(a.source)
    if src == nil then return "[ERR] source: " .. err2 end
    local len = getSplineLength(sp) or 0
    if len <= 0 then return "[ERR] spline has zero length" end

    local spacing = a.spacing
    if a.count ~= nil and a.count >= 2 then spacing = len / (a.count - 1) end
    spacing = spacing or 5.0
    if spacing < 0.05 then spacing = 0.05 end

    local maxCount = a.maxCount or 2000
    local terr = findTerrain()
    local snap = (a.terrainSnap ~= false)
    if snap and terr == nil then return "[ERR] terrainSnap requested but no terrain node found" end
    local yOff = a.yOffset or 0
    local lateral = a.lateral or 0
    local latJit = a.lateralJitter or 0
    local yawMode = a.yawMode or "spline"          -- "spline" | "keep" | "random"
    local yawJit = math.rad(a.yawJitterDeg or 0)
    local yawAdd = math.rad(a.yawAddDeg or 0)
    seedRng(a.seed)

    local srx, sry, srz = getWorldRotation(src)
    local placements = {}
    local hitCap = false
    walkSpline(sp, spacing, maxCount + 1, function(t, x, y, z, dx, dy, dz)
        if #placements >= maxCount then hitCap = true return end
        local lx, lz = leftVec(dx, dz)
        if lx == nil then return end
        local lat = lateral + (latJit ~= 0 and (math.random() * 2 - 1) * latJit or 0)
        local px, pz = x + lx * lat, z + lz * lat
        local py = y
        if snap then py = getTerrainHeightAtWorldPos(terr, px, 0, pz) end
        py = py + yOff
        local ry
        if yawMode == "keep" then
            ry = sry
        elseif yawMode == "random" then
            ry = math.random() * 2 * math.pi
        else
            ry = math.atan2(dx, dz)                -- yaw follows the spline tangent
        end
        ry = ry + yawAdd + (yawJit ~= 0 and (math.random() * 2 - 1) * yawJit or 0)
        placements[#placements + 1] = { px, py, pz, srx, ry, srz }
    end)

    -- closed spline: t=0 and t=1 are the same point -- drop the duplicate
    if getIsSplineClosed(sp) and #placements > 1 then
        local f, l = placements[1], placements[#placements]
        local d = math.sqrt((f[1]-l[1])^2 + (f[3]-l[3])^2)
        if d < spacing * 0.5 then table.remove(placements) end
    end
    if #placements == 0 then return "[ERR] no valid placements computed" end

    -- descendant count warning: past lesson is clone LEAF meshes, not prefab groups
    local descendants = 0
    local function countDesc(n) for i = 0, getNumOfChildren(n) - 1 do descendants = descendants + 1 countDesc(getChildAt(n, i)) end end
    countDesc(src)

    local head = string.format(
        "%s %d x '%s' along [%d] %s  (spacing %sm over %sm%s, yawMode=%s, seed=%d)%s%s",
        a.commit and "PLACED" or "PREVIEW:", #placements, getName(src) or "?", sp, getName(sp) or "?",
        fnum(spacing), fnum(len), snap and ", terrain-snapped" or "", yawMode, a.seed or 1234,
        hitCap and ("\nWARNING: capped at maxCount=" .. maxCount) or "",
        descendants > 50 and ("\nWARNING: source has " .. descendants ..
            " descendants -- past lesson: clone leaf meshes, not prefab groups") or "")

    if not a.commit then
        local out = { head, "first placements (x, y, z, yawDeg):" }
        for i = 1, math.min(5, #placements) do
            local p = placements[i]
            out[#out + 1] = string.format("  %2d: (%s, %s, %s, %s)", i, fnum(p[1]), fnum(p[2]), fnum(p[3]), fnum(math.deg(p[5])))
        end
        out[#out + 1] = "re-run with commit=true (same seed) to place exactly this."
        return table.concat(out, "\n")
    end

    local grpName = a.groupName or ("MCP_" .. (getName(src) or "obj") .. "_along_" .. (getName(sp) or "spline"))
    local grp = createTransformGroup(grpName)
    link(getRootNode(), grp)
    local wsx, wsy, wsz = worldScale(src)
    local baseName = getName(src) or "obj"
    for i, p in ipairs(placements) do
        local c = clone(src, true, false, false)
        link(grp, c)                                -- link keeps LOCAL transform; world pose is set below
        setName(c, baseName .. "_" .. i)
        setScale(c, wsx, wsy, wsz)                  -- group is identity, so bake the source's world scale
        setWorldTranslation(c, p[1], p[2], p[3])
        setWorldRotation(c, p[4], p[5], p[6])
    end
    return head .. string.format("\ngroup: [%d] %s (under scene root) -- delete this one group to undo", grp, grpName)
end

-- ---- terrain texture painting along a spline ----------------------------------
function S.paintTerrain(a)
    local sp, err = needSpline(a.spline)
    if sp == nil then return "[ERR] " .. err end
    local terr = findTerrain()
    if terr == nil then return "[ERR] no terrain node found" end

    local numLayers = getTerrainNumOfLayers(terr)
    local function layerIdx(spec)
        if spec == nil then return nil end
        if type(spec) == "number" then
            if spec >= 0 and spec < numLayers then return spec end
            return nil
        end
        local want = string.lower(tostring(spec))
        for i = 0, numLayers - 1 do
            if string.lower(getTerrainLayerName(terr, i)) == want then return i end
        end
        return nil
    end
    local centre = layerIdx(a.layer)
    if centre == nil then
        local names = {}
        for i = 0, numLayers - 1 do names[#names + 1] = i .. "=" .. getTerrainLayerName(terr, i) end
        return "[ERR] unknown layer '" .. tostring(a.layer) .. "'. Layers:\n  " .. table.concat(names, ", ")
    end
    local edge = layerIdx(a.edgeLayer)               -- optional shoulder texture

    local width = a.width or 4.0
    local edgeW = (edge ~= nil) and (a.edgeWidth or 2.0) or 0
    local offset = a.offset or 0
    local stepAcross = a.stepAcross or 0.5           -- ~ weightmap pixel (2048m/4096px)
    local stepAlongMax = a.stepAlong or stepAcross
    local halfC = width * 0.5
    local maxExt = halfC + edgeW
    local len = getSplineLength(sp) or 0
    if len <= 0 then return "[ERR] spline has zero length" end

    -- op estimate before touching anything
    local estRows = len / math.max(stepAlongMax * 0.5, 0.05)   -- adaptive step can halve
    local estOps = estRows * (2 * maxExt / stepAcross + 1)
    local cap = a.maxOps or 400000
    local msg = string.format("band %sm wide (+%sm edge) x %sm long, ~%d paint ops",
        fnum(width), fnum(edgeW), fnum(len), estOps)
    if estOps > cap then
        return "[REFUSED] " .. msg .. " exceeds maxOps=" .. cap ..
               ". Raise stepAcross/stepAlong, paint a shorter spline, or pass maxOps higher."
    end
    if not a.commit then
        return "PREVIEW: would paint " .. msg .. "\ncentre layer " .. centre .. " (" .. getTerrainLayerName(terr, centre) .. ")" ..
               (edge ~= nil and ("  edge layer " .. edge .. " (" .. getTerrainLayerName(terr, edge) .. ")") or "") ..
               "\nre-run with commit=true to paint. NOTE: terrain paint has no scripted undo -- save beforehand if unsure."
    end

    local ops = 0
    local t, finished = 0.0, false
    local guard = 0
    while not finished and guard < 500000 do
        guard = guard + 1
        local x, y, z = getSplinePosition(sp, t)
        local dx, dy, dz = getSplineDirection(sp, t)
        local lx, lz = leftVec(dx, dz)
        if lx ~= nil then
            local bx, bz = x + lx * offset, z + lz * offset
            local d = 0.0
            while d <= maxExt do
                local li = (d <= halfC or edge == nil) and centre or edge
                setTerrainLayerAtWorldPos(terr, li, bx + lx * d, y, bz + lz * d, 128.0)
                ops = ops + 1
                if d > 0 then
                    setTerrainLayerAtWorldPos(terr, li, bx - lx * d, y, bz - lz * d, 128.0)
                    ops = ops + 1
                end
                d = d + stepAcross
            end
        end
        -- adaptive along-step: tighten on bends so the outer edge has no gaps
        local okC, kappa = pcall(getSplineCurvature, sp, t)
        kappa = (okC and kappa ~= nil) and math.abs(kappa) or 0
        local stepAlong = stepAlongMax / (1.0 + maxExt * kappa)
        if stepAlong < 0.05 then stepAlong = 0.05 end
        local _, _, _, nt = getSplinePositionWithDistance(sp, t, stepAlong, true, 0.0005)
        if nt == nil or nt <= t then nt = t + stepAlong / len end
        t = nt
        if t >= 1.0 then t = 1.0 finished = true end
    end
    return "PAINTED " .. msg .. " (" .. ops .. " actual ops)"
end

-- ---- foliage painting along a spline -------------------------------------------
-- DensityMapModifier on the layer's data plane; the proven per-step pattern from
-- the foliage panel: one cross-band parallelogram per sample, executeSet(state).
function S.paintFoliage(a)
    local sp, err = needSpline(a.spline)
    if sp == nil then return "[ERR] " .. err end
    local terr = findTerrain()
    if terr == nil then return "[ERR] no terrain node found" end
    local layerName = tostring(a.layer or "")
    if layerName == "" then return "[ERR] layer (foliage layer name, e.g. 'decoBush') is required" end
    local plane = getTerrainDataPlaneByName(terr, layerName)
    if plane == nil or plane == 0 then
        return "[ERR] foliage layer '" .. layerName .. "' not found on terrain (exact name from the map's FoliageSystem, e.g. 'decoBush', 'grassDense')"
    end
    local state = a.state
    if state == nil then return "[ERR] state (foliage state value, e.g. 2) is required" end

    local width = a.width or 3.0
    local offset = a.offset or 0
    local spacing = a.spacing or 0.5
    if spacing < 0.05 then spacing = 0.05 end
    local jit = a.lateralJitter or 0
    seedRng(a.seed)
    local len = getSplineLength(sp) or 0
    if len <= 0 then return "[ERR] spline has zero length" end

    local estSteps = math.floor(len / spacing) + 1
    local cap = a.maxOps or 20000                     -- heavy executeSet loops have crashed GE before: keep chunks sane
    local msg = string.format("foliage '%s' state %d, band %sm x %sm, ~%d steps @ %sm",
        layerName, state, fnum(width), fnum(len), estSteps, fnum(spacing))
    if estSteps > cap then
        return "[REFUSED] " .. msg .. " exceeds maxOps=" .. cap ..
               ". Paint in chunks: raise spacing, or run twice with fromT/toT (e.g. fromT=0,toT=0.5 then 0.5,1)."
    end
    if not a.commit then
        return "PREVIEW: " .. msg .. "\nre-run with commit=true to paint. NOTE: no scripted undo -- save beforehand if unsure. If coverage looks striped, lower spacing to ~0.25."
    end

    local modifier = DensityMapModifier.new(plane, a.firstChannel or 0, a.numChannels or 4, terr)
    local halfW = width * 0.5
    local fromT = a.fromT or 0.0
    local toT = a.toT or 1.0
    local ops = 0
    local stMin, stMax = a.stateMin, a.stateMax       -- optional random state range
    local t, finished = fromT, false
    while not finished and ops < cap + 2 do
        local x, y, z = getSplinePosition(sp, t)
        local dx, dy, dz = getSplineDirection(sp, t)
        local lx, lz = leftVec(dx, dz)
        if lx ~= nil then
            local lat = offset + (jit ~= 0 and (math.random() * 2 - 1) * jit or 0)
            local cx, cz = x + lx * lat, z + lz * lat
            local p1x, p1z = cx + lx * halfW, cz + lz * halfW
            local p2x, p2z = cx - lx * halfW, cz - lz * halfW
            local st = state
            if stMin ~= nil and stMax ~= nil and stMax >= stMin then st = math.random(stMin, stMax) end
            modifier:setParallelogramWorldCoords(cx, cz, p1x, p1z, p2x, p2z, DensityCoordType.POINT_POINT_POINT)
            modifier:executeSet(st)
            ops = ops + 1
        end
        local _, _, _, nt = getSplinePositionWithDistance(sp, t, spacing, true, 0.0005)
        if nt == nil or nt <= t then nt = t + spacing / len end
        t = nt
        if t >= toT then finished = true end
    end
    return "PAINTED " .. msg .. " (" .. ops .. " executeSet calls, t=" .. fnum(fromT) .. ".." .. fnum(toT) .. ")"
end

-- ---- terrain height shaping along a spline (absolute, to the spline's Y) -------
-- profile "flat": road bed -- core band takes splineY (+yOffset), edges blend out.
-- profile "u":    riverbed -- cosine bowl `depth` deep at the centerline, rising
--                 to splineY at the band edges (draw the spline at the waterline).
-- profile "v":    ditch/creek -- linear V, `depth` at center.
function S.alignTerrainToSpline(a)
    local sp, err = needSpline(a.spline)
    if sp == nil then return "[ERR] " .. err end
    local terr = findTerrain()
    if terr == nil then return "[ERR] no terrain node found" end
    local width = a.width or 6.0
    local edgeW = a.edgeWidth or 4.0
    local yOff = a.yOffset or 0
    local offset = a.offset or 0
    local step = a.step or 0.5
    local profile = a.profile or "flat"
    local depth = a.depth or 0
    if profile ~= "flat" and depth <= 0 then
        return "[ERR] profile '" .. profile .. "' needs depth > 0"
    end
    local halfC = width * 0.5
    local maxExt = halfC + edgeW
    local len = getSplineLength(sp) or 0
    if len <= 0 then return "[ERR] spline has zero length" end

    local estOps = (len / step) * (2 * maxExt / step + 1)
    local cap = a.maxOps or 400000
    local msg = string.format("height %s band %sm (+%sm blend) x %sm%s, ~%d ops",
        profile, fnum(width), fnum(edgeW), fnum(len),
        profile ~= "flat" and (", depth " .. fnum(depth) .. "m") or "", estOps)
    if estOps > cap then
        return "[REFUSED] " .. msg .. " exceeds maxOps=" .. cap .. ". Raise step, shorten the spline, or pass maxOps higher."
    end
    if not a.commit then
        return "PREVIEW: " .. msg .. "\nCore band shaped to splineY" .. (yOff ~= 0 and (string.format("%+.2f", yOff)) or "") ..
               (profile == "u" and " (cosine bowl below it)" or (profile == "v" and " (V cut below it)" or "")) ..
               "; edges blend into existing terrain.\nre-run with commit=true. NOTE: no scripted undo -- save beforehand if unsure."
    end

    -- TWO-PHASE: collect every cell + all terrain READS first, then write.
    -- Heightmap vertices are coarser than the sampling grid, so writing while
    -- still reading lets later reads see earlier writes through vertex aliasing
    -- (verified live: a 0.8m relative lower compounded to 1.7m). Reads-then-
    -- writes makes every value derive from the pristine terrain.
    local cxs, czs, chs = {}, {}, {}
    local nCells = 0
    local visited = {}
    local t, finished = 0.0, false
    while not finished do
        local x, y, z = getSplinePosition(sp, t)
        local dx, dy, dz = getSplineDirection(sp, t)
        local lx, lz = leftVec(dx, dz)
        if lx ~= nil then
            local target = y + yOff
            local bx, bz = x + lx * offset, z + lz * offset
            local d = 0.0
            while d <= maxExt do
                local function collectAt(px, pz)
                    local key = math.floor(px / step + 0.5) .. ":" .. math.floor(pz / step + 0.5)
                    if visited[key] then return end
                    visited[key] = true
                    local h
                    if d <= halfC then
                        h = target
                        if profile == "u" and halfC > 0.01 then
                            h = target - depth * math.cos((d / halfC) * math.pi * 0.5)
                        elseif profile == "v" and halfC > 0.01 then
                            h = target - depth * (1 - d / halfC)
                        end
                    else
                        local alpha = (d - halfC) / math.max(edgeW, 0.01)
                        local existing = getTerrainHeightAtWorldPos(terr, px, 0, pz)
                        h = target * (1 - alpha) + existing * alpha
                    end
                    nCells = nCells + 1
                    cxs[nCells], czs[nCells], chs[nCells] = px, pz, h
                end
                collectAt(bx + lx * d, bz + lz * d)
                if d > 0 then collectAt(bx - lx * d, bz - lz * d) end
                d = d + step
            end
        end
        local _, _, _, nt = getSplinePositionWithDistance(sp, t, step, true, 0.0005)
        if nt == nil or nt <= t then nt = t + step / len end
        t = nt
        if t >= 1.0 then t = 1.0 finished = true end
    end
    for i = 1, nCells do
        setTerrainHeightAtWorldPos(terr, cxs[i], 0, czs[i], chs[i])
    end
    return "SHAPED " .. msg .. " (" .. nCells .. " cells written)"
end

-- ---- relative terrain adjust along a spline (works off EXISTING ground) --------
-- mode "lower": dig `depth` below the current ground along the path (quick rivers/
--               creeks -- no need to draw the spline at a careful height).
-- mode "raise": levee / berm / dam.
-- mode "smooth": relax each cell toward its neighbours' average (soften banks).
-- Cells are deduped on a `step` grid, so bends and overlaps do NOT compound --
-- which also makes lower followed by raise (same args) restore the original.
function S.adjustTerrainAlongSpline(a)
    local sp, err = needSpline(a.spline)
    if sp == nil then return "[ERR] " .. err end
    local terr = findTerrain()
    if terr == nil then return "[ERR] no terrain node found" end
    local mode = a.mode or "lower"
    if mode ~= "lower" and mode ~= "raise" and mode ~= "smooth" then
        return "[ERR] mode must be lower | raise | smooth"
    end
    local depth = a.depth or 1.5
    local strength = a.strength or 0.5
    local width = a.width or 6.0
    local edgeW = a.edgeWidth or 4.0
    local offset = a.offset or 0
    local step = a.step or 0.5
    local radius = (a.radius ~= nil and a.radius > 0) and a.radius or (step * 3)
    local halfC = width * 0.5
    local maxExt = halfC + edgeW
    local len = getSplineLength(sp) or 0
    if len <= 0 then return "[ERR] spline has zero length" end

    local estOps = (len / step) * (2 * maxExt / step + 1)
    local cap = a.maxOps or 400000
    local msg = string.format("%s band %sm (+%sm falloff) x %sm, %s, ~%d cells",
        mode, fnum(width), fnum(edgeW), fnum(len),
        mode == "smooth" and ("strength " .. fnum(strength)) or ("depth " .. fnum(depth) .. "m"), estOps)
    if estOps > cap then
        return "[REFUSED] " .. msg .. " exceeds maxOps=" .. cap .. ". Raise step, shorten the spline, or pass maxOps higher."
    end
    if not a.commit then
        return "PREVIEW: " .. msg .. " (relative to the EXISTING ground; deduped per cell)" ..
               "\nre-run with commit=true. NOTE: no scripted undo, but lower<->raise with identical args invert each other."
    end

    -- TWO-PHASE (see alignTerrainToSpline): ALL reads happen against the
    -- pristine terrain, then all writes -- otherwise heightmap-vertex aliasing
    -- compounds relative ops and lower/raise stop being inverses.
    local cxs, czs, chs = {}, {}, {}
    local nCells = 0
    local visited = {}
    local t, finished = 0.0, false
    while not finished do
        local x, _, z = getSplinePosition(sp, t)
        local dx, _, dz = getSplineDirection(sp, t)
        local lx, lz = leftVec(dx, dz)
        if lx ~= nil then
            local bx, bz = x + lx * offset, z + lz * offset
            local d = 0.0
            while d <= maxExt do
                local function collectAt(px, pz)
                    local key = math.floor(px / step + 0.5) .. ":" .. math.floor(pz / step + 0.5)
                    if visited[key] then return end
                    visited[key] = true
                    -- cosine falloff: full effect in the core, easing to 0 at the rim
                    local f = 1.0
                    if d > halfC then
                        f = 0.5 * (1 + math.cos(((d - halfC) / math.max(edgeW, 0.01)) * math.pi))
                    end
                    local existing = getTerrainHeightAtWorldPos(terr, px, 0, pz)
                    local h
                    if mode == "lower" then
                        h = existing - depth * f
                    elseif mode == "raise" then
                        h = existing + depth * f
                    else
                        local avg = (getTerrainHeightAtWorldPos(terr, px + radius, 0, pz)
                                   + getTerrainHeightAtWorldPos(terr, px - radius, 0, pz)
                                   + getTerrainHeightAtWorldPos(terr, px, 0, pz + radius)
                                   + getTerrainHeightAtWorldPos(terr, px, 0, pz - radius)) * 0.25
                        h = existing + (avg - existing) * strength * f
                    end
                    nCells = nCells + 1
                    cxs[nCells], czs[nCells], chs[nCells] = px, pz, h
                end
                collectAt(bx + lx * d, bz + lz * d)
                if d > 0 then collectAt(bx - lx * d, bz - lz * d) end
                d = d + step
            end
        end
        local _, _, _, nt = getSplinePositionWithDistance(sp, t, step, true, 0.0005)
        if nt == nil or nt <= t then nt = t + step / len end
        t = nt
        if t >= 1.0 then t = 1.0 finished = true end
    end
    for i = 1, nCells do
        setTerrainHeightAtWorldPos(terr, cxs[i], 0, czs[i], chs[i])
    end
    return "ADJUSTED " .. msg .. " (" .. nCells .. " cells written)"
end

-- ---- drop nodes onto the terrain -----------------------------------------------
function S.alignToTerrain(a)
    local id, err = S.resolveNode(a.node)
    if id == nil then return "[ERR] " .. err end
    local terr = findTerrain()
    if terr == nil then return "[ERR] no terrain node found" end
    if id == terr then return "[ERR] refusing to move the terrain node itself" end
    local yOff = a.yOffset or 0
    local targets = {}
    if a.children ~= false and getNumOfChildren(id) > 0 then
        for i = 0, getNumOfChildren(id) - 1 do targets[#targets + 1] = getChildAt(id, i) end
    else
        targets[1] = id
    end
    local moved, maxDelta = 0, 0
    local rows = {}
    for _, n in ipairs(targets) do
        local wx, wy, wz = getWorldTranslation(n)
        local h = getTerrainHeightAtWorldPos(terr, wx, 0, wz) + yOff
        local dyy = h - wy
        if math.abs(dyy) > 0.001 then
            moved = moved + 1
            if math.abs(dyy) > math.abs(maxDelta) then maxDelta = dyy end
            if a.commit then setWorldTranslation(n, wx, h, wz) end
            if #rows < 8 then
                rows[#rows + 1] = string.format("  [%d] %s  y %s -> %s (%s%s)", n, getName(n) or "?",
                    fnum(wy), fnum(h), dyy >= 0 and "+" or "", fnum(dyy))
            end
        end
    end
    local head = string.format("%s %d/%d node(s) under '%s'%s  (max dY %s%s)",
        a.commit and "MOVED" or "WOULD MOVE", moved, #targets, getName(id) or "?",
        yOff ~= 0 and (string.format(" yOffset=%+.2f", yOff)) or "",
        maxDelta >= 0 and "+" or "", fnum(maxDelta))
    if #rows > 0 then head = head .. "\n" .. table.concat(rows, "\n") end
    if moved > 8 then head = head .. "\n  ..." end
    if not a.commit then head = head .. "\nre-run with commit=true to apply." end
    return head
end

-- ============================================================================
--  v2 additions: node lifecycle, transforms, camera, selection
-- ============================================================================

-- merged world-space bounding sphere over all shapes under a node
-- (getShapeBoundingSphere is local-space: center via localToWorld)
local function mergedSphere(node)
    local minx, miny, minz = math.huge, math.huge, math.huge
    local maxx, maxy, maxz = -math.huge, -math.huge, -math.huge
    local found, scanned = false, 0
    local function walk(n)
        if scanned > 800 then return end
        scanned = scanned + 1
        -- MESH shapes only: getShapeBoundingSphere on a spline-geometry shape is
        -- a native-crash suspect (GE died mid-scan on the fields subtree once;
        -- pcall cannot catch an engine segfault). isSplineShape excludes them.
        local ok, isShape = pcall(getHasClassId, n, ClassIds.SHAPE)
        if ok and isShape and not isSplineShape(n) then
            local okS, cx, cy, cz, r = pcall(getShapeBoundingSphere, n)
            if okS and r ~= nil then
                local wx, wy, wz = localToWorld(n, cx, cy, cz)
                -- expand by radius scaled with the largest axis scale up the chain
                local sx, sy, sz = 1, 1, 1
                local p = n
                while p ~= nil and p ~= 0 do
                    local okc, ax, ay, az = pcall(getScale, p)
                    if okc and ax ~= nil then sx, sy, sz = sx * ax, sy * ay, sz * az end
                    local okp, pp = pcall(getParent, p)
                    if not okp or pp == nil or pp == 0 or pp == p then break end
                    p = pp
                end
                local wr = r * math.max(sx, sy, sz)
                found = true
                if wx - wr < minx then minx = wx - wr end
                if wy - wr < miny then miny = wy - wr end
                if wz - wr < minz then minz = wz - wr end
                if wx + wr > maxx then maxx = wx + wr end
                if wy + wr > maxy then maxy = wy + wr end
                if wz + wr > maxz then maxz = wz + wr end
            end
        end
        for i = 0, getNumOfChildren(n) - 1 do walk(getChildAt(n, i)) end
    end
    walk(node)
    if not found then return nil end
    local cx, cy, cz = (minx + maxx) / 2, (miny + maxy) / 2, (minz + maxz) / 2
    local r = math.sqrt((maxx - cx) ^ 2 + (maxy - cy) ^ 2 + (maxz - cz) ^ 2)
    return cx, cy, cz, r
end

-- NOTE: no user-attribute enumeration here. getUserAttributeByIndex is
-- undocumented with unknown arity and is a native-crash suspect (GE died on the
-- first nodeInfo call that used it; a pcall cannot catch an engine segfault).
-- Known-name reads via getUserAttribute(id, "onCreate") are safe when needed.

function S.nodeInfo(a)
    local id, err = S.resolveNode(a.node)
    if id == nil then return "[ERR] " .. err end
    local wx, wy, wz = getWorldTranslation(id)
    local lx, ly, lz = getTranslation(id)
    local wrx, wry, wrz = getWorldRotation(id)
    local sx, sy, sz = getScale(id)
    local out = {
        string.format("[%d] %s  (%s)", id, getName(id) or "?", classStr(id)),
        "path: " .. nodePath(id),
        string.format("world: (%s, %s, %s)   local: (%s, %s, %s)",
            fnum(wx), fnum(wy), fnum(wz), fnum(lx), fnum(ly), fnum(lz)),
        string.format("worldRot(deg): (%s, %s, %s)   scale: (%s, %s, %s)",
            fnum(math.deg(wrx)), fnum(math.deg(wry)), fnum(math.deg(wrz)), fnum(sx), fnum(sy), fnum(sz)),
    }
    local okV, vis = pcall(getVisibility, id)
    local okC, clip = pcall(getClipDistance, id)
    local okR, rigid = pcall(getRigidBodyType, id)
    out[#out + 1] = string.format("visible: %s   clipDistance: %s   rigidBody: %s   children: %d",
        okV and tostring(vis) or "?", okC and fnum(clip) or "?",
        okR and tostring(rigid) or "?", getNumOfChildren(id))
    if a.bounds == true then                     -- opt-in: mesh-shape walk
        local cx, cy, cz, r = mergedSphere(id)
        if cx ~= nil then
            out[#out + 1] = string.format("bounds: center (%s, %s, %s) radius %sm", fnum(cx), fnum(cy), fnum(cz), fnum(r))
        else
            out[#out + 1] = "bounds: no mesh shapes underneath"
        end
    end
    local okA, onCreate = pcall(getUserAttribute, id, "onCreate")
    if okA and onCreate ~= nil then out[#out + 1] = "userAttributes: onCreate=" .. tostring(onCreate) end
    return table.concat(out, "\n")
end

function S.setTransform(a)
    local id, err = S.resolveNode(a.node)
    if id == nil then return "[ERR] " .. err end
    if id == getRootNode() or id == findTerrain() then return "[ERR] refusing to move the scene root / terrain" end
    local wx, wy, wz = getWorldTranslation(id)
    local wrx, wry, wrz = getWorldRotation(id)
    local osx, osy, osz = getScale(id)
    local before = string.format("was: pos (%s, %s, %s)  rot (%s, %s, %s)  scale (%s, %s, %s)",
        fnum(wx), fnum(wy), fnum(wz), fnum(math.deg(wrx)), fnum(math.deg(wry)), fnum(math.deg(wrz)),
        fnum(osx), fnum(osy), fnum(osz))
    local rel = a.relative == true
    if a.x ~= nil or a.y ~= nil or a.z ~= nil then
        local nx = a.x ~= nil and (rel and wx + a.x or a.x) or wx
        local ny = a.y ~= nil and (rel and wy + a.y or a.y) or wy
        local nz = a.z ~= nil and (rel and wz + a.z or a.z) or wz
        setWorldTranslation(id, nx, ny, nz)
    end
    if a.rxDeg ~= nil or a.ryDeg ~= nil or a.rzDeg ~= nil then
        local nrx = a.rxDeg ~= nil and (rel and wrx + math.rad(a.rxDeg) or math.rad(a.rxDeg)) or wrx
        local nry = a.ryDeg ~= nil and (rel and wry + math.rad(a.ryDeg) or math.rad(a.ryDeg)) or wry
        local nrz = a.rzDeg ~= nil and (rel and wrz + math.rad(a.rzDeg) or math.rad(a.rzDeg)) or wrz
        setWorldRotation(id, nrx, nry, nrz)
    end
    if a.sx ~= nil or a.sy ~= nil or a.sz ~= nil then
        local s = a.sx or a.sy or a.sz
        setScale(id, a.sx or (a.uniform and s) or osx,
                     a.sy or (a.uniform and s) or osy,
                     a.sz or (a.uniform and s) or osz)
    end
    local ax, ay, az = getWorldTranslation(id)
    local arx, ary, arz = getWorldRotation(id)
    local asx, asy, asz = getScale(id)
    return string.format("[%d] %s updated\n%s\nnow: pos (%s, %s, %s)  rot (%s, %s, %s)  scale (%s, %s, %s)",
        id, getName(id) or "?", before, fnum(ax), fnum(ay), fnum(az),
        fnum(math.deg(arx)), fnum(math.deg(ary)), fnum(math.deg(arz)), fnum(asx), fnum(asy), fnum(asz))
end

function S.nodeProps(a)
    local id, err = S.resolveNode(a.node)
    if id == nil then return "[ERR] " .. err end
    local done = {}
    if a.name ~= nil and a.name ~= "" then
        local old = getName(id)
        setName(id, a.name)
        done[#done + 1] = "renamed '" .. tostring(old) .. "' -> '" .. a.name .. "'"
    end
    local targets = { id }
    if a.recursive == true then
        local function walk(n) for i = 0, getNumOfChildren(n) - 1 do local c = getChildAt(n, i) targets[#targets + 1] = c walk(c) end end
        walk(id)
    end
    if a.visible ~= nil then
        for _, n in ipairs(targets) do setVisibility(n, a.visible == true) end
        done[#done + 1] = "visibility=" .. tostring(a.visible) .. " on " .. #targets .. " node(s)"
    end
    if a.clipDistance ~= nil then
        for _, n in ipairs(targets) do setClipDistance(n, a.clipDistance) end
        done[#done + 1] = "clipDistance=" .. fnum(a.clipDistance) .. " on " .. #targets .. " node(s)"
    end
    if #done == 0 then return "[ERR] nothing to do (pass name / visible / clipDistance)" end
    return "[" .. id .. "] " .. (getName(id) or "?") .. ": " .. table.concat(done, "; ")
end

function S.createGroup(a)
    local parent = getRootNode()
    if a.parent ~= nil and a.parent ~= "" then
        local p, err = S.resolveNode(a.parent)
        if p == nil then return "[ERR] parent: " .. err end
        parent = p
    end
    local g = createTransformGroup(a.name or "MCP_group")
    link(parent, g)
    if a.x ~= nil and a.y ~= nil and a.z ~= nil then setWorldTranslation(g, a.x, a.y, a.z) end
    local wx, wy, wz = getWorldTranslation(g)
    return string.format("created [%d] %s under [%d] %s at (%s, %s, %s)",
        g, getName(g), parent, getName(parent) or "?", fnum(wx), fnum(wy), fnum(wz))
end

-- Deletion with the crash guards baked in: NEVER delete a selected node
-- (dangling selection ref crashes GE) -- selection is cleared first; protected
-- nodes (root/terrain/active camera) are refused; ids re-checked via entityExists.
function S.safeDelete(a)
    local specs = {}
    for s in string.gmatch(tostring(a.nodes or ""), "[^,]+") do
        s = s:match("^%s*(.-)%s*$")
        if s ~= "" then specs[#specs + 1] = s end
    end
    if #specs == 0 then return "[ERR] pass nodes as a comma-separated list of ids/names" end
    local ids, out = {}, {}
    local terr = findTerrain()
    local cam = getCamera and getCamera() or nil
    for _, s in ipairs(specs) do
        local id, err = S.resolveNode(tonumber(s) or s)
        if id == nil then
            out[#out + 1] = "  skip '" .. s .. "': " .. err
        elseif id == getRootNode() then
            out[#out + 1] = "  REFUSED '" .. s .. "': scene root"
        elseif id == terr then
            out[#out + 1] = "  REFUSED '" .. s .. "': terrain node"
        elseif id == cam then
            out[#out + 1] = "  REFUSED '" .. s .. "': active camera"
        else
            ids[#ids + 1] = id
        end
    end
    if not a.commit then
        for _, id in ipairs(ids) do
            out[#out + 1] = string.format("  would delete [%d] %s (%s, %d children)",
                id, getName(id) or "?", classStr(id), getNumOfChildren(id))
        end
        return "PREVIEW safe_delete:\n" .. table.concat(out, "\n") .. "\nre-run with commit=true to delete."
    end
    clearSelection()          -- the crash guard: no node may be selected while script-deleted
    local n = 0
    for _, id in ipairs(ids) do
        if entityExists(id) then
            local nm = getName(id) or "?"
            delete(id)
            n = n + 1
            out[#out + 1] = "  deleted [" .. id .. "] " .. nm .. (entityExists(id) and "  (STILL EXISTS?)" or "")
        end
    end
    return "safe_delete: " .. n .. " node(s) deleted (selection cleared first)\n" .. table.concat(out, "\n")
end

-- World-preserving reparent: bake world transform + scale product, link, restore.
-- (Plain link() keeps LOCAL values, so the node would jump.)
function S.reparentWorld(a)
    local id, err = S.resolveNode(a.node)
    if id == nil then return "[ERR] " .. err end
    local np, err2 = S.resolveNode(a.parent)
    if np == nil then return "[ERR] parent: " .. err2 end
    if id == getRootNode() then return "[ERR] cannot reparent the scene root" end
    -- refuse making a node a child of its own descendant
    local p = np
    while p ~= nil and p ~= 0 do
        if p == id then return "[ERR] target parent is inside the node's own subtree" end
        local ok, pp = pcall(getParent, p)
        if not ok or pp == nil or pp == 0 or pp == p then break end
        p = pp
    end
    local oldParent = getParent(id)
    local olx, oly, olz = getTranslation(id)
    local olrx, olry, olrz = getRotation(id)
    local osx, osy, osz = getScale(id)
    local wx, wy, wz = getWorldTranslation(id)
    local wrx, wry, wrz = getWorldRotation(id)
    local nsx, nsy, nsz = worldScale(id)          -- world scale product incl the node
    local psx, psy, psz = worldScale(np)          -- new parent's world scale product
    local warn = ""
    if math.abs(psx - psy) > 1e-4 or math.abs(psy - psz) > 1e-4 then
        warn = "\nWARNING: new parent chain has NON-UNIFORM scale -- rotation under it shears geometry."
    end
    link(np, id)
    setScale(id, nsx / psx, nsy / psy, nsz / psz)
    setWorldTranslation(id, wx, wy, wz)
    setWorldRotation(id, wrx, wry, wrz)
    local ax, ay, az = getWorldTranslation(id)
    local d = math.sqrt((ax - wx) ^ 2 + (ay - wy) ^ 2 + (az - wz) ^ 2)
    if d > 0.1 then
        -- restore everything and report instead of leaving a jumped node
        link(oldParent, id)
        setTranslation(id, olx, oly, olz)
        setRotation(id, olrx, olry, olrz)
        setScale(id, osx, osy, osz)
        return string.format("[REVERTED] world position drifted %.3fm after reparent (shear/scale mismatch); node restored to its old parent.", d)
    end
    return string.format("reparented [%d] %s -> under [%d] %s  (world pose preserved, drift %.4fm)%s",
        id, getName(id) or "?", np, getName(np) or "?", d, warn)
end

function S.randomizeTransforms(a)
    local id, err = S.resolveNode(a.node)
    if id == nil then return "[ERR] " .. err end
    local n = getNumOfChildren(id)
    if n == 0 then return "[ERR] '" .. (getName(id) or "?") .. "' has no children" end
    seedRng(a.seed)
    local yawJ = math.rad(a.yawJitterDeg or 360)
    local tiltJ = math.rad(a.tiltJitterDeg or 0)
    local sMin = a.scaleMin or 1.0
    local sMax = a.scaleMax or 1.0
    local yJ = a.yJitter or 0
    local rows = {}
    for i = 0, n - 1 do
        local c = getChildAt(id, i)
        local ry = (math.random() * 2 - 1) * yawJ
        local rx = (math.random() * 2 - 1) * tiltJ
        local rz = (math.random() * 2 - 1) * tiltJ
        local s = sMin + math.random() * (sMax - sMin)
        local dy = (math.random() * 2 - 1) * yJ
        if a.commit then
            local wrx, wry, wrz = getWorldRotation(c)
            setWorldRotation(c, wrx + rx, wry + ry, wrz + rz)
            if sMin ~= 1.0 or sMax ~= 1.0 then
                local sx, sy, sz = getScale(c)
                setScale(c, sx * s, sy * s, sz * s)
            end
            if yJ ~= 0 then
                local wx, wy, wz = getWorldTranslation(c)
                setWorldTranslation(c, wx, wy + dy, wz)
            end
        end
        if #rows < 5 then
            rows[#rows + 1] = string.format("  %s: yaw%+.0f tilt(%+.1f,%+.1f) scale x%.2f dy%+.2f",
                getName(c) or i, math.deg(ry), math.deg(rx), math.deg(rz), s, dy)
        end
    end
    local head = string.format("%s %d children of [%d] %s  (yaw±%.0f°, tilt±%.1f°, scale %.2f..%.2f, dy±%.2f, seed=%d)",
        a.commit and "RANDOMIZED" or "PREVIEW (same seed on commit):", n, id, getName(id) or "?",
        math.deg(yawJ), math.deg(tiltJ), sMin, sMax, yJ, a.seed or 1234)
    return head .. "\n" .. table.concat(rows, "\n") .. (a.commit and "" or "\nre-run with commit=true to apply.")
end

function S.importI3d(a)
    local path = tostring(a.path or ""):gsub("\\", "/")
    if path == "" then return "[ERR] path required" end
    local parent = getRootNode()
    if a.parent ~= nil and a.parent ~= "" then
        local p, err = S.resolveNode(a.parent)
        if p == nil then return "[ERR] parent: " .. err end
        parent = p
    end
    local rootId, failedReason = loadI3DFile(path, false, false, false)
    if rootId == nil or rootId == 0 then
        return "[ERR] loadI3DFile failed (reason code " .. tostring(failedReason) .. ") for " .. path
    end
    link(parent, rootId)
    if a.name ~= nil and a.name ~= "" then setName(rootId, a.name) end
    if a.x ~= nil and a.y ~= nil and a.z ~= nil then setWorldTranslation(rootId, a.x, a.y, a.z) end
    local kids = {}
    for i = 0, math.min(getNumOfChildren(rootId) - 1, 9) do
        local c = getChildAt(rootId, i)
        kids[#kids + 1] = string.format("  [%d] %s (%s)", c, getName(c) or "?", classStr(c))
    end
    local wx, wy, wz = getWorldTranslation(rootId)
    return string.format("imported [%d] %s under [%d] %s at (%s, %s, %s), %d direct children:\n%s",
        rootId, getName(rootId) or "?", parent, getName(parent) or "?",
        fnum(wx), fnum(wy), fnum(wz), getNumOfChildren(rootId), table.concat(kids, "\n"))
end

-- Aim the active viewport camera at a node or position; pair with viewport_screenshot.
function S.cameraLook(a)
    local tx, ty, tz, autoDist
    if a.target ~= nil and a.target ~= "" then
        local id, err = S.resolveNode(a.target)
        if id == nil then return "[ERR] " .. err end
        local cx, cy, cz, r = mergedSphere(id)
        if cx ~= nil then
            tx, ty, tz = cx, cy, cz
            autoDist = math.max(4, math.min(r * 2.5, 1500))
        else
            tx, ty, tz = getWorldTranslation(id)
        end
    elseif a.x ~= nil and a.z ~= nil then
        tx, tz = a.x, a.z
        local terr = findTerrain()
        ty = a.y or (terr ~= nil and getTerrainHeightAtWorldPos(terr, tx, 0, tz) or 0)
    else
        return "[ERR] pass target (node) or x/z coordinates"
    end
    local dist = a.distance
    if dist == nil or dist <= 0 then dist = autoDist or 60 end
    local yaw = math.rad(a.yawDeg or 45)
    local pitch = math.rad(a.pitchDeg or 35)
    local ex = tx + math.sin(yaw) * math.cos(pitch) * dist
    local ey = ty + math.sin(pitch) * dist
    local ez = tz + math.cos(yaw) * math.cos(pitch) * dist
    local cam = getCamera()
    if cam == nil or cam == 0 then return "[ERR] no active camera" end
    setWorldTranslation(cam, ex, ey, ez)
    -- cameras look down their LOCAL -Z; setDirection aims +Z, so point +Z
    -- from the target back through the eye (aiming +Z at the target shows sky)
    local dx, dy, dz = ex - tx, ey - ty, ez - tz
    local l = math.sqrt(dx * dx + dy * dy + dz * dz)
    setDirection(cam, dx / l, dy / l, dz / l, 0, 1, 0)
    return string.format("camera [%d] %s -> eye (%s, %s, %s) looking at (%s, %s, %s), dist %sm. Take a viewport_screenshot to see it.",
        cam, getName(cam) or "?", fnum(ex), fnum(ey), fnum(ez), fnum(tx), fnum(ty), fnum(tz), fnum(dist))
end

function S.selectNodes(a)
    if a.clear == true then
        clearSelection()
        return "selection cleared"
    end
    local names = {}
    clearSelection()
    for s in string.gmatch(tostring(a.nodes or ""), "[^,]+") do
        s = s:match("^%s*(.-)%s*$")
        if s ~= "" then
            local id = S.resolveNode(tonumber(s) or s)
            if id ~= nil then
                local ok = pcall(addSelection, id)
                if ok then names[#names + 1] = "[" .. id .. "] " .. (getName(id) or "?") end
            end
        end
    end
    if #names == 0 then return "[ERR] nothing selected (no specs resolved)" end
    return "selected " .. #names .. " node(s): " .. table.concat(names, ", ")
end

-- ============================================================================
--  v7 additions: closed-spline polygon area operations
-- ============================================================================

-- sample a closed spline into an XZ polygon (duplicate closing point dropped)
local function splinePolygon(sp, step)
    local pts = {}
    walkSpline(sp, step, 100000, function(t, x, y, z)
        pts[#pts + 1] = { x, z }
    end)
    if #pts > 2 then
        local f, l = pts[1], pts[#pts]
        if math.sqrt((f[1] - l[1]) ^ 2 + (f[2] - l[2]) ^ 2) < step * 0.75 then
            table.remove(pts)
        end
    end
    return pts
end

local function polygonArea(pts)                     -- shoelace, m^2
    local a, n = 0, #pts
    for i = 1, n do
        local p, q = pts[i], pts[i % n + 1]
        a = a + p[1] * q[2] - q[1] * p[2]
    end
    return math.abs(a) * 0.5
end

local function polygonBBox(pts)
    local minx, minz, maxx, maxz = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(pts) do
        if p[1] < minx then minx = p[1] end
        if p[1] > maxx then maxx = p[1] end
        if p[2] < minz then minz = p[2] end
        if p[2] > maxz then maxz = p[2] end
    end
    return minx, minz, maxx, maxz
end

-- even-odd scanline: sorted x crossings of the polygon at row z;
-- inside intervals are (xs[1],xs[2]), (xs[3],xs[4]), ...
local function rowCrossings(pts, z)
    local xs, n = {}, #pts
    for i = 1, n do
        local a, b = pts[i], pts[i % n + 1]
        local z1, z2 = a[2], b[2]
        if (z1 <= z and z2 > z) or (z2 <= z and z1 > z) then
            local tt = (z - z1) / (z2 - z1)
            xs[#xs + 1] = a[1] + (b[1] - a[1]) * tt
        end
    end
    table.sort(xs)
    return xs
end

-- resolve a closed-ish spline for area ops (open splines are treated as closed
-- by connecting end->start; report notes it)
local function needPolygon(spec, step)
    local sp, err = needSpline(spec)
    if sp == nil then return nil, nil, err end
    local pts = splinePolygon(sp, step)
    if #pts < 3 then return nil, nil, "spline yields fewer than 3 polygon points" end
    local closedNote = getIsSplineClosed(sp) and "" or
        "\nNOTE: spline is OPEN -- treating it as closed by joining end to start."
    return sp, pts, closedNote
end

function S.terrainStats(a)
    local step = a.step or 2.0
    local sp, pts, note = needPolygon(a.spline, step)
    if sp == nil then return "[ERR] " .. note end
    local terr = findTerrain()
    if terr == nil then return "[ERR] no terrain node found" end
    local minx, minz, maxx, maxz = polygonBBox(pts)
    local area = polygonArea(pts)
    local minH, maxH, sumH, cells = math.huge, -math.huge, 0, 0
    local maxSlope, sumSlope, slopeCells = 0, 0, 0
    local z = minz + step * 0.5
    while z <= maxz do
        local xs = rowCrossings(pts, z)
        for i = 1, #xs - 1, 2 do
            local x = xs[i] + step * 0.5
            while x <= xs[i + 1] do
                local h = getTerrainHeightAtWorldPos(terr, x, 0, z)
                cells = cells + 1
                sumH = sumH + h
                if h < minH then minH = h end
                if h > maxH then maxH = h end
                local h2 = getTerrainHeightAtWorldPos(terr, x + step, 0, z)
                local h3 = getTerrainHeightAtWorldPos(terr, x, 0, z + step)
                local sl = math.max(math.abs(h2 - h), math.abs(h3 - h)) / step
                slopeCells = slopeCells + 1
                sumSlope = sumSlope + sl
                if sl > maxSlope then maxSlope = sl end
                x = x + step
            end
        end
        z = z + step
    end
    if cells == 0 then return "[ERR] no cells sampled (polygon too small for step " .. fnum(step) .. "?)" end
    return string.format(
        "terrain stats inside [%d] %s (%d boundary pts, sampled %d cells @ %sm):\n" ..
        "area: %sm2 = %.2f ha   bbox: (%s, %s)..(%s, %s)\n" ..
        "height: min %s  max %s  avg %s  (range %s)\n" ..
        "slope: avg %.1f%%  max %.1f%%%s",
        sp, getName(sp) or "?", #pts, cells, fnum(step),
        fnum(area), area / 10000, fnum(minx), fnum(minz), fnum(maxx), fnum(maxz),
        fnum(minH), fnum(maxH), fnum(sumH / cells), fnum(maxH - minH),
        (sumSlope / slopeCells) * 100, maxSlope * 100, note)
end

function S.paintTerrainArea(a)
    local step = a.step or 0.5
    local sp, pts, note = needPolygon(a.spline, math.max(step, 0.5))
    if sp == nil then return "[ERR] " .. note end
    local terr = findTerrain()
    if terr == nil then return "[ERR] no terrain node found" end
    local numLayers = getTerrainNumOfLayers(terr)
    local li = nil
    if type(a.layer) == "number" then
        if a.layer >= 0 and a.layer < numLayers then li = a.layer end
    else
        local want = string.lower(tostring(a.layer or ""))
        for i = 0, numLayers - 1 do
            if string.lower(getTerrainLayerName(terr, i)) == want then li = i break end
        end
    end
    if li == nil then
        local names = {}
        for i = 0, numLayers - 1 do names[#names + 1] = i .. "=" .. getTerrainLayerName(terr, i) end
        return "[ERR] unknown layer '" .. tostring(a.layer) .. "'. Layers:\n  " .. table.concat(names, ", ")
    end
    local area = polygonArea(pts)
    local estOps = area / (step * step)
    local cap = a.maxOps or 600000
    local msg = string.format("fill %sm2 (%.2f ha) with layer %d (%s) @ %sm, ~%d ops",
        fnum(area), area / 10000, li, getTerrainLayerName(terr, li), fnum(step), estOps)
    if estOps > cap then
        return "[REFUSED] " .. msg .. " exceeds maxOps=" .. cap .. ". Raise step or maxOps." .. note
    end
    if not a.commit then
        return "PREVIEW: " .. msg .. note ..
               "\nre-run with commit=true to paint. NO scripted undo -- backup_scene/save first if unsure."
    end
    local minx, minz, maxx, maxz = polygonBBox(pts)
    local ops = 0
    local z = minz + step * 0.5
    while z <= maxz do
        local xs = rowCrossings(pts, z)
        for i = 1, #xs - 1, 2 do
            local x = xs[i] + step * 0.5
            while x <= xs[i + 1] do
                setTerrainLayerAtWorldPos(terr, li, x, 0, z, 128.0)
                ops = ops + 1
                x = x + step
            end
        end
        z = z + step
    end
    return "PAINTED " .. msg .. " (" .. ops .. " actual ops)" .. note
end

function S.paintFoliageArea(a)
    local rowStep = a.rowStep or 0.5
    local sp, pts, note = needPolygon(a.spline, math.max(rowStep, 0.5))
    if sp == nil then return "[ERR] " .. note end
    local terr = findTerrain()
    if terr == nil then return "[ERR] no terrain node found" end
    local layerName = tostring(a.layer or "")
    if layerName == "" then return "[ERR] layer (foliage layer name) is required" end
    local plane = getTerrainDataPlaneByName(terr, layerName)
    if plane == nil or plane == 0 then
        return "[ERR] foliage layer '" .. layerName .. "' not found on terrain"
    end
    if a.state == nil then return "[ERR] state is required (0 = remove/clear)" end
    local minx, minz, maxx, maxz = polygonBBox(pts)
    local area = polygonArea(pts)
    -- one executeSet per row segment: rows across the bbox, 1..k segments each
    local estRows = (maxz - minz) / rowStep
    local cap = a.maxOps or 20000
    local msg = string.format("foliage '%s' state %d over %sm2 (%.2f ha), ~%d row strips @ %sm",
        layerName, a.state, fnum(area), area / 10000, estRows, fnum(rowStep))
    if estRows * 2 > cap then
        return "[REFUSED] " .. msg .. " likely exceeds maxOps=" .. cap ..
               ". Raise rowStep, split the area, or raise maxOps." .. note
    end
    if not a.commit then
        return "PREVIEW: " .. msg .. note ..
               "\nstate 0 clears. re-run with commit=true. NO scripted undo -- backup_scene/save first if unsure."
    end
    local modifier = DensityMapModifier.new(plane, a.firstChannel or 0, a.numChannels or 4, terr)
    local ops = 0
    local z = minz
    while z <= maxz do
        local zMid = z + rowStep * 0.5
        local xs = rowCrossings(pts, zMid)
        for i = 1, #xs - 1, 2 do
            if xs[i + 1] - xs[i] > 0.05 and ops < cap then
                -- rectangle strip: start + corner along x + corner along z
                modifier:setParallelogramWorldCoords(
                    xs[i], z, xs[i + 1], z, xs[i], z + rowStep, DensityCoordType.POINT_POINT_POINT)
                modifier:executeSet(a.state)
                ops = ops + 1
            end
        end
        z = z + rowStep
    end
    return "PAINTED " .. msg .. " (" .. ops .. " executeSet strips)" .. note
end

function S.flattenArea(a)
    local step = a.step or 0.5
    local sp, pts, note = needPolygon(a.spline, math.max(step, 0.5))
    if sp == nil then return "[ERR] " .. note end
    local terr = findTerrain()
    if terr == nil then return "[ERR] no terrain node found" end
    -- target height: explicit, or derived from the boundary samples
    local target = a.height
    if target == nil then
        local mode = a.heightMode or "avg"
        local minH, maxH, sumH = math.huge, -math.huge, 0
        for _, p in ipairs(pts) do
            local h = getTerrainHeightAtWorldPos(terr, p[1], 0, p[2])
            if h < minH then minH = h end
            if h > maxH then maxH = h end
            sumH = sumH + h
        end
        if mode == "min" then target = minH
        elseif mode == "max" then target = maxH
        else target = sumH / #pts end
    end
    local area = polygonArea(pts)
    local estOps = area / (step * step)
    local cap = a.maxOps or 600000
    local msg = string.format("flatten %sm2 (%.2f ha) to height %s @ %sm, ~%d ops",
        fnum(area), area / 10000, fnum(target), fnum(step), estOps)
    if estOps > cap then
        return "[REFUSED] " .. msg .. " exceeds maxOps=" .. cap .. ". Raise step or maxOps." .. note
    end
    if not a.commit then
        return "PREVIEW: " .. msg .. note ..
               "\nEdges are SHARP -- afterwards run spline_adjust_terrain mode=smooth on the same spline to blend the rim." ..
               "\nre-run with commit=true. NO scripted undo -- backup_scene/save first if unsure."
    end
    local minx, minz, maxx, maxz = polygonBBox(pts)
    local ops = 0
    local z = minz + step * 0.5
    while z <= maxz do
        local xs = rowCrossings(pts, z)
        for i = 1, #xs - 1, 2 do
            local x = xs[i] + step * 0.5
            while x <= xs[i + 1] do
                setTerrainHeightAtWorldPos(terr, x, 0, z, target)
                ops = ops + 1
                x = x + step
            end
        end
        z = z + step
    end
    return string.format("FLATTENED to %s: %s (%d actual ops)%s", fnum(target), msg, ops, note)
end

-- ============================================================================
--  v8 additions: fields, farmlands, info layers
--  Patterns ported from the editor's own MapToolkitField.lua plugin (which is
--  NOT loaded outside the Map Toolkit window -- everything here is raw engine
--  calls, self-contained). Field structure: field TG (+polygonIndex/
--  nameIndicatorIndex/teleportIndicatorIndex/angle/missionOnlyGrass/
--  missionAllowed user attrs) > polygonPoints TG > point1..N TGs.
-- ============================================================================

local function fieldsRoot()
    local found = nil
    local function walk(n)
        if found then return end
        local ok, v = pcall(getUserAttribute, n, "onCreate")
        if ok and v == "FieldUtil.onCreate" then found = n return end
        for i = 0, getNumOfChildren(n) - 1 do
            walk(getChildAt(n, i))
            if found then return end
        end
    end
    walk(getRootNode())
    return found
end

local function nodeByIndexPath(base, path)          -- "0" or "0|2" child-index path
    local n = base
    for seg in string.gmatch(tostring(path or ""), "[^|]+") do
        local idx = tonumber(seg)
        if idx == nil or n == nil or idx >= getNumOfChildren(n) then return nil end
        n = getChildAt(n, idx)
    end
    return n ~= base and n or nil
end

local function fieldRootByNode(node)                -- walk up until polygonIndex attr
    local n = node
    local hops = 0
    while n ~= nil and n ~= 0 and hops < 64 do
        local ok, v = pcall(getUserAttribute, n, "polygonIndex")
        if ok and v ~= nil then return n end
        if n == getRootNode() then return nil end
        local okp, p = pcall(getParent, n)
        if not okp or p == nil or p == 0 then return nil end
        n = p
        hops = hops + 1
    end
    return nil
end

local function resolveField(spec)
    local id, err = S.resolveNode(spec)
    if id == nil then return nil, err end
    local f = fieldRootByNode(id)
    if f == nil then return nil, "'" .. tostring(getName(id)) .. "' is not (inside) a field (no polygonIndex attribute up the chain)" end
    return f
end

local function fieldVertsXZ(field)                  -- world-space {{x,z},...}
    local poly = nodeByIndexPath(field, getUserAttribute(field, "polygonIndex"))
    if poly == nil or getNumOfChildren(poly) < 3 then return nil, nil end
    local xz = {}
    for i = 0, getNumOfChildren(poly) - 1 do
        local x, _, z = getWorldTranslation(getChildAt(poly, i))
        xz[#xz + 1] = { x, z }
    end
    return xz, poly
end

local function shoelaceHa(xz)
    local a, n = 0, #xz
    for i = 1, n do
        local p, q = xz[i], xz[i % n + 1]
        a = a + p[1] * q[2] - q[1] * p[2]
    end
    return math.abs(a) * 0.5 / 10000
end

local function centroidXZ(xz)
    local cx, cz = 0, 0
    for _, p in ipairs(xz) do cx = cx + p[1] cz = cz + p[2] end
    return cx / #xz, cz / #xz
end

local function farmlandLayer()
    local layer = getInfoLayerFromTerrain(g_terrainNode, "farmlands")
    if layer == nil or layer == 0 then return nil end
    local w, h = getBitVectorMapSize(layer)
    return layer, w, h, getBitVectorMapNumChannels(layer), getTerrainSize(g_terrainNode)
end

local function infoLayerValueAt(layer, w, h, nch, ts, x, z)
    local lx = math.floor(w * (x + ts * 0.5) / ts)
    local lz = math.floor(h * (z + ts * 0.5) / ts)
    return getBitVectorMapPoint(layer, lx, lz, 0, nch)
end

-- engine-side polygon rasterization: ONE executeSet call, no manual scanline
local function polyModifySet(plane, ch0, nch, xz, value)
    local modifier = DensityMapModifier.new(plane, ch0, nch, g_terrainNode)
    modifier:clearPolygonPoints()
    for _, p in ipairs(xz) do
        modifier:addPolygonPointWorldCoords(p[1], p[2])
    end
    modifier:executeSet(value)
end

function S.fieldOps(a)
    local action = tostring(a.action or "")
    local root = fieldsRoot()

    if action == "list" then
        if root == nil then return "[ERR] no fields root node (create one in the Map Toolkit first)" end
        local out, totalHa, nonFields = {}, 0, 0
        for i = 0, getNumOfChildren(root) - 1 do
            local f = getChildAt(root, i)
            local okA, idxPath = pcall(getUserAttribute, f, "polygonIndex")
            if okA and idxPath ~= nil then
                local xz = fieldVertsXZ(f)
                local ha = xz and shoelaceHa(xz) or 0
                totalHa = totalHa + ha
                local ma = getUserAttribute(f, "missionAllowed")
                out[#out + 1] = string.format("  [%d] %s  %.2f ha  %d pts%s",
                    f, getName(f) or "?", ha, xz and #xz or 0,
                    ma == false and "  missionAllowed=false" or "")
            else
                nonFields = nonFields + 1
                out[#out + 1] = string.format("  [%d] %s  (NOT a field -- no polygonIndex)", f, getName(f) or "?")
            end
        end
        return string.format("fields root [%d]: %d children, %.2f ha total%s\n%s",
            root, getNumOfChildren(root), totalHa,
            nonFields > 0 and (", " .. nonFields .. " non-field child(ren)") or "",
            table.concat(out, "\n"))

    elseif action == "info" then
        local f, err = resolveField(a.field)
        if f == nil then return "[ERR] " .. err end
        local xz, poly = fieldVertsXZ(f)
        if xz == nil then return "[ERR] field has no valid polygon (<3 points)" end
        local cx, cz = centroidXZ(xz)
        local fid = "?"
        local layer, w, h, nch, ts = farmlandLayer()
        if layer then fid = tostring(infoLayerValueAt(layer, w, h, nch, ts, cx, cz)) end
        local wx, wy, wz = getWorldTranslation(f)
        return string.format(
            "[%d] %s  %.2f ha  %d polygon points (poly node [%d])\n" ..
            "centroid: (%s, %s)   pivot: (%s, %s, %s)\n" ..
            "farmlandId at centroid: %s\n" ..
            "attrs: angle=%s missionAllowed=%s missionOnlyGrass=%s",
            f, getName(f) or "?", shoelaceHa(xz), #xz, poly,
            fnum(cx), fnum(cz), fnum(wx), fnum(wy), fnum(wz), fid,
            tostring(getUserAttribute(f, "angle")),
            tostring(getUserAttribute(f, "missionAllowed")),
            tostring(getUserAttribute(f, "missionOnlyGrass")))

    elseif action == "create_from_spline" then
        if root == nil then return "[ERR] no fields root node (create one in the Map Toolkit first)" end
        local sp, err = needSpline(a.spline)
        if sp == nil then return "[ERR] " .. err end
        local spacing = a.pointSpacing or 15.0
        local raw = {}
        walkSpline(sp, spacing, 4000, function(t, x, y, z) raw[#raw + 1] = { x, z } end)
        if #raw > 2 then
            local f1, l1 = raw[1], raw[#raw]
            if math.sqrt((f1[1] - l1[1]) ^ 2 + (f1[2] - l1[2]) ^ 2) < spacing * 0.75 then
                table.remove(raw)
            end
        end
        if #raw < 3 then return "[ERR] spline yields fewer than 3 polygon points" end
        local name = a.name
        if name == nil or name == "" then
            name = string.format("field%01d", getNumOfChildren(root) + 1)
        end
        local field = createTransformGroup(name)
        local polygonPoints = createTransformGroup("polygonPoints")
        local nameIndicator = createTransformGroup("nameIndicator")
        local teleportIndicator = createTransformGroup("teleportIndicator")
        link(field, polygonPoints)
        link(field, nameIndicator)
        link(field, teleportIndicator)
        link(root, field)
        local cx, cz = centroidXZ(raw)
        local cy = getTerrainHeightAtWorldPos(g_terrainNode, cx, 0, cz)
        setWorldTranslation(field, cx, cy, cz)
        for i, p in ipairs(raw) do
            local pt = createTransformGroup("point" .. i)
            link(polygonPoints, pt)
            local py = getTerrainHeightAtWorldPos(g_terrainNode, p[1], 0, p[2])
            setWorldTranslation(pt, p[1], py, p[2])
        end
        setUserAttribute(field, "polygonIndex", UserAttributeType.STRING, tostring(getChildIndex(polygonPoints)))
        setUserAttribute(field, "nameIndicatorIndex", UserAttributeType.STRING, tostring(getChildIndex(nameIndicator)))
        setUserAttribute(field, "teleportIndicatorIndex", UserAttributeType.STRING, tostring(getChildIndex(teleportIndicator)))
        setUserAttribute(field, "angle", UserAttributeType.INTEGER, 0)
        setUserAttribute(field, "missionOnlyGrass", UserAttributeType.BOOLEAN, false)
        setUserAttribute(field, "missionAllowed", UserAttributeType.BOOLEAN, true)
        local ha = shoelaceHa(raw)
        pcall(function()
            local note = createNoteNode(nameIndicator, string.format("%s\n%.2f ha", name, ha), 0, 0, 0, true)
            setTranslation(note, 0, 0, 0)
        end)
        pcall(refreshViewport, true)
        return string.format("created field [%d] %s: %.2f ha, %d points, under fields root [%d]\n" ..
            "next: fieldOps set_ground to paint the ground, farmlandOps paint_field to assign ownership",
            field, name, ha, #raw, root)

    elseif action == "delete" then
        local f, err = resolveField(a.field)
        if f == nil then return "[ERR] " .. err end
        if not a.commit then
            return string.format("PREVIEW: would delete field [%d] %s (%d children). re-run with commit=true.",
                f, getName(f) or "?", getNumOfChildren(f))
        end
        local nm = getName(f) or "?"
        clearSelection()
        delete(f)
        return "deleted field " .. nm .. " (selection cleared first)"

    elseif action == "set_ground" or action == "clear_ground" then
        local f, err = resolveField(a.field)
        if f == nil then return "[ERR] " .. err end
        local xz = fieldVertsXZ(f)
        if xz == nil then return "[ERR] field has no valid polygon" end
        local value = action == "clear_ground" and 0 or (a.value ~= nil and a.value or 2)
        local plane = getTerrainDataPlaneByName(g_terrainNode, "terrainDetail")
        if plane == nil or plane == 0 then return "[ERR] terrainDetail data plane not found" end
        if not a.commit then
            return string.format("PREVIEW: paint terrainDetail=%d over %.2f ha of %s. re-run with commit=true. NO undo -- backup_scene first if unsure.",
                value, shoelaceHa(xz), getName(f) or "?")
        end
        polyModifySet(plane, 0, 4, xz, value)
        return string.format("ground %s on [%d] %s (terrainDetail=%d over %.2f ha, one polygon rasterization)",
            action == "clear_ground" and "CLEARED" or "PAINTED", f, getName(f) or "?", value, shoelaceHa(xz))

    elseif action == "set_fruit" or action == "clear_fruit" then
        local f, err = resolveField(a.field)
        if f == nil then return "[ERR] " .. err end
        local xz = fieldVertsXZ(f)
        if xz == nil then return "[ERR] field has no valid polygon" end
        local fruit = tostring(a.fruit or "")
        if fruit == "" then return "[ERR] fruit (foliage layer name, e.g. 'wheat') is required -- see list_foliage_layers" end
        local plane = getTerrainDataPlaneByName(g_terrainNode, fruit)
        if plane == nil or plane == 0 then return "[ERR] fruit layer '" .. fruit .. "' not found -- see list_foliage_layers" end
        local state = action == "clear_fruit" and 0 or a.state
        if state == nil then return "[ERR] state required (see list_foliage_layers for meanings)" end
        if not a.commit then
            return string.format("PREVIEW: set '%s' state %d over %.2f ha of %s. re-run with commit=true. NO undo -- backup_scene first if unsure.",
                fruit, state, shoelaceHa(xz), getName(f) or "?")
        end
        polyModifySet(plane, a.firstChannel or 0, a.numChannels or 4, xz, state)
        return string.format("fruit '%s' -> state %d on [%d] %s (%.2f ha)", fruit, state, f, getName(f) or "?", shoelaceHa(xz))

    elseif action == "align_points" then
        local f, err = resolveField(a.field)
        if f == nil then return "[ERR] " .. err end
        local xz, poly = fieldVertsXZ(f)
        if poly == nil then return "[ERR] field has no valid polygon" end
        local moved = 0
        for i = 0, getNumOfChildren(poly) - 1 do
            local pt = getChildAt(poly, i)
            local x, y, z = getWorldTranslation(pt)
            local ty = getTerrainHeightAtWorldPos(g_terrainNode, x, y, z)
            if math.abs(ty - y) > 0.001 then
                setWorldTranslation(pt, x, ty, z)
                moved = moved + 1
            end
        end
        return string.format("aligned %d/%d polygon points of %s to the terrain", moved, #xz, getName(f) or "?")

    elseif action == "rename" then
        local f, err = resolveField(a.field)
        if f == nil then return "[ERR] " .. err end
        if a.name == nil or a.name == "" then return "[ERR] name required" end
        local old = getName(f)
        setName(f, a.name)
        local xz = fieldVertsXZ(f)
        pcall(function()
            local ind = nodeByIndexPath(f, getUserAttribute(f, "nameIndicatorIndex"))
            if ind ~= nil and getNumOfChildren(ind) == 1 then
                setNoteNodeText(getChildAt(ind, 0), string.format("%s\n%.2f ha", a.name, xz and shoelaceHa(xz) or 0))
            end
        end)
        return "renamed field '" .. tostring(old) .. "' -> '" .. a.name .. "' (note updated)"
    end

    return "[ERR] unknown action '" .. action .. "'. Actions: list, info, create_from_spline, " ..
           "delete, set_ground, clear_ground, set_fruit, clear_fruit, align_points, rename"
end

function S.farmlandOps(a)
    local action = tostring(a.action or "")
    local layer, w, h, nch, ts = farmlandLayer()
    if layer == nil then return "[ERR] no 'farmlands' info layer on this terrain" end

    if action == "id_at" then
        if a.x == nil or a.z == nil then return "[ERR] x and z required" end
        return string.format("farmlandId at (%.1f, %.1f) = %d", a.x, a.z,
            infoLayerValueAt(layer, w, h, nch, ts, a.x, a.z))

    elseif action == "field_id" then
        local f, err = resolveField(a.field)
        if f == nil then return "[ERR] " .. err end
        local xz = fieldVertsXZ(f)
        if xz == nil then return "[ERR] field has no valid polygon" end
        local cx, cz = centroidXZ(xz)
        return string.format("%s centroid (%.1f, %.1f) -> farmlandId %d",
            getName(f) or "?", cx, cz, infoLayerValueAt(layer, w, h, nch, ts, cx, cz))

    elseif action == "paint_field" or action == "paint_polygon" then
        local id = a.id
        if id == nil or id < 0 then return "[ERR] id (farmland id) required" end
        local xz, label
        if action == "paint_field" then
            local f, err = resolveField(a.field)
            if f == nil then return "[ERR] " .. err end
            xz = fieldVertsXZ(f)
            label = getName(f) or "?"
        else
            local sp, err = needSpline(a.spline)
            if sp == nil then return "[ERR] " .. err end
            xz = {}
            walkSpline(sp, 10.0, 4000, function(t, x, y, z) xz[#xz + 1] = { x, z } end)
            label = getName(sp) or "?"
        end
        if xz == nil or #xz < 3 then return "[ERR] no valid polygon" end
        if not a.commit then
            return string.format("PREVIEW: paint farmlandId=%d over %.2f ha (%s). re-run with commit=true. NO undo -- backup_scene first if unsure.",
                id, shoelaceHa(xz), label)
        end
        polyModifySet(layer, 0, nch, xz, id)
        return string.format("farmland %d painted over %.2f ha (%s)", id, shoelaceHa(xz), label)

    elseif action == "audit" then
        local root = fieldsRoot()
        if root == nil then return "[ERR] no fields root node" end
        local byId, rows, problems = {}, {}, 0
        for i = 0, getNumOfChildren(root) - 1 do
            local f = getChildAt(root, i)
            local ok, idxPath = pcall(getUserAttribute, f, "polygonIndex")
            if ok and idxPath ~= nil then
                local xz = fieldVertsXZ(f)
                if xz then
                    local cx, cz = centroidXZ(xz)
                    local fid = infoLayerValueAt(layer, w, h, nch, ts, cx, cz)
                    local nm = getName(f) or "?"
                    local issues = {}
                    if fid == 0 then issues[#issues + 1] = "on UNOWNED land (id 0)" end
                    if byId[fid] ~= nil and fid ~= 0 then
                        issues[#issues + 1] = "shares farmland " .. fid .. " with " .. byId[fid]
                    end
                    local num = tonumber(string.match(nm, "(%d+)$") or "")
                    if num ~= nil and num ~= fid then
                        issues[#issues + 1] = "name number " .. num .. " ~= farmlandId " .. fid
                    end
                    byId[fid] = byId[fid] or nm
                    if #issues > 0 then
                        problems = problems + 1
                        if #rows < 40 then
                            rows[#rows + 1] = "  " .. nm .. ": " .. table.concat(issues, "; ")
                        end
                    end
                else
                    problems = problems + 1
                    rows[#rows + 1] = "  " .. (getName(f) or "?") .. ": invalid polygon (<3 points)"
                end
            end
        end
        if problems == 0 then return "farmland audit: all fields OK (unique ids, named to match, owned)" end
        return "farmland audit: " .. problems .. " issue(s):\n" .. table.concat(rows, "\n")
    end

    return "[ERR] unknown action '" .. action .. "'. Actions: id_at, field_id, paint_field, paint_polygon, audit"
end

function S.infoLayerOps(a)
    local action = tostring(a.action or "")
    local candidates = { "farmlands", "indoorMask", "placementCollision", "placementCollisionGenerated",
                         "tipCollision", "tipCollisionGenerated", "navigationCollision", "fieldType",
                         "limeLevel", "plowLevel", "sprayLevel", "stubbleShredLevel", "rollerLevel", "weed" }

    if action == "list" then
        local out = {}
        for _, nm in ipairs(candidates) do
            local layer = getInfoLayerFromTerrain(g_terrainNode, nm)
            if layer ~= nil and layer ~= 0 then
                local w, h = getBitVectorMapSize(layer)
                out[#out + 1] = string.format("  %s  %dx%d  %d channel(s)", nm, w, h, getBitVectorMapNumChannels(layer))
            end
        end
        if #out == 0 then return "no known info layers found (probed " .. #candidates .. " common names)" end
        return #out .. " info layer(s) present (of " .. #candidates .. " probed names):\n" .. table.concat(out, "\n")

    elseif action == "read_at" then
        local nm = tostring(a.layer or "")
        if nm == "" or a.x == nil or a.z == nil then return "[ERR] layer, x, z required" end
        local layer = getInfoLayerFromTerrain(g_terrainNode, nm)
        if layer == nil or layer == 0 then return "[ERR] info layer '" .. nm .. "' not found (try action=list)" end
        local w, h = getBitVectorMapSize(layer)
        local nch = getBitVectorMapNumChannels(layer)
        return string.format("%s at (%.1f, %.1f) = %d", nm, a.x, a.z,
            infoLayerValueAt(layer, w, h, nch, getTerrainSize(g_terrainNode), a.x, a.z))

    elseif action == "paint_polygon" then
        local nm = tostring(a.layer or "")
        if nm == "" then return "[ERR] layer required" end
        if a.value == nil or a.value < 0 then return "[ERR] value required" end
        local layer = getInfoLayerFromTerrain(g_terrainNode, nm)
        if layer == nil or layer == 0 then return "[ERR] info layer '" .. nm .. "' not found" end
        local xz
        if a.field ~= nil and a.field ~= "" then
            local f, err = resolveField(a.field)
            if f == nil then return "[ERR] " .. err end
            xz = fieldVertsXZ(f)
        else
            local sp, err = needSpline(a.spline)
            if sp == nil then return "[ERR] " .. err end
            xz = {}
            walkSpline(sp, 10.0, 4000, function(t, x, y, z) xz[#xz + 1] = { x, z } end)
        end
        if xz == nil or #xz < 3 then return "[ERR] no valid polygon" end
        local nch = getBitVectorMapNumChannels(layer)
        if not a.commit then
            return string.format("PREVIEW: paint info layer '%s' = %d over %.2f ha. Collision/gameplay layers change game behavior -- be sure. re-run with commit=true.",
                nm, a.value, shoelaceHa(xz))
        end
        polyModifySet(layer, 0, nch, xz, a.value)
        return string.format("info layer '%s' = %d painted over %.2f ha", nm, a.value, shoelaceHa(xz))
    end

    return "[ERR] unknown action '" .. action .. "'. Actions: list, read_at, paint_polygon"
end

-- ============================================================================
--  v9 additions: spline editing, fence lines, terrain-normal alignment,
--  slope-based painting
--  Spline editing works on EDIT POINTS (getSplineEP -- the user's points; CVs
--  are smoothed internals) with a rebuild pattern: read EPs, transform, create
--  a new spline (name/parent preserved), delete the old. THE NODE ID CHANGES
--  on rebuild -- every rebuild action reports the new id.
-- ============================================================================

local function readEPs(sp)
    local n = getSplineNumOfCV(sp)
    local pts = {}
    for i = 0, n - 1 do
        local ok, x, y, z = pcall(getSplineEP, sp, i)
        if not ok or x == nil then break end
        pts[#pts + 1] = { x, y, z }
    end
    return pts
end

local function rebuildSpline(sp, pts, closed, linear)
    if #pts < 2 then return nil, "fewer than 2 points" end
    local name = getName(sp)
    local parent = getParent(sp)
    local flat = {}
    for _, p in ipairs(pts) do
        flat[#flat + 1] = p[1] flat[#flat + 1] = p[2] flat[#flat + 1] = p[3]
    end
    local newSp = createSplineFromEditPoints(parent, flat, linear == true, closed == true)
    if newSp == nil or newSp == 0 then return nil, "createSplineFromEditPoints failed" end
    setName(newSp, name)
    clearSelection()
    delete(sp)
    return newSp
end

function S.splineEdit(a)
    local action = tostring(a.action or "")
    local sp, err = needSpline(a.spline)
    if action ~= "create_from_points" and sp == nil then return "[ERR] " .. err end
    local closed = sp and getIsSplineClosed(sp) or false

    if action == "get_points" then
        local pts = readEPs(sp)
        local out = { string.format("[%d] %s: %d edit points%s (len %sm)", sp, getName(sp) or "?",
            #pts, closed and ", closed" or "", fnum(getSplineLength(sp))) }
        for i, p in ipairs(pts) do
            if i > 200 then out[#out + 1] = "  ... (" .. (#pts - 200) .. " more)" break end
            out[#out + 1] = string.format("  %d: (%s, %s, %s)", i - 1, fnum(p[1]), fnum(p[2]), fnum(p[3]))
        end
        return table.concat(out, "\n")

    elseif action == "create_from_points" then
        local raw = tostring(a.points or "")
        local pts = {}
        for triple in string.gmatch(raw, "[^;]+") do
            local nums = {}
            for v in string.gmatch(triple, "[^,%s]+") do nums[#nums + 1] = tonumber(v) end
            if #nums == 3 then
                pts[#pts + 1] = { nums[1], nums[2], nums[3] }
            elseif #nums == 2 then                    -- x,z pairs: y from terrain
                local terr = findTerrain()
                local y = terr and getTerrainHeightAtWorldPos(terr, nums[1], 0, nums[2]) or 0
                pts[#pts + 1] = { nums[1], y, nums[2] }
            end
        end
        if #pts < 2 then return "[ERR] need >= 2 points ('x,y,z; x,y,z; ...' or 'x,z; x,z; ...')" end
        local flat = {}
        for _, p in ipairs(pts) do flat[#flat + 1] = p[1] flat[#flat + 1] = p[2] flat[#flat + 1] = p[3] end
        local newSp = createSplineFromEditPoints(getRootNode(), flat, a.linear == true, a.closed == true)
        setName(newSp, (a.name ~= nil and a.name ~= "") and a.name or "MCP_spline")
        return string.format("created spline [%d] %s: %d points%s, len %sm",
            newSp, getName(newSp), #pts, a.closed and ", closed" or "", fnum(getSplineLength(newSp)))

    elseif action == "move_point" then
        local i = a.index
        if i == nil then return "[ERR] index required (0-based, see get_points)" end
        local ok, x, y, z = pcall(getSplineEP, sp, i)
        if not ok or x == nil then return "[ERR] no edit point " .. i end
        local nx = a.x or (x + (a.dx or 0))
        local ny = a.y or (y + (a.dy or 0))
        local nz = a.z or (z + (a.dz or 0))
        setSplineEP(sp, i, nx, ny, nz)
        return string.format("point %d: (%s, %s, %s) -> (%s, %s, %s)  [same node id %d]",
            i, fnum(x), fnum(y), fnum(z), fnum(nx), fnum(ny), fnum(nz), sp)

    elseif action == "add_point" then
        if a.x == nil or a.z == nil then return "[ERR] x, z required (y optional: terrain height)" end
        local y = a.y
        if y == nil then
            local terr = findTerrain()
            y = terr and getTerrainHeightAtWorldPos(terr, a.x, 0, a.z) or 0
        end
        local pts = readEPs(sp)
        local after = a.index or (#pts - 1)          -- default: append at the end
        table.insert(pts, math.min(after + 2, #pts + 1), { a.x, y, a.z })
        local newSp, e = rebuildSpline(sp, pts, closed, a.linear == true)
        if newSp == nil then return "[ERR] " .. e end
        return string.format("added point after %d -> %d points. REBUILT: new id [%d]", after, #pts, newSp)

    elseif action == "delete_point" then
        local i = a.index
        if i == nil then return "[ERR] index required" end
        local pts = readEPs(sp)
        if i < 0 or i >= #pts then return "[ERR] index out of range (0.." .. (#pts - 1) .. ")" end
        if #pts <= (closed and 3 or 2) then return "[ERR] spline would collapse (needs >= " .. (closed and 3 or 2) .. " points)" end
        table.remove(pts, i + 1)
        local newSp, e = rebuildSpline(sp, pts, closed, a.linear == true)
        if newSp == nil then return "[ERR] " .. e end
        return string.format("deleted point %d -> %d points. REBUILT: new id [%d]", i, #pts, newSp)

    elseif action == "set_heights" then
        local mode = tostring(a.mode or "drape")
        local pts = readEPs(sp)
        local terr = findTerrain()
        if mode == "drape" and terr == nil then return "[ERR] no terrain for drape" end
        local changed = 0
        if mode == "smooth" then
            local iters = a.iterations or 2
            for _ = 1, iters do
                local ys = {}
                for i = 1, #pts do
                    local prev = pts[i > 1 and i - 1 or (closed and #pts or 1)][2]
                    local nxt = pts[i < #pts and i + 1 or (closed and 1 or #pts)][2]
                    ys[i] = (prev + pts[i][2] * 2 + nxt) * 0.25
                end
                for i = 1, #pts do pts[i][2] = ys[i] end
            end
            changed = #pts
        else
            for i = 1, #pts do
                local ny
                if mode == "drape" then
                    ny = getTerrainHeightAtWorldPos(terr, pts[i][1], 0, pts[i][3]) + (a.yOffset or 0)
                elseif mode == "constant" then
                    if a.value == nil then return "[ERR] value required for constant" end
                    ny = a.value
                else
                    return "[ERR] mode must be drape | constant | smooth"
                end
                if math.abs(ny - pts[i][2]) > 0.001 then changed = changed + 1 end
                pts[i][2] = ny
            end
        end
        for i = 1, #pts do
            setSplineEP(sp, i - 1, pts[i][1], pts[i][2], pts[i][3])
        end
        return string.format("heights %s: %d/%d points adjusted  [same node id %d]", mode, changed, #pts, sp)

    elseif action == "resample" then
        local spacing = a.spacing or 10.0
        if spacing < 0.5 then spacing = 0.5 end
        local pts = {}
        walkSpline(sp, spacing, 8000, function(t, x, y, z) pts[#pts + 1] = { x, y, z } end)
        if closed and #pts > 3 then table.remove(pts) end
        local newSp, e = rebuildSpline(sp, pts, closed, a.linear == true)
        if newSp == nil then return "[ERR] " .. e end
        return string.format("resampled @ %sm -> %d points. REBUILT: new id [%d], len %sm",
            fnum(spacing), #pts, newSp, fnum(getSplineLength(newSp)))

    elseif action == "reverse" then
        local pts = readEPs(sp)
        local rev = {}
        for i = #pts, 1, -1 do rev[#rev + 1] = pts[i] end
        local newSp, e = rebuildSpline(sp, rev, closed, a.linear == true)
        if newSp == nil then return "[ERR] " .. e end
        return string.format("reversed %d points. REBUILT: new id [%d]", #rev, newSp)

    elseif action == "set_closed" then
        if a.closed == nil then return "[ERR] closed (true/false) required" end
        local pts = readEPs(sp)
        local newSp, e = rebuildSpline(sp, pts, a.closed == true, a.linear == true)
        if newSp == nil then return "[ERR] " .. e end
        return string.format("closed=%s. REBUILT: new id [%d]", tostring(a.closed), newSp)

    elseif action == "split_at" then
        local t = a.t
        if t == nil or t <= 0 or t >= 1 then return "[ERR] t required (0..1, fraction along the spline)" end
        local pts = readEPs(sp)
        local splitIdx = nil
        for i = 0, #pts - 1 do
            local okT, ct = pcall(getTimeAtSplineCV, sp, i)
            if okT and ct ~= nil and ct >= t then splitIdx = i break end
        end
        if splitIdx == nil or splitIdx < 1 or splitIdx > #pts - 2 then
            return "[ERR] split point falls on an endpoint -- pick a t further inside"
        end
        local aPts, bPts = {}, {}
        for i = 1, splitIdx + 1 do aPts[#aPts + 1] = pts[i] end
        for i = splitIdx + 1, #pts do bPts[#bPts + 1] = pts[i] end
        local name = getName(sp)
        local parent = getParent(sp)
        local function mk(list, suffix)
            local flat = {}
            for _, p in ipairs(list) do flat[#flat + 1] = p[1] flat[#flat + 1] = p[2] flat[#flat + 1] = p[3] end
            local s2 = createSplineFromEditPoints(parent, flat, a.linear == true, false)
            setName(s2, name .. suffix)
            return s2
        end
        local s1 = mk(aPts, "_part1")
        local s2 = mk(bPts, "_part2")
        clearSelection()
        delete(sp)
        return string.format("split at t=%.2f (point %d): [%d] %s_part1 (%d pts) + [%d] %s_part2 (%d pts); original deleted",
            t, splitIdx, s1, name, #aPts, s2, name, #bPts)

    elseif action == "join" then
        local sp2, err2 = needSpline(a.spline2)
        if sp2 == nil then return "[ERR] spline2: " .. err2 end
        if sp2 == sp then return "[ERR] cannot join a spline to itself" end
        local p1, p2 = readEPs(sp), readEPs(sp2)
        local lastP, firstQ = p1[#p1], p2[1]
        local gap = math.sqrt((lastP[1] - firstQ[1]) ^ 2 + (lastP[3] - firstQ[3]) ^ 2)
        local joined = {}
        for _, p in ipairs(p1) do joined[#joined + 1] = p end
        for i, p in ipairs(p2) do
            if not (i == 1 and gap < 0.5) then joined[#joined + 1] = p end
        end
        local flat = {}
        for _, p in ipairs(joined) do flat[#flat + 1] = p[1] flat[#flat + 1] = p[2] flat[#flat + 1] = p[3] end
        local newSp = createSplineFromEditPoints(getParent(sp), flat, a.linear == true, false)
        setName(newSp, (getName(sp) or "spline") .. "_joined")
        return string.format("joined -> [%d] %s (%d points, end-start gap was %sm). ORIGINALS KEPT -- safe_delete them once happy.",
            newSp, getName(newSp), #joined, fnum(gap))

    elseif action == "offset_copy" then
        local off = a.offset
        if off == nil or off == 0 then return "[ERR] offset required (meters, +left / -right)" end
        local spacing = a.spacing or 5.0
        local pts = {}
        walkSpline(sp, spacing, 8000, function(t, x, y, z, dx, dy, dz)
            local lx, lz = leftVec(dx, dz)
            if lx ~= nil then pts[#pts + 1] = { x + lx * off, y, z + lz * off } end
        end)
        if closed and #pts > 3 then table.remove(pts) end
        if #pts < 2 then return "[ERR] not enough offset points" end
        local flat = {}
        for _, p in ipairs(pts) do flat[#flat + 1] = p[1] flat[#flat + 1] = p[2] flat[#flat + 1] = p[3] end
        local newSp = createSplineFromEditPoints(getParent(sp), flat, a.linear == true, closed)
        setName(newSp, (getName(sp) or "spline") .. "_offset")
        return string.format("offset copy [%d] %s: %sm to the %s, %d points, len %sm. Original untouched.",
            newSp, getName(newSp), fnum(math.abs(off)), off > 0 and "left" or "right", #pts, fnum(getSplineLength(newSp)))

    elseif action == "attributes" then
        local okN, nA = pcall(getNumSplineAttributes, sp)
        if not okN or nA == nil or nA == 0 then return "no spline attributes on " .. (getName(sp) or "?") end
        local out = { nA .. " attribute(s):" }
        for i = 0, nA - 1 do
            local okNm, nm = pcall(getSplineAttributeName, sp, i)
            out[#out + 1] = "  " .. i .. ": " .. tostring(okNm and nm or "?")
        end
        return table.concat(out, "\n")
    end

    return "[ERR] unknown action '" .. action .. "'. Actions: get_points, create_from_points, " ..
           "move_point, add_point, delete_point, set_heights, resample, reverse, set_closed, " ..
           "split_at, join, offset_copy, attributes"
end

-- ---- fence lines: connected posts + panels stretched to the exact gaps ----------
function S.createFenceLine(a)
    local sp, err = needSpline(a.spline)
    if sp == nil then return "[ERR] " .. err end
    local post, errP = S.resolveNode(a.postSource)
    if post == nil then return "[ERR] postSource: " .. errP end
    local panel = nil
    if a.panelSource ~= nil and a.panelSource ~= "" then
        local p, errQ = S.resolveNode(a.panelSource)
        if p == nil then return "[ERR] panelSource: " .. errQ end
        panel = p
    end
    local spacing = a.postSpacing or 2.5
    if spacing < 0.3 then spacing = 0.3 end
    local maxCount = a.maxCount or 1500
    local terr = findTerrain()
    local snap = (a.terrainSnap ~= false)
    local yOff = a.yOffset or 0
    local closed = getIsSplineClosed(sp)

    local posts = {}
    walkSpline(sp, spacing, maxCount + 1, function(t, x, y, z)
        local py = y
        if snap and terr then py = getTerrainHeightAtWorldPos(terr, x, 0, z) end
        posts[#posts + 1] = { x, py + yOff, z }
    end)
    if closed and #posts > 2 then
        local f, l = posts[1], posts[#posts]
        if math.sqrt((f[1] - l[1]) ^ 2 + (f[3] - l[3]) ^ 2) < spacing * 0.5 then table.remove(posts) end
    end
    if #posts < 2 then return "[ERR] fewer than 2 posts" end
    local nPanels = #posts - (closed and 0 or 1)

    local panelLen = a.panelLength or 0
    local warn = ""
    if panel ~= nil and panelLen <= 0 then
        local cx, cy, cz, r = mergedSphere(panel)
        panelLen = r and r * 2 or spacing
        warn = "\nWARNING: panelLength not given -- estimated " .. fnum(panelLen) ..
               "m from bounds; pass panelLength for exact fit."
    end

    if not a.commit then
        return string.format("PREVIEW fence along [%d] %s: %d posts @ %sm%s%s%s\nre-run with commit=true.",
            sp, getName(sp) or "?", #posts, fnum(spacing),
            panel ~= nil and (", " .. nPanels .. " panels (natural len " .. fnum(panelLen) .. "m, scaled to fit)") or ", no panels",
            closed and ", closed loop" or "", warn)
    end

    local grpName = a.groupName or ("MCP_fence_" .. (getName(sp) or "spline"))
    local grp = createTransformGroup(grpName)
    link(getRootNode(), grp)
    local postGrp = createTransformGroup("posts")
    link(grp, postGrp)
    local wsx, wsy, wsz = worldScale(post)
    local prx, _, prz = getWorldRotation(post)
    local postYawAdd = math.rad(a.postYawAddDeg or 0)
    for i, p in ipairs(posts) do
        local nxt = posts[i < #posts and i + 1 or (closed and 1 or i)]
        local yaw = math.atan2(nxt[1] - p[1], nxt[3] - p[3])
        if i == #posts and not closed then
            local prev = posts[i - 1]
            yaw = math.atan2(p[1] - prev[1], p[3] - prev[3])
        end
        local c = clone(post, true, false, false)
        link(postGrp, c)
        setName(c, "post_" .. i)
        setScale(c, wsx, wsy, wsz)
        setWorldTranslation(c, p[1], p[2], p[3])
        setWorldRotation(c, prx, yaw + postYawAdd, prz)
    end
    local panelCount = 0
    if panel ~= nil then
        local panGrp = createTransformGroup("panels")
        link(grp, panGrp)
        local pwsx, pwsy, pwsz = worldScale(panel)
        local qrx, _, qrz = getWorldRotation(panel)
        local panelYawAdd = math.rad(a.panelYawAddDeg or 0)
        for i = 1, nPanels do
            local p = posts[i]
            local q = posts[i < #posts and i + 1 or 1]
            local dx, dy, dz = q[1] - p[1], q[2] - p[2], q[3] - p[3]
            local horiz = math.sqrt(dx * dx + dz * dz)
            local gapLen = math.sqrt(horiz * horiz + dy * dy)
            local c = clone(panel, true, false, false)
            link(panGrp, c)
            setName(c, "panel_" .. i)
            local zScale = pwsz * (gapLen / math.max(panelLen, 0.01))
            setScale(c, pwsx, pwsy, zScale)
            setWorldTranslation(c, (p[1] + q[1]) * 0.5, (p[2] + q[2]) * 0.5, (p[3] + q[3]) * 0.5)
            local yaw = math.atan2(dx, dz)
            local pitch = -math.atan2(dy, horiz)
            setWorldRotation(c, qrx + pitch, yaw + panelYawAdd, qrz)
            panelCount = panelCount + 1
        end
    end
    return string.format("FENCE built along [%d] %s: %d posts + %d panels in [%d] %s -- delete that group to undo%s",
        sp, getName(sp) or "?", #posts, panelCount, grp, grpName, warn)
end

-- ---- pitch/roll props to the terrain slope --------------------------------------
function S.alignToTerrainNormal(a)
    local id, err = S.resolveNode(a.node)
    if id == nil then return "[ERR] " .. err end
    local terr = findTerrain()
    if terr == nil then return "[ERR] no terrain node found" end
    local maxTilt = math.rad(a.maxTiltDeg or 30)
    local targets = {}
    if a.children ~= false and getNumOfChildren(id) > 0 then
        for i = 0, getNumOfChildren(id) - 1 do targets[#targets + 1] = getChildAt(id, i) end
    else
        targets[1] = id
    end
    local rows, done = {}, 0
    for _, n in ipairs(targets) do
        local x, y, z = getWorldTranslation(n)
        local d = a.sampleDist or 1.0
        local hx1 = getTerrainHeightAtWorldPos(terr, x - d, 0, z)
        local hx2 = getTerrainHeightAtWorldPos(terr, x + d, 0, z)
        local hz1 = getTerrainHeightAtWorldPos(terr, x, 0, z - d)
        local hz2 = getTerrainHeightAtWorldPos(terr, x, 0, z + d)
        local nx, ny, nz = -(hx2 - hx1) / (2 * d), 1, -(hz2 - hz1) / (2 * d)
        local l = math.sqrt(nx * nx + ny * ny + nz * nz)
        nx, ny, nz = nx / l, ny / l, nz / l
        local tilt = math.acos(math.min(ny, 1))
        if tilt > maxTilt then                        -- cap: blend the normal toward straight up
            local f = maxTilt / tilt
            nx, nz = nx * f, nz * f
            local l2 = math.sqrt(nx * nx + 1 + nz * nz)
            nx, ny, nz = nx / l2, 1 / l2, nz / l2
            tilt = maxTilt
        end
        if a.commit then
            local _, ry, _ = getWorldRotation(n)
            local fx, fz = math.sin(ry), math.cos(ry)   -- keep heading
            local dot = fx * nx + fz * nz
            local px, py, pz = fx - nx * dot, -ny * dot, fz - nz * dot
            local pl = math.sqrt(px * px + py * py + pz * pz)
            if pl > 1e-4 then
                local sx, sy, sz = getScale(n)          -- setDirection resets scale
                setDirection(n, px / pl, py / pl, pz / pl, nx, ny, nz)
                setScale(n, sx, sy, sz)
                done = done + 1
            end
        else
            done = done + 1
        end
        if #rows < 8 then
            rows[#rows + 1] = string.format("  [%d] %s: slope tilt %.1f%s", n, getName(n) or "?",
                math.deg(tilt), tilt >= maxTilt and " (CAPPED)" or "")
        end
    end
    local head = string.format("%s %d node(s) under '%s' to the terrain normal (cap %.0f%s)",
        a.commit and "TILTED" or "WOULD TILT", done, getName(id) or "?", math.deg(maxTilt), "\194\176")
    if #rows > 0 then head = head .. "\n" .. table.concat(rows, "\n") end
    if #targets > 8 then head = head .. "\n  ..." end
    if not a.commit then head = head .. "\nre-run with commit=true. Heading and scale are preserved." end
    return head
end

-- ---- paint a texture wherever the slope is in range ------------------------------
function S.paintBySlope(a)
    local step = a.step or 1.0
    local sp, pts, note = needPolygon(a.spline, math.max(step, 0.5))
    if sp == nil then return "[ERR] " .. note end
    local terr = findTerrain()
    if terr == nil then return "[ERR] no terrain node found" end
    local numLayers = getTerrainNumOfLayers(terr)
    local li = nil
    if type(a.layer) == "number" then
        if a.layer >= 0 and a.layer < numLayers then li = a.layer end
    else
        local want = string.lower(tostring(a.layer or ""))
        for i = 0, numLayers - 1 do
            if string.lower(getTerrainLayerName(terr, i)) == want then li = i break end
        end
    end
    if li == nil then return "[ERR] unknown layer '" .. tostring(a.layer) .. "'" end
    local minS = math.tan(math.rad(a.minSlopeDeg or 20))
    local maxS = math.tan(math.rad(a.maxSlopeDeg or 90))
    local minx, minz, maxx, maxz = polygonBBox(pts)
    local area = polygonArea(pts)
    local estOps = area / (step * step)
    local cap = a.maxOps or 600000
    local msg = string.format("paint layer %d (%s) where slope %.0f..%.0f%s inside %sm2 @ %sm (~%d cells scanned)",
        li, getTerrainLayerName(terr, li), a.minSlopeDeg or 20, a.maxSlopeDeg or 90, "\194\176", fnum(area), fnum(step), estOps)
    if estOps > cap then
        return "[REFUSED] " .. msg .. " exceeds maxOps=" .. cap .. ". Raise step or maxOps." .. note
    end
    if not a.commit then
        return "PREVIEW: " .. msg .. note .. "\nre-run with commit=true. NO undo -- backup_scene first if unsure."
    end
    local painted, scanned = 0, 0
    local z = minz + step * 0.5
    while z <= maxz do
        local xs = rowCrossings(pts, z)
        for i = 1, #xs - 1, 2 do
            local x = xs[i] + step * 0.5
            while x <= xs[i + 1] do
                scanned = scanned + 1
                local h = getTerrainHeightAtWorldPos(terr, x, 0, z)
                local h2 = getTerrainHeightAtWorldPos(terr, x + step, 0, z)
                local h3 = getTerrainHeightAtWorldPos(terr, x, 0, z + step)
                local sl = math.max(math.abs(h2 - h), math.abs(h3 - h)) / step
                if sl >= minS and sl <= maxS then
                    setTerrainLayerAtWorldPos(terr, li, x, 0, z, 128.0)
                    painted = painted + 1
                end
                x = x + step
            end
        end
        z = z + step
    end
    return string.format("PAINTED %d/%d cells (slope-matched): %s%s", painted, scanned, msg, note)
end

-- ============================================================================
--  v10 additions: scene audits + batch operations
-- ============================================================================

-- names that are LEGITIMATELY empty transform groups (field structure etc.)
local function isExpectedEmptyTG(nm)
    return nm == "nameIndicator" or nm == "teleportIndicator"
        or nm == "careerStartPoint" or string.match(nm, "^point%d+$") ~= nil
end

function S.auditScene(a)
    local action = tostring(a.action or "scene")
    local root = getRootNode()
    local ts = getTerrainSize(g_terrainNode) or 2048
    local bound = ts * 0.5 * 1.25

    if action == "lights" then
        local rows, count = {}, 0
        local function walk(n)
            local ok, isL = pcall(getHasClassId, n, ClassIds.LIGHT_SOURCE)
            if ok and isL then
                count = count + 1
                local okR, range = pcall(getLightRange, n)
                local okV, vis = pcall(getVisibility, n)
                if #rows < 40 then
                    rows[#rows + 1] = string.format("  [%d] %s  range=%s  visible=%s%s",
                        n, getName(n) or "?", okR and fnum(range) or "?", tostring(okV and vis),
                        (okR and range ~= nil and range > 500) and "  (LARGE range)" or "")
                end
            end
            for i = 0, getNumOfChildren(n) - 1 do walk(getChildAt(n, i)) end
        end
        walk(root)
        if count == 0 then return "no light sources in the scene" end
        return count .. " light source(s):\n" .. table.concat(rows, "\n")
            .. (count > 40 and "\n  ... (capped at 40)" or "")

    elseif action == "collisions" then
        local nRigid, mask0, rows = 0, 0, {}
        local function walk(n)
            local okR, rb = pcall(getRigidBodyType, n)
            if okR and rb ~= nil and rb ~= 0 and rb ~= "NoRigidBody" then
                nRigid = nRigid + 1
                local okM, mask = pcall(getCollisionFilterMask, n)
                if okM and mask == 0 then
                    mask0 = mask0 + 1
                    if #rows < 25 then
                        rows[#rows + 1] = string.format("  [%d] %s  rigidBody=%s but collisionFilterMask=0 (collides with nothing)",
                            n, getName(n) or "?", tostring(rb))
                    end
                end
            end
            for i = 0, getNumOfChildren(n) - 1 do walk(getChildAt(n, i)) end
        end
        walk(root)
        local head = string.format("collision audit: %d rigid bodies, %d with mask=0", nRigid, mask0)
        if #rows > 0 then head = head .. "\n" .. table.concat(rows, "\n") end
        return head
    end

    -- action == "scene": one walk, several checks
    local stats = { nodes = 0, tg = 0, shapes = 0, splines = 0, lights = 0, cameras = 0 }
    local emptyTG, dupes, oob, weirdScale = {}, {}, {}, {}
    local nEmpty, nOob, nWeird, nDupePairs = 0, 0, 0, 0
    local fields = fieldsRoot()

    local function walk(n, inFields)
        stats.nodes = stats.nodes + 1
        local kids = getNumOfChildren(n)
        local cls = classStr(n)
        if cls == "TG" then stats.tg = stats.tg + 1
        elseif cls == "SPLINE" then stats.splines = stats.splines + 1
        elseif cls == "LIGHT" then stats.lights = stats.lights + 1
        elseif cls == "CAMERA" then stats.cameras = stats.cameras + 1
        else stats.shapes = stats.shapes + 1 end

        local nm = getName(n) or "?"
        if cls == "TG" and kids == 0 and not inFields and not isExpectedEmptyTG(nm) then
            local okA, oc = pcall(getUserAttribute, n, "onCreate")
            if not (okA and oc ~= nil) then
                nEmpty = nEmpty + 1
                if #emptyTG < 25 then emptyTG[#emptyTG + 1] = "  [" .. n .. "] " .. nodePath(n) end
            end
        end
        local wx, _, wz = getWorldTranslation(n)
        if math.abs(wx) > bound or math.abs(wz) > bound then
            nOob = nOob + 1
            if #oob < 20 then oob[#oob + 1] = string.format("  [%d] %s at (%s, %s)", n, nm, fnum(wx), fnum(wz)) end
        end
        local okS, sx, sy, sz = pcall(getScale, n)
        if okS and sx ~= nil then
            local mn, mx = math.min(sx, sy, sz), math.max(sx, sy, sz)
            if mx > 100 or (mn < 0.01 and mn > 0) or mn < 0 then
                nWeird = nWeird + 1
                if #weirdScale < 20 then
                    weirdScale[#weirdScale + 1] = string.format("  [%d] %s scale (%s, %s, %s)", n, nm, fnum(sx), fnum(sy), fnum(sz))
                end
            end
        end
        if kids > 1 then
            local seen = {}
            for i = 0, kids - 1 do
                local c = getChildAt(n, i)
                local cn = getName(c) or "?"
                if seen[cn] then
                    seen[cn] = seen[cn] + 1
                else
                    seen[cn] = 1
                end
            end
            for cn, cnt in pairs(seen) do
                if cnt > 1 then
                    nDupePairs = nDupePairs + 1
                    if #dupes < 20 then
                        dupes[#dupes + 1] = string.format("  %s: '%s' x%d", nodePath(n), cn, cnt)
                    end
                end
            end
        end
        for i = 0, kids - 1 do
            walk(getChildAt(n, i), inFields or n == fields)
        end
    end
    walk(root, false)

    local out = {
        string.format("scene audit: %d nodes (%d TG, %d shapes, %d splines, %d lights, %d cameras)",
            stats.nodes, stats.tg, stats.shapes, stats.splines, stats.lights, stats.cameras),
        string.format("empty transform groups (excl. field structure): %d", nEmpty),
    }
    for _, r in ipairs(emptyTG) do out[#out + 1] = r end
    out[#out + 1] = string.format("duplicate sibling names: %d parent/name pair(s)", nDupePairs)
    for _, r in ipairs(dupes) do out[#out + 1] = r end
    out[#out + 1] = string.format("out of bounds (beyond +-%sm): %d", fnum(bound), nOob)
    for _, r in ipairs(oob) do out[#out + 1] = r end
    out[#out + 1] = string.format("suspicious scale (<0.01, >100 or negative): %d", nWeird)
    for _, r in ipairs(weirdScale) do out[#out + 1] = r end
    out[#out + 1] = "(lists capped; use find_nodes / node_info to chase individuals. " ..
        "clean_empty_groups can remove the empty TGs.)"
    return table.concat(out, "\n")
end

function S.batchOps(a)
    local action = tostring(a.action or "")

    if action == "rename_pattern" then
        local id, err = S.resolveNode(a.node)
        if id == nil then return "[ERR] " .. err end
        local prefix = tostring(a.prefix or "")
        if prefix == "" then return "[ERR] prefix required (children become prefix_1, prefix_2, ...)" end
        local match = a.match ~= nil and string.lower(tostring(a.match)) or nil
        local targets = {}
        for i = 0, getNumOfChildren(id) - 1 do
            local c = getChildAt(id, i)
            if match == nil or string.find(string.lower(getName(c) or ""), match, 1, true) then
                targets[#targets + 1] = c
            end
        end
        if #targets == 0 then return "[ERR] no children match" end
        if not a.commit then
            return string.format("PREVIEW: rename %d children of %s to %s_1..%s_%d. re-run with commit=true.",
                #targets, getName(id) or "?", prefix, prefix, #targets)
        end
        for i, c in ipairs(targets) do setName(c, prefix .. "_" .. (i - 1 + (a.start or 1))) end
        return string.format("renamed %d children to %s_%d..%s_%d", #targets, prefix, a.start or 1,
            prefix, #targets - 1 + (a.start or 1))

    elseif action == "clean_empty_groups" then
        local id, err = S.resolveNode(a.node or "map.i3d")
        if id == nil then id = getRootNode() end
        local fields = fieldsRoot()
        local victims = {}
        local function walk(n, inFields)
            for i = 0, getNumOfChildren(n) - 1 do
                walk(getChildAt(n, i), inFields or n == fields)
            end
            if n ~= id and not inFields and getNumOfChildren(n) == 0 and classStr(n) == "TG"
                and not isExpectedEmptyTG(getName(n) or "") then
                local okA, oc = pcall(getUserAttribute, n, "onCreate")
                if not (okA and oc ~= nil) then victims[#victims + 1] = n end
            end
        end
        walk(id, false)
        if #victims == 0 then return "no removable empty transform groups under " .. (getName(id) or "?") end
        if not a.commit then
            local rows = {}
            for i = 1, math.min(#victims, 30) do
                rows[#rows + 1] = "  [" .. victims[i] .. "] " .. nodePath(victims[i])
            end
            return string.format("PREVIEW: %d empty group(s) would be deleted:\n%s%s\nre-run with commit=true.",
                #victims, table.concat(rows, "\n"), #victims > 30 and "\n  ..." or "")
        end
        clearSelection()
        local n = 0
        for _, v in ipairs(victims) do
            if entityExists(v) then delete(v) n = n + 1 end
        end
        return "deleted " .. n .. " empty transform group(s) (selection cleared first)"

    elseif action == "array_duplicate" then
        local src, err = S.resolveNode(a.node)
        if src == nil then return "[ERR] " .. err end
        local mode = tostring(a.mode or "line")
        local placements = {}
        local wx, wy, wz = getWorldTranslation(src)
        if mode == "line" then
            local count = a.count or 5
            local dx = a.spacingX or (a.spacing or 5)
            local dz = a.spacingZ or 0
            for i = 1, count do placements[#placements + 1] = { wx + dx * i, wy, wz + dz * i } end
        elseif mode == "grid" then
            local cx2 = a.countX or 3
            local cz2 = a.countZ or 3
            local sx2 = a.spacingX or (a.spacing or 5)
            local sz2 = a.spacingZ or (a.spacing or 5)
            for ix = 0, cx2 - 1 do
                for iz = 0, cz2 - 1 do
                    if not (ix == 0 and iz == 0) then
                        placements[#placements + 1] = { wx + sx2 * ix, wy, wz + sz2 * iz }
                    end
                end
            end
        elseif mode == "circle" then
            local count = a.count or 8
            local r = a.radius or 10
            for i = 1, count do
                local ang = (i / count) * 2 * math.pi
                placements[#placements + 1] = { wx + math.sin(ang) * r, wy, wz + math.cos(ang) * r, ang }
            end
        else
            return "[ERR] mode must be line | grid | circle"
        end
        if #placements > (a.maxCount or 500) then
            return "[REFUSED] " .. #placements .. " copies exceeds maxCount"
        end
        local terr = findTerrain()
        if not a.commit then
            return string.format("PREVIEW: %d %s copies of '%s'%s. re-run with commit=true.",
                #placements, mode, getName(src) or "?", a.terrainSnap and ", terrain-snapped" or "")
        end
        local grp = createTransformGroup(a.groupName or ("MCP_array_" .. (getName(src) or "node")))
        link(getRootNode(), grp)
        local wsx, wsy, wsz = worldScale(src)
        local rx, ry, rz = getWorldRotation(src)
        for i, p in ipairs(placements) do
            local c = clone(src, true, false, false)
            link(grp, c)
            setName(c, (getName(src) or "node") .. "_" .. i)
            setScale(c, wsx, wsy, wsz)
            local py = p[2]
            if a.terrainSnap and terr then py = getTerrainHeightAtWorldPos(terr, p[1], 0, p[3]) end
            setWorldTranslation(c, p[1], py, p[3])
            setWorldRotation(c, rx, p[4] ~= nil and (a.faceCenter and p[4] or ry) or ry, rz)
        end
        return string.format("arrayed %d copies (%s) into [%d] %s -- delete that group to undo",
            #placements, mode, grp, getName(grp))

    elseif action == "distribute" then
        local id, err = S.resolveNode(a.node)
        if id == nil then return "[ERR] " .. err end
        local n = getNumOfChildren(id)
        if n < 3 then return "[ERR] need >= 3 children to distribute" end
        local first = getChildAt(id, 0)
        local last = getChildAt(id, n - 1)
        local x1, y1, z1 = getWorldTranslation(first)
        local x2, y2, z2 = getWorldTranslation(last)
        if not a.commit then
            return string.format("PREVIEW: evenly space %d children of %s between (%s, %s) and (%s, %s). re-run with commit=true.",
                n, getName(id) or "?", fnum(x1), fnum(z1), fnum(x2), fnum(z2))
        end
        local terr = findTerrain()
        for i = 1, n - 2 do
            local t = i / (n - 1)
            local c = getChildAt(id, i)
            local px = x1 + (x2 - x1) * t
            local py = y1 + (y2 - y1) * t
            local pz = z1 + (z2 - z1) * t
            if a.terrainSnap and terr then py = getTerrainHeightAtWorldPos(terr, px, 0, pz) end
            setWorldTranslation(c, px, py, pz)
        end
        return string.format("distributed %d children of %s evenly", n, getName(id) or "?")

    elseif action == "snap_to_grid" then
        local id, err = S.resolveNode(a.node)
        if id == nil then return "[ERR] " .. err end
        local step = a.step or 1.0
        if step <= 0 then step = 1.0 end
        local moved, maxD = 0, 0
        local n = getNumOfChildren(id)
        for i = 0, n - 1 do
            local c = getChildAt(id, i)
            local x, y, z = getWorldTranslation(c)
            local nx = math.floor(x / step + 0.5) * step
            local nz = math.floor(z / step + 0.5) * step
            local d = math.max(math.abs(nx - x), math.abs(nz - z))
            if d > 0.001 then
                moved = moved + 1
                if d > maxD then maxD = d end
                if a.commit then setWorldTranslation(c, nx, y, nz) end
            end
        end
        return string.format("%s %d/%d children of %s to a %sm grid (max shift %sm)%s",
            a.commit and "snapped" or "WOULD snap", moved, n, getName(id) or "?",
            fnum(step), fnum(maxD), a.commit and "" or "  re-run with commit=true.")

    elseif action == "replace_asset" then
        local pat = string.lower(tostring(a.pattern or ""))
        if pat == "" then return "[ERR] pattern required (name substring of the nodes to replace)" end
        local src, err = S.resolveNode(a.source)
        if src == nil then return "[ERR] source: " .. err end
        local victims = {}
        local limit = a.limit or 200
        local function walk(n)
            if n ~= src and string.find(string.lower(getName(n) or ""), pat, 1, true)
                and not string.find(getName(n) or "", "^MCP_") then
                victims[#victims + 1] = n
                return                                 -- don't descend into a match
            end
            for i = 0, getNumOfChildren(n) - 1 do walk(getChildAt(n, i)) end
        end
        walk(getRootNode())
        if #victims == 0 then return "no nodes match '" .. a.pattern .. "'" end
        if #victims > limit then
            return "[REFUSED] " .. #victims .. " matches exceeds limit=" .. limit
        end
        if not a.commit then
            local rows = {}
            for i = 1, math.min(#victims, 20) do
                rows[#rows + 1] = "  [" .. victims[i] .. "] " .. nodePath(victims[i])
            end
            return string.format("PREVIEW: replace %d node(s) matching '%s' with clones of '%s':\n%s%s\nre-run with commit=true (originals are DELETED).",
                #victims, a.pattern, getName(src) or "?", table.concat(rows, "\n"),
                #victims > 20 and "\n  ..." or "")
        end
        local grp = createTransformGroup(a.groupName or ("MCP_replaced_" .. a.pattern))
        link(getRootNode(), grp)
        local wsx, wsy, wsz = worldScale(src)
        clearSelection()
        local done = 0
        for i, v in ipairs(victims) do
            if entityExists(v) then
                local x, y, z = getWorldTranslation(v)
                local rx, ry, rz = getWorldRotation(v)
                local c = clone(src, true, false, false)
                link(grp, c)
                setName(c, (getName(src) or "node") .. "_r" .. i)
                setScale(c, wsx, wsy, wsz)
                setWorldTranslation(c, x, y, z)
                setWorldRotation(c, rx, ry, rz)
                delete(v)
                done = done + 1
            end
        end
        return string.format("replaced %d node(s): clones in [%d] %s, originals deleted (selection cleared first)",
            done, grp, getName(grp))
    end

    return "[ERR] unknown action '" .. action .. "'. Actions: rename_pattern, clean_empty_groups, " ..
           "array_duplicate, distribute, snap_to_grid, replace_asset"
end

-- ============================================================================
--  v11 additions: materials/shaders, traffic validation, camera state
-- ============================================================================

local function shapesUnder(node, cap)
    local shapes = {}
    local function walk(n)
        if #shapes >= (cap or 2000) then return end
        local ok, isShape = pcall(getHasClassId, n, ClassIds.SHAPE)
        if ok and isShape and not isSplineShape(n) then shapes[#shapes + 1] = n end
        for i = 0, getNumOfChildren(n) - 1 do walk(getChildAt(n, i)) end
    end
    walk(node)
    return shapes
end

function S.materialOps(a)
    local action = tostring(a.action or "")
    local id, err = S.resolveNode(a.node)
    if id == nil then return "[ERR] " .. err end

    if action == "list" then
        local shapes = shapesUnder(id)
        if #shapes == 0 then return "no mesh shapes under " .. (getName(id) or "?") end
        local mats = {}          -- matId -> {count, example, shader, variation}
        local order = {}
        for _, s in ipairs(shapes) do
            local okN, nMat = pcall(getNumOfMaterials, s)
            for mi = 0, (okN and nMat or 1) - 1 do
                local okM, m = pcall(getMaterial, s, mi)
                if okM and m ~= nil and m ~= 0 then
                    if mats[m] == nil then
                        local okF, file = pcall(getMaterialCustomShaderFilename, m)
                        local okV, var = pcall(getMaterialCustomShaderVariation, m)
                        mats[m] = { count = 0, example = getName(s) or "?",
                                    shader = okF and file or nil, variation = okV and var or nil }
                        order[#order + 1] = m
                    end
                    mats[m].count = mats[m].count + 1
                end
            end
        end
        local out = { string.format("%d unique material(s) across %d shape(s) under %s:",
            #order, #shapes, getName(id) or "?") }
        for i, m in ipairs(order) do
            if i > 40 then out[#out + 1] = "  ... (" .. (#order - 40) .. " more)" break end
            local e = mats[m]
            local sh = ""
            if e.shader ~= nil and e.shader ~= "" then
                sh = "  shader=" .. tostring(e.shader):match("[^/\\]+$")
                if e.variation ~= nil and e.variation ~= "" then sh = sh .. " (" .. tostring(e.variation) .. ")" end
            end
            out[#out + 1] = string.format("  mat [%d]  x%d slots  e.g. %s%s", m, e.count, e.example, sh)
        end
        return table.concat(out, "\n")

    elseif action == "get_param" then
        local param = tostring(a.param or "")
        if param == "" then return "[ERR] param required" end
        local shapes = shapesUnder(id, 50)
        if #shapes == 0 then return "[ERR] no mesh shapes under " .. (getName(id) or "?") end
        local out = {}
        for i, s in ipairs(shapes) do
            if i > 10 then out[#out + 1] = "  ..." break end
            local ok, x, y, z, w = pcall(getShaderParameter, s, param)
            if ok and x ~= nil then
                out[#out + 1] = string.format("  [%d] %s: (%s, %s, %s, %s)", s, getName(s) or "?",
                    fnum(x), fnum(y), fnum(z), fnum(w))
            end
        end
        if #out == 0 then return "no shape under " .. (getName(id) or "?") .. " has shader parameter '" .. param .. "'" end
        return "'" .. param .. "':\n" .. table.concat(out, "\n")

    elseif action == "set_param" then
        local param = tostring(a.param or "")
        if param == "" then return "[ERR] param required" end
        if a.x == nil then return "[ERR] at least x required (x,y,z,w default to current)" end
        local shapes = shapesUnder(id, a.recursive == false and 1 or 500)
        local done, rows = 0, {}
        for _, s in ipairs(shapes) do
            local ok, ox, oy, oz, ow = pcall(getShaderParameter, s, param)
            if ok and ox ~= nil then
                local nx, ny, nz, nw = a.x, a.y or oy, a.z or oz, a.w or ow
                local okS = pcall(setShaderParameter, s, param, nx, ny, nz, nw, a.shared == true)
                if okS then
                    done = done + 1
                    if #rows < 8 then
                        rows[#rows + 1] = string.format("  [%d] %s: (%s,%s,%s,%s) -> (%s,%s,%s,%s)",
                            s, getName(s) or "?", fnum(ox), fnum(oy), fnum(oz), fnum(ow),
                            fnum(nx), fnum(ny), fnum(nz), fnum(nw))
                    end
                end
            end
        end
        if done == 0 then return "[ERR] no shape under " .. (getName(id) or "?") .. " has parameter '" .. param .. "'" end
        return string.format("set '%s' on %d shape(s) (old -> new shown; re-set old values to revert):\n%s",
            param, done, table.concat(rows, "\n"))

    elseif action == "assign_from" then
        local src, err2 = S.resolveNode(a.source)
        if src == nil then return "[ERR] source: " .. err2 end
        local srcShapes = shapesUnder(src, 1)
        if #srcShapes == 0 then return "[ERR] source has no mesh shape" end
        local okM, mat = pcall(getMaterial, srcShapes[1], 0)
        if not okM or mat == nil or mat == 0 then return "[ERR] could not read source material" end
        local shapes = shapesUnder(id, 500)
        if #shapes == 0 then return "[ERR] no mesh shapes under target" end
        if not a.commit then
            return string.format("PREVIEW: assign material [%d] (from %s) to %d shape(s) under %s. re-run with commit=true. (Old materials are NOT recorded -- save first.)",
                mat, getName(src) or "?", #shapes, getName(id) or "?")
        end
        local done = 0
        for _, s in ipairs(shapes) do
            local okN, nMat = pcall(getNumOfMaterials, s)
            for mi = 0, (okN and nMat or 1) - 1 do
                if pcall(setMaterial, s, mat, mi) then done = done + 1 end
            end
        end
        return string.format("assigned material [%d] to %d slot(s) under %s", mat, done, getName(id) or "?")
    end

    return "[ERR] unknown action '" .. action .. "'. Actions: list, get_param, set_param, assign_from"
end

function S.trafficOps(a)
    local action = tostring(a.action or "validate")
    local rootSpec = a.node or "traffsplines"
    local root, err = S.resolveNode(rootSpec)
    if root == nil then return "[ERR] " .. err end
    local splines = {}
    local function walk(n)
        if isSplineShape(n) then splines[#splines + 1] = n end
        for i = 0, getNumOfChildren(n) - 1 do walk(getChildAt(n, i)) end
    end
    walk(root)
    if #splines == 0 then return "[ERR] no splines under " .. (getName(root) or "?") end

    if action == "list" then
        local out = { #splines .. " traffic spline(s) under " .. (getName(root) or "?") .. ":" }
        for i, sp in ipairs(splines) do
            if i > 60 then out[#out + 1] = "  ... (" .. (#splines - 60) .. " more)" break end
            out[#out + 1] = string.format("  [%d] %s  len=%sm%s", sp, getName(sp) or "?",
                fnum(getSplineLength(sp)), getIsSplineClosed(sp) and "  closed" or "")
        end
        return table.concat(out, "\n")
    end

    -- action == "validate": pairs, direction, endpoint gaps
    -- pair left/right by base name: take the prefix before "left"/"right" and
    -- strip trailing spline-word/underscore junk ("road_curve10_splline_left"
    -- and "..._right" both map to base "road_curve10")
    local byBase = {}
    for _, sp in ipairs(splines) do
        local nm = getName(sp) or ""
        local pos, side = string.find(nm, "left"), nil
        if pos ~= nil then side = "left" else pos = string.find(nm, "right") side = pos and "right" or nil end
        if side ~= nil then
            local base = string.gsub(string.sub(nm, 1, pos - 1), "[_splineSPLINE]+$", "")
            if base ~= "" then
                byBase[base] = byBase[base] or {}
                byBase[base][side] = sp
            end
        end
    end
    -- Direction check is CONVENTION-RELATIVE: whether left/right pairs run the
    -- same or opposite way differs per map (GreenOre: all-same, and its traffic
    -- works). Measure every pair, take the majority as this map's convention,
    -- and flag only the DEVIANTS.
    local issues, nPairs = {}, 0
    local pairDots = {}
    for base, pair in pairs(byBase) do
        if pair.left ~= nil and pair.right ~= nil then
            nPairs = nPairs + 1
            local lLen = getSplineLength(pair.left)
            local rLen = getSplineLength(pair.right)
            if math.abs(lLen - rLen) / math.max(lLen, rLen) > 0.15 then
                issues[#issues + 1] = string.format("  %s: length mismatch left %sm vs right %sm",
                    base, fnum(lLen), fnum(rLen))
            end
            local mx, my, mz = getSplinePosition(pair.left, 0.5)
            local ldx, _, ldz = getSplineDirection(pair.left, 0.5)
            local okC, _, _, _, rt = pcall(getClosestSplinePosition, pair.right, mx, my, mz, 1.0)
            if okC and rt ~= nil then
                local rdx, _, rdz = getSplineDirection(pair.right, math.max(0, math.min(1, rt)))
                pairDots[#pairDots + 1] = { base = base, dot = ldx * rdx + ldz * rdz }
            end
        elseif (pair.left ~= nil) ~= (pair.right ~= nil) then
            issues[#issues + 1] = "  " .. base .. ": " .. (pair.left and "left" or "right") .. " side only (missing partner)"
        end
    end
    local nSame = 0
    for _, pd in ipairs(pairDots) do
        if pd.dot > 0 then nSame = nSame + 1 end
    end
    local convSame = nSame * 2 >= #pairDots          -- majority convention
    local convNote = ""
    if #pairDots > 0 then
        convNote = string.format("  (pair direction convention on this map: %s, %d/%d)",
            convSame and "SAME-direction" or "opposite-direction", convSame and nSame or (#pairDots - nSame), #pairDots)
        for _, pd in ipairs(pairDots) do
            local isSame = pd.dot > 0
            if isSame ~= convSame and math.abs(pd.dot) > 0.5 then
                issues[#issues + 1] = string.format("  %s: runs %s its pair (dot %.2f) -- DEVIATES from this map's convention",
                    pd.base, isSame and "WITH" or "AGAINST", pd.dot)
            end
        end
    end
    -- endpoint gap check: every open spline's ends should sit near SOME other endpoint
    local endpoints = {}
    for _, sp in ipairs(splines) do
        if not getIsSplineClosed(sp) then
            local x0, y0, z0 = getSplinePosition(sp, 0)
            local x1, y1, z1 = getSplinePosition(sp, 1)
            endpoints[#endpoints + 1] = { sp, "start", x0, z0 }
            endpoints[#endpoints + 1] = { sp, "end", x1, z1 }
        end
    end
    local nGaps = 0
    local gapT = a.gapTolerance or 1.0
    for i, e in ipairs(endpoints) do
        local best = math.huge
        for j, f in ipairs(endpoints) do
            if e[1] ~= f[1] then
                local d = math.sqrt((e[3] - f[3]) ^ 2 + (e[4] - f[4]) ^ 2)
                if d < best then best = d end
            end
        end
        if best > gapT and best < math.huge then
            nGaps = nGaps + 1
            if nGaps <= 15 then
                issues[#issues + 1] = string.format("  [%d] %s %s point: nearest other endpoint %sm away (dead end?)",
                    e[1], getName(e[1]) or "?", e[2], fnum(best))
            end
        end
    end
    local head = string.format("traffic validation under %s: %d splines, %d left/right pair(s), %d issue(s)",
        getName(root) or "?", #splines, nPairs, #issues) .. (convNote ~= "" and ("\n" .. convNote) or "")
    if #issues == 0 then return head .. "\n-- looks clean" end
    return head .. ":\n" .. table.concat(issues, "\n")
end

-- camera state save/restore + top-down setup (used by camera_topdown server-side)
function S.cameraTopSet(a)
    local cam = getCamera()
    if cam == nil or cam == 0 then return "[ERR] no active camera" end
    local px, py, pz = getWorldTranslation(cam)
    local rx, ry, rz = getWorldRotation(cam)
    _G.__mcpCamState = { cam = cam, px = px, py = py, pz = pz, rx = rx, ry = ry, rz = rz,
                         fov = getFovY(cam), ortho = getIsOrthographic(cam) }
    local terr = findTerrain()
    local y = (terr and getTerrainHeightAtWorldPos(terr, a.x, 0, a.z) or 0) + (a.height or 400)
    setWorldTranslation(cam, a.x, y, a.z)
    setWorldRotation(cam, -math.pi / 2, 0, 0)        -- straight down, north up
    setIsOrthographic(cam, true)
    setOrthographicHeight(cam, a.size or 200)
    return "top-down set over (" .. fnum(a.x) .. ", " .. fnum(a.z) .. "), " .. fnum(a.size or 200) .. "m frame"
end

function S.cameraRestore()
    local st = _G.__mcpCamState
    if st == nil then return "[ERR] no saved camera state" end
    setIsOrthographic(st.cam, st.ortho == true)
    pcall(setFovY, st.cam, st.fov)
    setWorldTranslation(st.cam, st.px, st.py, st.pz)
    setWorldRotation(st.cam, st.rx, st.ry, st.rz)
    _G.__mcpCamState = nil
    return "camera restored"
end

function S.debugView(a)
    local mode = string.upper(tostring(a.mode or "NONE"))
    if DebugRendering == nil then return "[ERR] DebugRendering not available" end
    if DebugRendering[mode] == nil then
        local keys = {}
        for k in pairs(DebugRendering) do keys[#keys + 1] = k end
        table.sort(keys)
        return "[ERR] unknown mode '" .. mode .. "'. Modes: " .. table.concat(keys, ", ")
    end
    setDebugRenderingMode(DebugRendering[mode])
    return "debug rendering: " .. mode .. (mode ~= "NONE" and "  (take a viewport_screenshot; debug_view NONE to reset)" or "")
end

return "[GE-MCP] helpers v" .. S.version .. " injected: " ..
       "listSplines, splineInfo, placeObjects, paintTerrain, paintFoliage, " ..
       "alignTerrainToSpline, alignToTerrain, selectionInfo, sceneTree, findNodes, " ..
       "nodeInfo, setTransform, nodeProps, createGroup, safeDelete, reparentWorld, " ..
       "randomizeTransforms, importI3d, cameraLook, selectNodes, adjustTerrainAlongSpline, " ..
       "terrainStats, paintTerrainArea, paintFoliageArea, flattenArea, " ..
       "fieldOps, farmlandOps, infoLayerOps, " ..
       "splineEdit, createFenceLine, alignToTerrainNormal, paintBySlope, auditScene, batchOps, " ..
       "materialOps, trafficOps, cameraTopSet, cameraRestore, debugView"
