-- Farm Route Planner
-- Its own window: pick a zone, draw a route on that zone's map, save it by name,
-- show it on the minimap, and share it with import/export strings.

local ADDON = ...
local FRP = {}
_G.FarmRoutePlanner = FRP

local floor, ceil, max, min, sqrt, cos, sin, atan2 =
	math.floor, math.ceil, math.max, math.min, math.sqrt, math.cos, math.sin, math.atan2
local tinsert, tremove = table.insert, table.remove

local EXPORT_PREFIX = "!FRP1!"
local MAP_W, MAP_H = 690, 460          -- map area size in the window
local FREEHAND_STEP = 0.004            -- min normalized distance between freehand samples
local PALETTE = {
	{ 1.00, 0.82, 0.00 }, { 0.20, 0.80, 1.00 }, { 1.00, 0.30, 0.30 },
	{ 0.40, 1.00, 0.40 }, { 0.85, 0.45, 1.00 }, { 1.00, 0.60, 0.20 },
	{ 1.00, 1.00, 1.00 },
}
-- Minimap diameter in yards per zoom level (0-5)
local MINIMAP_YARDS = {
	indoor  = { [0] = 300, 240, 180, 120, 80, 50 },
	outdoor = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 },
}

local db
local cur -- the route being edited in the window
local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff66ff66Farm Route Planner:|r " .. tostring(msg)) end
local function Clean(s) return (tostring(s or ""):gsub("[\t\n|]", " "):gsub("^%s+", ""):gsub("%s+$", "")) end

---------------------------------------------------------------------------
-- Maps / zones
---------------------------------------------------------------------------
local ZONE = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
local CONTINENT = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2

local function MapName(mapID)
	local info = mapID and C_Map.GetMapInfo(mapID)
	return info and info.name or ("Map " .. tostring(mapID))
end

-- The player's current zone (walks up from sub-zones/dungeon floors).
local function PlayerZone()
	local id = C_Map.GetBestMapForUnit("player")
	local guard = 0
	while id and guard < 10 do
		local info = C_Map.GetMapInfo(id)
		if not info then break end
		if info.mapType <= ZONE then return id end
		id = info.parentMapID
		guard = guard + 1
	end
	return C_Map.GetBestMapForUnit("player")
end

-- Returns { {name=, header=true}, {name=, mapID=}, ... } grouped by continent.
local zoneList
local function BuildZoneList()
	if zoneList then return zoneList end
	zoneList = {}
	-- find the top-level map
	local root = C_Map.GetBestMapForUnit("player") or 947
	local guard = 0
	while guard < 10 do
		local info = C_Map.GetMapInfo(root)
		if not info or not info.parentMapID or info.parentMapID == 0 then break end
		root = info.parentMapID
		guard = guard + 1
	end
	local seen = {}
	local function AddZones(parentID)
		local kids = C_Map.GetMapChildrenInfo(parentID, ZONE, true) or {}
		table.sort(kids, function(a, b) return a.name < b.name end)
		local added = 0
		for _, z in ipairs(kids) do
			if not seen[z.mapID] and z.mapType == ZONE then
				seen[z.mapID] = true
				tinsert(zoneList, { name = z.name, mapID = z.mapID })
				added = added + 1
			end
		end
		return added
	end
	local conts = C_Map.GetMapChildrenInfo(root, CONTINENT, true) or {}
	table.sort(conts, function(a, b) return a.name < b.name end)
	for _, c in ipairs(conts) do
		tinsert(zoneList, { name = c.name, header = true })
		if AddZones(c.mapID) == 0 then tremove(zoneList) end
	end
	if #zoneList == 0 then AddZones(root) end
	return zoneList
end

---------------------------------------------------------------------------
-- Route helpers
---------------------------------------------------------------------------
local function Invalidate(route) if route then route._world = nil; route._hbd = nil end end

local function NewWorking(mapID)
	local c = PALETTE[((db and #db.routes or 0) % #PALETTE) + 1]
	cur = { name = "", mapID = mapID, color = { c[1], c[2], c[3] }, width = 3, closed = true,
		visible = true, points = {}, savedIndex = nil, dirty = false }
end

local function CopyRoute(r)
	local pts = {}
	for i, p in ipairs(r.points) do pts[i] = { p[1], p[2] } end
	return { name = r.name, mapID = r.mapID, color = { r.color[1], r.color[2], r.color[3] },
		width = r.width or 3, closed = r.closed, visible = r.visible ~= false, points = pts }
end

-- World coordinates for a route (cached). Returns {inst=, [i]={north, west}} or nil.
local function GetWorld(route)
	if route._world ~= nil then return route._world or nil end
	local world = false
	if route.mapID and #route.points > 0 and C_Map.GetWorldPosFromMapPos then
		world = {}
		for i, p in ipairs(route.points) do
			local inst, pos = C_Map.GetWorldPosFromMapPos(route.mapID, CreateVector2D(p[1], p[2]))
			if not pos then world = false break end
			local n, w = pos:GetXY()
			world.inst = inst
			world[i] = { n, w }
		end
	end
	route._world = world
	return world or nil
end

---------------------------------------------------------------------------
-- Serialization (text -> base64)
---------------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64DEC = {}
for i = 1, 64 do B64DEC[B64:byte(i)] = i - 1 end

local function B64Encode(s)
	local out = {}
	for i = 1, #s, 3 do
		local a, b, c = s:byte(i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local c1, c2 = floor(n / 262144) % 64, floor(n / 4096) % 64
		local c3, c4 = floor(n / 64) % 64, n % 64
		out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
			.. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
	end
	return table.concat(out)
end

local function B64Decode(s)
	s = s:gsub("[^%w%+/=]", "")
	local out = {}
	for i = 1, #s, 4 do
		local v, pad = {}, 0
		for j = 0, 3 do
			local ch = s:byte(i + j)
			if ch == nil or ch == 61 then
				v[j + 1] = 0; pad = pad + 1
			else
				v[j + 1] = B64DEC[ch]
				if not v[j + 1] then return nil end
			end
		end
		local n = v[1] * 262144 + v[2] * 4096 + v[3] * 64 + v[4]
		local bytes = string.char(floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
		out[#out + 1] = bytes:sub(1, 3 - pad)
	end
	return table.concat(out)
end

local function SerializeRoute(r)
	local pts = {}
	for i, p in ipairs(r.points) do
		pts[i] = floor(p[1] * 10000 + 0.5) .. "," .. floor(p[2] * 10000 + 0.5)
	end
	return table.concat({
		Clean(r.name), tostring(r.mapID or 0),
		string.format("%.2f,%.2f,%.2f", r.color[1], r.color[2], r.color[3]),
		r.closed and "1" or "0", tostring(r.width or 3), table.concat(pts, ";"),
	}, "\t")
end

local function DeserializeRoute(line)
	local f = {}
	for field in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = field end
	if #f < 6 then return nil end
	local mapID = tonumber(f[2])
	local r, g, b = f[3]:match("([%d%.]+),([%d%.]+),([%d%.]+)")
	local route = {
		name = f[1] ~= "" and f[1] or "Imported route",
		mapID = (mapID and mapID > 0) and mapID or nil,
		color = { tonumber(r) or 1, tonumber(g) or 1, tonumber(b) or 0 },
		closed = f[4] == "1",
		width = min(max(tonumber(f[5]) or 3, 1), 10),
		visible = true,
		points = {},
	}
	for x, y in f[6]:gmatch("(%d+),(%d+)") do
		tinsert(route.points, { min(tonumber(x) / 10000, 1), min(tonumber(y) / 10000, 1) })
	end
	if not route.mapID or #route.points < 2 then return nil end
	return route
end

function FRP.Export(routes)
	local lines = {}
	for _, r in ipairs(routes) do lines[#lines + 1] = SerializeRoute(r) end
	return EXPORT_PREFIX .. B64Encode(table.concat(lines, "\n"))
end

-- Returns count, lastImportedIndex or 0, errorMessage
function FRP.Import(text)
	text = Clean(text)
	-- also accept strings from the older WorldRoutes version
	local prefix = text:match("^!FRP1!") or text:match("^!WR1!")
	if not prefix then return 0, "That isn't a Farm Route Planner string." end
	local raw = B64Decode(text:sub(#prefix + 1))
	if not raw then return 0, "The string is corrupted or incomplete." end
	local count = 0
	for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
		local route = DeserializeRoute(line)
		if route then
			tinsert(db.routes, route)
			count = count + 1
		end
	end
	if count == 0 then return 0, "No valid routes found in the string." end
	return count, #db.routes
end

---------------------------------------------------------------------------
-- Generic text dialog (import / export)
---------------------------------------------------------------------------
local Backdrop = BackdropTemplateMixin and "BackdropTemplate" or nil
local BACKDROP = {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
	tile = true, tileSize = 32, edgeSize = 24,
	insets = { left = 6, right = 6, top = 6, bottom = 6 },
}
local function ApplyBackdrop(f, a)
	if f.SetBackdrop then
		f:SetBackdrop(BACKDROP)
		f:SetBackdropColor(0, 0, 0, a or 0.9)
	end
end

local dialog
local function ShowDialog(title, text, onAccept)
	if not dialog then
		dialog = CreateFrame("Frame", "FarmRoutePlannerDialog", UIParent, Backdrop)
		dialog:SetSize(460, 260)
		dialog:SetPoint("CENTER")
		dialog:SetFrameStrata("FULLSCREEN_DIALOG")
		ApplyBackdrop(dialog, 1)
		dialog:EnableMouse(true); dialog:SetMovable(true)
		dialog:RegisterForDrag("LeftButton")
		dialog:SetScript("OnDragStart", dialog.StartMoving)
		dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
		tinsert(UISpecialFrames, "FarmRoutePlannerDialog")

		dialog.title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		dialog.title:SetPoint("TOP", 0, -14)

		local sf = CreateFrame("ScrollFrame", "FarmRoutePlannerDialogScroll", dialog, "UIPanelScrollFrameTemplate")
		sf:SetPoint("TOPLEFT", 16, -36); sf:SetPoint("BOTTOMRIGHT", -34, 44)
		local eb = CreateFrame("EditBox", nil, sf)
		eb:SetMultiLine(true); eb:SetAutoFocus(true); eb:SetFontObject(ChatFontNormal)
		eb:SetWidth(400); eb:SetMaxLetters(0)
		eb:SetScript("OnEscapePressed", function() dialog:Hide() end)
		sf:SetScrollChild(eb)
		sf:EnableMouse(true)
		sf:SetScript("OnMouseDown", function() eb:SetFocus() end)
		dialog.edit = eb

		local ok = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
		ok:SetSize(100, 22); ok:SetPoint("BOTTOMRIGHT", dialog, "BOTTOM", -4, 14)
		ok:SetText(OKAY or "Okay")
		ok:SetScript("OnClick", function()
			local fn = dialog.onAccept
			dialog:Hide()
			if fn then fn(dialog.edit:GetText()) end
		end)
		local cancel = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
		cancel:SetSize(100, 22); cancel:SetPoint("BOTTOMLEFT", dialog, "BOTTOM", 4, 14)
		cancel:SetText(CANCEL or "Cancel")
		cancel:SetScript("OnClick", function() dialog:Hide() end)
		dialog.cancel = cancel
	end
	dialog.title:SetText(title)
	dialog.onAccept = onAccept
	dialog.edit:SetText(text or "")
	dialog.cancel:SetShown(onAccept ~= nil)
	dialog:Show()
	dialog.edit:SetFocus()
	dialog.edit:HighlightText()
end

local function Confirm(text, onAccept)
	StaticPopupDialogs.FARMROUTEPLANNER_CONFIRM = {
		text = text, button1 = YES or "Yes", button2 = NO or "No",
		timeout = 0, whileDead = true, hideOnEscape = true, OnAccept = onAccept,
	}
	StaticPopup_Show("FARMROUTEPLANNER_CONFIRM")
end

---------------------------------------------------------------------------
-- Main window
---------------------------------------------------------------------------
local win, mapFrame, tileFrame, lineLayer, zoneButton, zoneMenu, nameBox, routeListChild
local tiles, linePool, usedLines, dotPool, usedDots = {}, {}, {}, {}, {}
local listRows = {}
local strokes = {}
local hasLines -- whether this client supports CreateLine

local function AcquireLine()
	local l = tremove(linePool) or lineLayer:CreateLine(nil, "OVERLAY")
	l:Show(); usedLines[#usedLines + 1] = l
	return l
end

local function AcquireDot()
	local t = tremove(dotPool)
	if not t then
		t = lineLayer:CreateTexture(nil, "OVERLAY", nil, 7)
		t:SetTexture("Interface\\Buttons\\WHITE8X8")
	end
	t:Show(); usedDots[#usedDots + 1] = t
	return t
end

-- Route point markers live on their own layer above the GatherMate2 icons,
-- so points sitting on a node can still be seen, selected and dragged.
local vertLayer
local vertPool, vertUsed = {}, {}
local function AcquireVert()
	local t = tremove(vertPool)
	if not t then
		t = vertLayer:CreateTexture(nil, "OVERLAY", nil, 7)
		t:SetTexture("Interface\\Buttons\\WHITE8X8")
	end
	t:Show(); vertUsed[#vertUsed + 1] = t
	return t
end

local function DrawSegment(ax, ay, bx, by, c, thick, alpha)
	if hasLines then
		local l = AcquireLine()
		l:SetColorTexture(c[1], c[2], c[3], alpha)
		l:SetThickness(thick)
		l:SetStartPoint("TOPLEFT", lineLayer, ax, -ay)
		l:SetEndPoint("TOPLEFT", lineLayer, bx, -by)
	else -- fallback: chain of dots
		local dx, dy = bx - ax, by - ay
		local steps = max(1, floor(sqrt(dx * dx + dy * dy) / (thick * 0.8)))
		for s = 0, steps do
			local d = AcquireDot()
			d:SetVertexColor(c[1], c[2], c[3], alpha)
			d:SetSize(thick, thick)
			d:ClearAllPoints()
			d:SetPoint("CENTER", lineLayer, "TOPLEFT", ax + dx * s / steps, -(ay + dy * s / steps))
		end
	end
end

local function DrawRoute(route, alpha, showVertices)
	local pts = route.points
	local n = #pts
	if n == 0 then return end
	local c, thick = route.color, route.width or 3
	local last = (route.closed and n > 2) and n or n - 1
	for i = 1, last do
		local a, b = pts[i], pts[i % n + 1]
		DrawSegment(a[1] * MAP_W, a[2] * MAP_H, b[1] * MAP_W, b[2] * MAP_H, c, thick, alpha)
	end
	if showVertices then
		local sel = route.sel or n
		for i = 1, n do
			local d = AcquireVert()
			if i == sel then
				-- selected point: new points are added right after this one
				d:SetVertexColor(0.2, 1, 0.2, 1)
				d:SetSize(10, 10)
			else
				local big = (i == 1 or i == n)
				d:SetVertexColor(1, 1, 1, big and 1 or 0.8)
				d:SetSize(big and 7 or 5, big and 7 or 5)
			end
			d:ClearAllPoints()
			d:SetPoint("CENTER", vertLayer, "TOPLEFT", pts[i][1] * MAP_W, -pts[i][2] * MAP_H)
		end
	end
end

function FRP.RedrawLines()
	if not win then return end
	for i = #usedLines, 1, -1 do usedLines[i]:Hide(); linePool[#linePool + 1] = tremove(usedLines, i) end
	for i = #usedDots, 1, -1 do usedDots[i]:Hide(); dotPool[#dotPool + 1] = tremove(usedDots, i) end
	for i = #vertUsed, 1, -1 do vertUsed[i]:Hide(); vertPool[#vertPool + 1] = tremove(vertUsed, i) end
	-- other saved routes in this zone, faded
	if db.showOthers then
		for idx, r in ipairs(db.routes) do
			if r.mapID == cur.mapID and idx ~= cur.savedIndex and r.visible then DrawRoute(r, 0.35, false) end
		end
	end
	DrawRoute(cur, 0.95, true)
	-- TomTom follow target (orange)
	if FRP.GetFollowTarget then
		local fm, fx, fy = FRP.GetFollowTarget()
		if fm and fm == cur.mapID then
			local d = AcquireVert()
			d:SetVertexColor(1, 0.55, 0, 1)
			d:SetSize(12, 12)
			d:ClearAllPoints()
			d:SetPoint("CENTER", vertLayer, "TOPLEFT", fx * MAP_W, -fy * MAP_H)
		end
	end
	if FRP.RedrawWorldMap then FRP.RedrawWorldMap() end
	win.pointCount:SetText(#cur.points .. " points" .. (cur.dirty and "  |cffff8080(unsaved)|r" or ""))
end

---------------------------------------------------------------------------
-- GatherMate2 nodes on our map
---------------------------------------------------------------------------
local GM_TYPES = {
	{ key = "Mining", label = "Mining", icon = "Interface\\Icons\\Trade_Mining" },
	{ key = "Herb Gathering", label = "Herbs", icon = "Interface\\Icons\\Trade_Herbalism" },
	{ key = "Fishing", label = "Fishing", icon = "Interface\\Icons\\Trade_Fishing" },
	{ key = "Treasure", label = "Treasure", icon = "Interface\\Icons\\INV_Misc_Bag_10" },
}
local gmLayer
local gmPool, gmUsed = {}, {}

local function GetGatherMate()
	local AceAddon = LibStub and LibStub("AceAddon-3.0", true)
	if not AceAddon then return nil end
	return AceAddon:GetAddon("GatherMate2", true)
end

-- When the ring is set to a number of yards here, use it as GatherMate2's tracking
-- distance too, so its red tracking circles start exactly at our ring.
-- ("GM dist" mode leaves GatherMate2's own setting alone.)
function FRP.SyncGatherMateDistance()
	local yards = db and tonumber(db.ringYards)
	if not yards then return end
	local gm = GetGatherMate()
	local profile = gm and gm.db and gm.db.profile
	if not profile then return end
	yards = max(50, min(240, floor(yards / 5 + 0.5) * 5)) -- GatherMate2's own limits: 50-240 in steps of 5
	if profile.trackDistance == yards then return end
	profile.trackDistance = yards
	local cfg = gm.GetModule and gm:GetModule("Config", true)
	if cfg and cfg.UpdateConfig then cfg:UpdateConfig() end
end

-- Individual node kinds (Copper Vein, Peacebloom, ...) the user switched off
local function Excluded(typeKey, nodeID)
	local ex = db.gmExclude[typeKey]
	return ex and ex[nodeID] or false
end

local function NodeName(gm, typeKey, nodeID)
	local rev = gm.reverseNodeIDs and gm.reverseNodeIDs[typeKey]
	return (rev and rev[nodeID]) or ("Node " .. tostring(nodeID))
end

-- Node kinds present in a zone for the ticked types:
-- { {typeKey=, typeLabel=, id=, name=, count=, icon=}, ... } sorted by type then name
local function ZoneNodeKinds(mapID)
	local gm = GetGatherMate()
	local out = {}
	if not gm or not gm.gmdbs then return out end
	for _, t in ipairs(GM_TYPES) do
		if db.gm[t.key] then
			local zoneDB = gm.gmdbs[t.key] and gm.gmdbs[t.key][mapID]
			local counts = {}
			for _, nodeID in pairs(zoneDB or {}) do counts[nodeID] = (counts[nodeID] or 0) + 1 end
			local kinds = {}
			local textures = gm.nodeTextures and gm.nodeTextures[t.key]
			for nodeID, count in pairs(counts) do
				kinds[#kinds + 1] = { typeKey = t.key, typeLabel = t.label, id = nodeID, count = count,
					name = NodeName(gm, t.key, nodeID), icon = (textures and textures[nodeID]) or t.icon }
			end
			table.sort(kinds, function(a, b) return a.name < b.name end)
			for _, k in ipairs(kinds) do out[#out + 1] = k end
		end
	end
	return out
end

-- All GatherMate2 nodes of the ticked (and not excluded) kinds in a zone: { {x, y}, ... } or nil, error
local function GatherNodes(mapID)
	local gm = GetGatherMate()
	if not gm or not gm.gmdbs or not gm.DecodeLoc then return nil, "GatherMate2 isn't loaded." end
	local out = {}
	for _, t in ipairs(GM_TYPES) do
		if db.gm[t.key] then
			local zoneDB = gm.gmdbs[t.key] and gm.gmdbs[t.key][mapID]
			for coord, nodeID in pairs(zoneDB or {}) do
				if not Excluded(t.key, nodeID) then
					local x, y = gm:DecodeLoc(coord)
					if x and y then out[#out + 1] = { x, y } end
				end
			end
		end
	end
	return out
end

local function DrawGatherMate(mapID)
	for i = #gmUsed, 1, -1 do gmUsed[i]:Hide(); gmPool[#gmPool + 1] = tremove(gmUsed, i) end
	if not gmLayer then return end
	if FRP.RefreshNodePanel then FRP.RefreshNodePanel() end
	local gm = GetGatherMate()
	win.gmStatus:SetText(gm and "" or "|cff808080GatherMate2 not loaded|r")
	if not db.gmEnabled then return end
	if not gm or not gm.gmdbs or not gm.DecodeLoc then return end
	for _, t in ipairs(GM_TYPES) do
		if db.gm[t.key] then
			local zoneDB = gm.gmdbs[t.key] and gm.gmdbs[t.key][mapID]
			if zoneDB then
				local textures = gm.nodeTextures and gm.nodeTextures[t.key]
				for coord, nodeID in pairs(zoneDB) do
					local x, y
					if not Excluded(t.key, nodeID) then x, y = gm:DecodeLoc(coord) end
					if x and y then
						local pin = tremove(gmPool) or gmLayer:CreateTexture(nil, "ARTWORK")
						pin:SetTexture((textures and textures[nodeID]) or t.icon)
						pin:SetSize(12, 12)
						pin:ClearAllPoints()
						pin:SetPoint("CENTER", gmLayer, "TOPLEFT", x * MAP_W, -y * MAP_H)
						pin:Show()
						gmUsed[#gmUsed + 1] = pin
					end
				end
			end
		end
	end
end

-- Paint the zone's map art into the map area: base layer + explored areas.
local overlays = {}
local TILE = 256
local function LoadMapArt(mapID)
	for _, t in ipairs(tiles) do t:Hide() end
	for _, t in ipairs(overlays) do t:Hide() end
	local layers = C_Map.GetMapArtLayers and C_Map.GetMapArtLayers(mapID)
	local layer = layers and layers[1]
	local textures = layer and C_Map.GetMapArtLayerTextures and C_Map.GetMapArtLayerTextures(mapID, 1)
	win.noArt:SetShown(not (layer and textures and #textures > 0))
	if layer and textures then
		local cols = ceil(layer.layerWidth / layer.tileWidth)
		local rows = ceil(layer.layerHeight / layer.tileHeight)
		local sx, sy = MAP_W / layer.layerWidth, MAP_H / layer.layerHeight
		local tw, th = layer.tileWidth * sx, layer.tileHeight * sy
		for r = 1, rows do
			for c = 1, cols do
				local i = (r - 1) * cols + c
				local t = tiles[i]
				if not t then
					t = tileFrame:CreateTexture(nil, "BACKGROUND", nil, 1)
					tiles[i] = t
				end
				if textures[i] then
					t:SetTexture(textures[i])
					t:SetSize(tw, th)
					t:ClearAllPoints()
					t:SetPoint("TOPLEFT", tileFrame, "TOPLEFT", (c - 1) * tw, -(r - 1) * th)
					t:Show()
				end
			end
		end

		-- Explored-area overlays (the green terrain), same method Blizzard's map uses
		local explored = C_MapExplorationInfo and C_MapExplorationInfo.GetExploredMapTextures
			and C_MapExplorationInfo.GetExploredMapTextures(mapID)
		local n = 0
		for _, info in ipairs(explored or {}) do
			local wide = ceil(info.textureWidth / TILE)
			local tall = ceil(info.textureHeight / TILE)
			for j = 1, tall do
				local ph, fh = TILE, TILE
				if j == tall then
					ph = info.textureHeight % TILE
					if ph == 0 then ph = TILE end
					fh = 16
					while fh < ph do fh = fh * 2 end
				end
				for k = 1, wide do
					local pw, fw = TILE, TILE
					if k == wide then
						pw = info.textureWidth % TILE
						if pw == 0 then pw = TILE end
						fw = 16
						while fw < pw do fw = fw * 2 end
					end
					local file = info.fileDataIDs[(j - 1) * wide + k]
					if file then
						n = n + 1
						local t = overlays[n]
						if not t then
							t = tileFrame:CreateTexture(nil, "BORDER")
							overlays[n] = t
						end
						t:SetTexture(file)
						t:SetTexCoord(0, pw / fw, 0, ph / fh)
						t:SetSize(pw * sx, ph * sy)
						t:ClearAllPoints()
						t:SetPoint("TOPLEFT", tileFrame, "TOPLEFT",
							(info.offsetX + TILE * (k - 1)) * sx, -(info.offsetY + TILE * (j - 1)) * sy)
						t:Show()
					end
				end
			end
		end
	end
	DrawGatherMate(mapID)
end

function FRP.RefreshList()
	if not win then return end
	local shown = 0
	for idx, r in ipairs(db.routes) do
		if r.mapID == cur.mapID then
			shown = shown + 1
			local row = listRows[shown]
			if not row then
				row = CreateFrame("Button", nil, routeListChild)
				row:SetSize(196, 20)
				row:SetPoint("TOPLEFT", 0, -(shown - 1) * 20)
				row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
				row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
				row.check:SetSize(20, 20); row.check:SetPoint("LEFT")
				row.check:SetScript("OnEnter", function(self)
					GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Show on minimap"); GameTooltip:Show()
				end)
				row.check:SetScript("OnLeave", GameTooltip_Hide)
				row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
				row.text:SetPoint("LEFT", row.check, "RIGHT", 2, 0); row.text:SetPoint("RIGHT")
				row.text:SetJustifyH("LEFT")
				listRows[shown] = row
			end
			row.check:SetChecked(r.visible ~= false)
			row.check:SetScript("OnClick", function(self)
				r.visible = self:GetChecked() and true or false
				FRP.RedrawLines()
			end)
			row:SetScript("OnClick", function() FRP.LoadRoute(idx) end)
			row.text:SetText((idx == cur.savedIndex and "> " or "") .. r.name)
			row.text:SetTextColor(r.color[1], r.color[2], r.color[3])
			row:Show()
		end
	end
	for i = shown + 1, #listRows do listRows[i]:Hide() end
	routeListChild:SetHeight(max(1, shown * 20))
	win.emptyList:SetShown(shown == 0)
end

function FRP.UpdateControls()
	if not win then return end
	zoneButton.text:SetText(MapName(cur.mapID))
	win.loopBtn:SetText(cur.closed and "Loop: On" or "Loop: Off")
	win.colorSwatch:SetColorTexture(cur.color[1], cur.color[2], cur.color[3], 1)
	if not nameBox:HasFocus() then nameBox:SetText(cur.name or "") end
	FRP.RefreshList()
	FRP.RedrawLines()
end

local function WithUnsavedCheck(fn)
	if cur and cur.dirty and #cur.points > 0 then
		Confirm("You have unsaved changes to this route. Discard them?", fn)
	else
		fn()
	end
end

function FRP.SetZone(mapID)
	if not mapID then return end
	NewWorking(mapID)
	wipe(strokes)
	LoadMapArt(mapID)
	FRP.UpdateControls()
end

function FRP.LoadRoute(idx)
	local r = db.routes[idx]
	if not r then return end
	WithUnsavedCheck(function()
		if r.mapID ~= cur.mapID then LoadMapArt(r.mapID) end
		cur = CopyRoute(r)
		cur.savedIndex = idx
		cur.dirty = false
		wipe(strokes)
		FRP.UpdateControls()
	end)
end

function FRP.Save()
	local name = Clean(nameBox:GetText())
	if name == "" then Print("Type a name for the route first."); nameBox:SetFocus() return end
	if #cur.points < 2 then Print("Draw at least two points before saving.") return end
	cur.name = name
	local copy = CopyRoute(cur)
	if cur.savedIndex and db.routes[cur.savedIndex] and db.routes[cur.savedIndex].name == name then
		copy.visible = db.routes[cur.savedIndex].visible
		db.routes[cur.savedIndex] = copy
	else
		tinsert(db.routes, copy)
		cur.savedIndex = #db.routes
	end
	cur.dirty = false
	Print("Saved '" .. name .. "' in " .. MapName(cur.mapID) .. ".")
	FRP.UpdateControls()
end

local function MarkEdited()
	cur.dirty = true
	Invalidate(cur)
	FRP.RedrawLines()
end

-- Cursor -> normalized (0-1) map coords, or nil if outside
local function CursorPos()
	local s = mapFrame:GetEffectiveScale()
	local cx, cy = GetCursorPosition()
	cx, cy = cx / s, cy / s
	local left, top = mapFrame:GetLeft(), mapFrame:GetTop()
	if not left then return nil end
	local x = (cx - left) / MAP_W
	local y = (top - cy) / MAP_H
	if x < 0 or x > 1 or y < 0 or y > 1 then return nil end
	return x, y
end

-- Undo history: snapshots of the point list taken before each edit.
local function PushUndo()
	local snap = {}
	for i, p in ipairs(cur.points) do snap[i] = { p[1], p[2] } end
	tinsert(strokes, snap)
	if #strokes > 100 then tremove(strokes, 1) end
end

local GRAB_PX = 7 -- how close (in pixels) the cursor must be to grab a point

-- Closest existing point to (x, y): index, distance in pixels
local function NearestPoint(x, y)
	local best, bestD
	for i, p in ipairs(cur.points) do
		local dx, dy = (p[1] - x) * MAP_W, (p[2] - y) * MAP_H
		local d = sqrt(dx * dx + dy * dy)
		if not bestD or d < bestD then best, bestD = i, d end
	end
	return best, bestD
end

-- Index to insert at so (x, y) lands in the closest segment of the route
local function InsertIndex(x, y)
	local pts, n = cur.points, #cur.points
	if n < 2 then return n + 1 end
	local last = (cur.closed and n > 2) and n or n - 1
	local bestI, bestD = n + 1, math.huge
	local cx, cy = x * MAP_W, y * MAP_H
	for i = 1, last do
		local a, b = pts[i], pts[i % n + 1]
		local ax, ay, bx, by = a[1] * MAP_W, a[2] * MAP_H, b[1] * MAP_W, b[2] * MAP_H
		local dx, dy = bx - ax, by - ay
		local len2 = dx * dx + dy * dy
		local t = len2 > 0 and max(0, min(1, ((cx - ax) * dx + (cy - ay) * dy) / len2)) or 0
		local ex, ey = ax + dx * t - cx, ay + dy * t - cy
		local d = ex * ex + ey * ey
		if d < bestD then bestI, bestD = i + 1, d end
	end
	return bestI
end

-- New points always go right after the selected point (cur.sel; nil = the last point),
-- and the new point becomes the selection, so points stay in the order you add them.
local function AddAfterSelection(x, y)
	local i = (cur.sel or #cur.points) + 1
	tinsert(cur.points, i, { x, y })
	cur.sel = (i < #cur.points) and i or nil
	MarkEdited()
	return i
end

local function SetupDrawing()
	mapFrame:EnableMouse(true)
	local mode, lastX, lastY, moveIdx -- mode: "draw" (freehand append) or "move"
	mapFrame:SetScript("OnMouseDown", function(_, button)
		zoneMenu:Hide()
		local x, y = CursorPos()
		if button == "RightButton" then
			if #cur.points == 0 then return end
			PushUndo()
			-- right-click on a point deletes it; anywhere else deletes the selected point
			local idx, d
			if x then idx, d = NearestPoint(x, y) end
			if not (idx and d <= GRAB_PX) then idx = cur.sel or #cur.points end
			tremove(cur.points, idx)
			local sel = cur.sel or (#cur.points + 1)
			if idx <= sel then sel = sel - 1 end
			cur.sel = (sel >= 1 and sel < #cur.points) and sel or nil
			MarkEdited()
			return
		end
		if button ~= "LeftButton" or not x then return end
		PushUndo()
		local idx, d = NearestPoint(x, y)
		if idx and d <= GRAB_PX then
			-- click a point to select it (new points go after it); drag to move it
			cur.sel = (idx < #cur.points) and idx or nil
			mode, moveIdx = "move", idx
			FRP.RedrawLines()
			return
		end
		-- one click = one point; the route is straight lines between points.
		-- Holding the button lets you nudge the new point before letting go.
		mode, moveIdx = "move", AddAfterSelection(x, y)
	end)
	mapFrame:SetScript("OnMouseUp", function() mode = nil end)
	mapFrame:SetScript("OnUpdate", function()
		if not mode then return end
		if not IsMouseButtonDown("LeftButton") then mode = nil return end
		local x, y = CursorPos()
		if not x then return end
		if mode == "move" then
			local p = cur.points[moveIdx]
			if p and (p[1] ~= x or p[2] ~= y) then
				p[1], p[2] = x, y
				MarkEdited()
			end
			return
		end
		local dx, dy = x - lastX, y - lastY
		if dx * dx + dy * dy >= FREEHAND_STEP * FREEHAND_STEP then
			lastX, lastY = x, y
			AddAfterSelection(x, y)
		end
	end)
end

local function Undo()
	local snap = tremove(strokes)
	if snap then
		cur.points = snap
		cur.sel = nil
	elseif #cur.points > 0 then
		tremove(cur.points)
	else
		return
	end
	MarkEdited()
end

-- Build a looping route through every GatherMate2 node of the ticked types in this zone.
function FRP.ImportGatherMate()
	if not db.gmEnabled then Print("Tick 'Use GatherMate2 data' first.") return end
	local nodes, err = GatherNodes(cur.mapID)
	if not nodes then Print(err) return end
	-- distances in yards when the map size is known, otherwise in map units scaled by aspect
	local mw, mh
	if FRP.MapYards then mw, mh = FRP.MapYards(cur.mapID) end
	local MERGE
	if not (mw and mh) then mw, mh, MERGE = MAP_W / MAP_H, 1, 0.002 else MERGE = 5 end
	local function D(a, b)
		local dx, dy = (a[1] - b[1]) * mw, (a[2] - b[2]) * mh
		return sqrt(dx * dx + dy * dy)
	end
	-- only merge records that are essentially the same spot (GatherMate2 duplicates)
	local merged = {}
	for _, n in ipairs(nodes) do
		local dup
		for _, m in ipairs(merged) do
			if D(m, n) < MERGE then dup = true break end
		end
		if not dup then merged[#merged + 1] = { n[1], n[2] } end
	end
	if #merged < 2 then
		Print("Found " .. #merged .. " GatherMate2 node(s) of the ticked types in " .. MapName(cur.mapID) .. ". Need at least 2.")
		return
	end

	local function Build()
		local n = #merged
		-- start at the node closest to the player (if they're in this zone)
		local start = 1
		local pos = C_Map.GetPlayerMapPosition(cur.mapID, "player")
		if pos then
			local p, bestD = { pos:GetXY() }, math.huge
			for i, m in ipairs(merged) do
				local d = D(p, m)
				if d < bestD then start, bestD = i, d end
			end
		end
		-- nearest-neighbour tour
		local used, tour = { [start] = true }, { merged[start] }
		for _ = 2, n do
			local last, best, bestD = tour[#tour], nil, math.huge
			for i, m in ipairs(merged) do
				if not used[i] then
					local d = D(last, m)
					if d < bestD then best, bestD = i, d end
				end
			end
			used[best] = true
			tour[#tour + 1] = merged[best]
		end
		-- 2-opt: undo crossings to shorten the loop (time-limited so the game doesn't stall)
		local t0 = debugprofilestop and debugprofilestop() or 0
		local improved, passes = true, 0
		while improved and passes < 25 do
			improved, passes = false, passes + 1
			for i = 2, n - 1 do
				for k = i + 1, n do
					local a, b, c, d = tour[i - 1], tour[i], tour[k], tour[k % n + 1]
					if D(a, b) + D(c, d) > D(a, c) + D(b, d) + 1e-9 then
						local lo, hi = i, k
						while lo < hi do tour[lo], tour[hi] = tour[hi], tour[lo]; lo, hi = lo + 1, hi - 1 end
						improved = true
					end
				end
			end
			if debugprofilestop and debugprofilestop() - t0 > 400 then break end
		end

		PushUndo()
		cur.points = {}
		for i, p in ipairs(tour) do cur.points[i] = { p[1], p[2] } end
		cur.closed = true
		cur.sel = nil
		if cur.name == "" then cur.name = "GatherMate route" end
		MarkEdited()
		FRP.UpdateControls()
		Print("Built a loop through " .. n .. " GatherMate2 nodes. Edit it if you like, then click Save.")
	end

	if #cur.points > 0 then
		Confirm("Replace the current route with a route through " .. #merged .. " GatherMate2 nodes?", function()
			local ok, e = pcall(Build)
			if not ok then Print("|cffff6060Couldn't build the route:|r " .. tostring(e)) end
		end)
	else
		Build()
	end
end

local function MakeButton(parent, text, w, onClick, tip)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(w, 22); b:SetText(text)
	b:SetScript("OnClick", onClick)
	if tip then
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(tip, 1, 1, 1, 1, true); GameTooltip:Show()
		end)
		b:SetScript("OnLeave", GameTooltip_Hide)
	end
	return b
end

local function BuildZoneMenu()
	zoneMenu = CreateFrame("Frame", nil, win, Backdrop)
	zoneMenu:SetPoint("TOPLEFT", zoneButton, "BOTTOMLEFT", 0, -2)
	zoneMenu:SetSize(260, 360)
	zoneMenu:SetFrameStrata("FULLSCREEN")
	ApplyBackdrop(zoneMenu, 0.97)
	zoneMenu:EnableMouse(true)
	zoneMenu:Hide()
	local sf = CreateFrame("ScrollFrame", "FarmRoutePlannerZoneScroll", zoneMenu, "UIPanelScrollFrameTemplate")
	sf:SetPoint("TOPLEFT", 8, -8); sf:SetPoint("BOTTOMRIGHT", -30, 8)
	local child = CreateFrame("Frame", nil, sf)
	child:SetSize(220, 1)
	sf:SetScrollChild(child)
	zoneMenu.child = child
	zoneMenu.rows = {}
	zoneMenu:SetScript("OnShow", function()
		local list = BuildZoneList()
		for i, z in ipairs(list) do
			local row = zoneMenu.rows[i]
			if not row then
				row = CreateFrame("Button", nil, child)
				row:SetSize(220, 18)
				row:SetPoint("TOPLEFT", 0, -(i - 1) * 18)
				row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
				row.text:SetPoint("LEFT", 4, 0)
				row.hl = row:CreateTexture(nil, "HIGHLIGHT")
				row.hl:SetAllPoints(); row.hl:SetColorTexture(1, 1, 1, 0.15)
				zoneMenu.rows[i] = row
			end
			if z.header then
				row.text:SetText("|cffffd100" .. z.name .. "|r")
				row:SetScript("OnClick", nil)
				row:EnableMouse(false)
			else
				row.text:SetText("   " .. z.name .. (z.mapID == cur.mapID and "  |cff66ff66*|r" or ""))
				row:EnableMouse(true)
				row:SetScript("OnClick", function()
					zoneMenu:Hide()
					WithUnsavedCheck(function() FRP.SetZone(z.mapID) end)
				end)
			end
			row:Show()
		end
		for i = #list + 1, #zoneMenu.rows do zoneMenu.rows[i]:Hide() end
		child:SetHeight(max(1, #list * 18))
	end)
end

local function BuildWindow()
	hasLines = UIParent.CreateLine ~= nil

	win = CreateFrame("Frame", "FarmRoutePlannerFrame", UIParent, Backdrop)
	win:SetSize(MAP_W + 260, MAP_H + 104)
	win:SetPoint("CENTER")
	win:SetFrameStrata("HIGH")
	win:SetToplevel(true)
	ApplyBackdrop(win, 0.95)
	win:EnableMouse(true); win:SetMovable(true); win:SetClampedToScreen(true)
	win:RegisterForDrag("LeftButton")
	win:SetScript("OnDragStart", win.StartMoving)
	win:SetScript("OnDragStop", win.StopMovingOrSizing)
	win:Hide()
	tinsert(UISpecialFrames, "FarmRoutePlannerFrame")

	local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -14)
	title:SetText("Farm Route Planner")

	local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	-- Zone dropdown
	zoneButton = CreateFrame("Button", nil, win, Backdrop)
	zoneButton:SetSize(260, 24)
	zoneButton:SetPoint("TOPLEFT", 200, -12)
	ApplyBackdrop(zoneButton, 1)
	if zoneButton.SetBackdrop then
		zoneButton:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
		zoneButton:SetBackdropColor(0.1, 0.1, 0.1, 1)
	end
	zoneButton.text = zoneButton:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	zoneButton.text:SetPoint("LEFT", 8, 0); zoneButton.text:SetPoint("RIGHT", -22, 0)
	zoneButton.text:SetJustifyH("LEFT")
	local arrow = zoneButton:CreateTexture(nil, "OVERLAY")
	arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
	arrow:SetSize(20, 20); arrow:SetPoint("RIGHT", -2, 0)
	zoneButton:SetScript("OnClick", function() zoneMenu:SetShown(not zoneMenu:IsShown()) end)

	local here = MakeButton(win, "My Zone", 80, function()
		WithUnsavedCheck(function() FRP.SetZone(PlayerZone()) end)
	end, "Switch to the zone you are standing in.")
	here:SetPoint("LEFT", zoneButton, "RIGHT", 6, 0)

	-- Map area
	mapFrame = CreateFrame("Frame", nil, win)
	mapFrame:SetSize(MAP_W, MAP_H)
	mapFrame:SetPoint("TOPLEFT", 16, -46)
	if mapFrame.SetClipsChildren then mapFrame:SetClipsChildren(true) end
	local bg = mapFrame:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(); bg:SetColorTexture(0.05, 0.05, 0.05, 1)
	tileFrame = CreateFrame("Frame", nil, mapFrame)
	tileFrame:SetAllPoints()
	gmLayer = CreateFrame("Frame", nil, mapFrame)
	gmLayer:SetAllPoints()
	gmLayer:SetFrameLevel(tileFrame:GetFrameLevel() + 8) -- node icons above the route lines
	vertLayer = CreateFrame("Frame", nil, mapFrame)
	vertLayer:SetAllPoints()
	vertLayer:SetFrameLevel(tileFrame:GetFrameLevel() + 12) -- route points above node icons
	lineLayer = CreateFrame("Frame", nil, mapFrame)
	lineLayer:SetAllPoints()
	lineLayer:SetFrameLevel(tileFrame:GetFrameLevel() + 5)
	win.noArt = mapFrame:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	win.noArt:SetPoint("CENTER"); win.noArt:SetText("No map art for this zone - you can still draw.")

	local help = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	help:SetPoint("TOPLEFT", mapFrame, "BOTTOMLEFT", 0, -8)
	help:SetText("Click: add point after the green one   Click a point: select   Drag a point: move   Right-click: delete")
	win.pointCount = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	win.pointCount:SetPoint("TOPRIGHT", mapFrame, "BOTTOMRIGHT", 0, -8)

	-- GatherMate2: master checkbox, node types, import button
	local gmLabel = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	gmLabel:SetPoint("TOPLEFT", mapFrame, "BOTTOMLEFT", 0, -30)
	gmLabel:SetText("")
	local typeBoxes = {}
	local useGM = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
	useGM:SetSize(22, 22)
	useGM:SetPoint("LEFT", gmLabel, "LEFT", -4, 0)
	useGM.label = useGM:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	useGM.label:SetPoint("LEFT", useGM, "RIGHT", 1, 0); useGM.label:SetText("Use GatherMate2 data")
	local importGM
	local function UpdateGMControls()
		for _, cb in ipairs(typeBoxes) do
			if db.gmEnabled then cb:Enable(); cb.label:SetTextColor(1, 1, 1) else cb:Disable(); cb.label:SetTextColor(0.5, 0.5, 0.5) end
		end
		if importGM then importGM:SetEnabled(db.gmEnabled and true or false) end
		if typeBoxes.nodesBtn then typeBoxes.nodesBtn:SetEnabled(db.gmEnabled and true or false) end
		if not db.gmEnabled and FRP.HideNodePanel then FRP.HideNodePanel() end
	end
	useGM:SetScript("OnShow", function(self) self:SetChecked(db.gmEnabled); UpdateGMControls() end)
	useGM:SetScript("OnClick", function(self)
		db.gmEnabled = self:GetChecked() and true or false
		UpdateGMControls()
		if cur then DrawGatherMate(cur.mapID) end
	end)
	local gx = 140
	for _, t in ipairs(GM_TYPES) do
		local cb = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
		cb:SetSize(22, 22)
		cb:SetPoint("LEFT", gmLabel, "LEFT", gx, 0)
		cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		cb.label:SetPoint("LEFT", cb, "RIGHT", 1, 0); cb.label:SetText(t.label)
		cb:SetScript("OnShow", function(self) self:SetChecked(db.gm[t.key]) end)
		cb:SetScript("OnClick", function(self)
			db.gm[t.key] = self:GetChecked() and true or nil
			if cur then DrawGatherMate(cur.mapID) end
		end)
		typeBoxes[#typeBoxes + 1] = cb
		cb:HookScript("OnClick", function() if FRP.RefreshNodePanel then FRP.RefreshNodePanel() end end)
		gx = gx + 72
	end
	local nodesBtn = MakeButton(win, "Nodes...", 70, function() FRP.ToggleNodePanel() end,
		"Choose which kinds of node (Copper Vein, Peacebloom, ...) to show and to include in the optimized route.")
	nodesBtn:SetPoint("LEFT", gmLabel, "LEFT", gx, 0)
	typeBoxes.nodesBtn = nodesBtn
	importGM = MakeButton(win, "GatherMate Optimized Route", 170, function()
		-- report problems in chat instead of failing silently (Lua errors may be hidden)
		local ok, e = pcall(FRP.ImportGatherMate)
		if not ok then Print("|cffff6060Couldn't build the route:|r " .. tostring(e)) end
	end,
		"Build the shortest loop we can find through every chosen GatherMate2 node in this zone.")
	importGM:SetPoint("LEFT", nodesBtn, "RIGHT", 4, 0)
	-- size the button to its label; use the smaller font if it would run past the map edge
	do
		local fs = importGM:GetFontString()
		local room = 200
		if fs and fs:GetStringWidth() + 24 > room then
			importGM:SetNormalFontObject("GameFontNormalSmall")
			importGM:SetHighlightFontObject("GameFontHighlightSmall")
			importGM:SetDisabledFontObject("GameFontDisableSmall")
		end
		if fs then importGM:SetWidth(min(room, fs:GetStringWidth() + 24)) end
	end
	win.gmStatus = mapFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	win.gmStatus:SetPoint("BOTTOMRIGHT", mapFrame, "BOTTOMRIGHT", -6, 6)

	-- Sidebar
	local sx = MAP_W + 32
	local nameLabel = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	nameLabel:SetPoint("TOPLEFT", sx, -48); nameLabel:SetText("Route name")
	nameBox = CreateFrame("EditBox", "FarmRoutePlannerNameBox", win, "InputBoxTemplate")
	nameBox:SetSize(200, 20); nameBox:SetPoint("TOPLEFT", sx + 6, -64)
	nameBox:SetAutoFocus(false); nameBox:SetMaxLetters(60)
	nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); FRP.Save() end)
	nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	local y = -92
	local function Place(b, x) b:SetPoint("TOPLEFT", sx + (x or 0), y) end
	local save = MakeButton(win, "Save", 98, FRP.Save, "Save this route under the name above. Saving with a new name makes a copy.")
	Place(save)
	local new = MakeButton(win, "New", 98, function()
		WithUnsavedCheck(function() FRP.SetZone(cur.mapID) end)
	end, "Start a blank route in this zone.")
	Place(new, 104)
	y = y - 26
	Place(MakeButton(win, "Undo", 98, Undo, "Remove the last stroke."))
	Place(MakeButton(win, "Clear", 98, function()
		if #cur.points > 0 then PushUndo(); cur.points = {}; cur.sel = nil; MarkEdited() end
	end, "Remove every point."), 104)
	y = y - 26
	win.loopBtn = MakeButton(win, "Loop: On", 98, function()
		cur.closed = not cur.closed; MarkEdited(); FRP.UpdateControls()
	end, "Join the last point back to the first.")
	Place(win.loopBtn)
	local colorBtn = MakeButton(win, "Color", 74, function()
		cur._ci = ((cur._ci or 0) % #PALETTE) + 1
		local c = PALETTE[cur._ci]
		cur.color = { c[1], c[2], c[3] }
		MarkEdited(); FRP.UpdateControls()
	end, "Change the route color.")
	Place(colorBtn, 104)
	win.colorSwatch = win:CreateTexture(nil, "OVERLAY")
	win.colorSwatch:SetSize(18, 18)
	win.colorSwatch:SetPoint("LEFT", colorBtn, "RIGHT", 6, 0)
	y = y - 26
	Place(MakeButton(win, "Export", 98, function()
		if #cur.points < 2 then Print("Draw or load a route first.") return end
		if cur.name == "" then cur.name = Clean(nameBox:GetText()) end
		ShowDialog("Copy this string with Ctrl+C and share it", FRP.Export({ cur }))
	end, "Get a string for this route to share."))
	Place(MakeButton(win, "Import", 98, function()
		ShowDialog("Paste a route string with Ctrl+V, then click Okay", "", function(text)
			local n, res = FRP.Import(text)
			if n == 0 then Print(res) return end
			Print("Imported " .. n .. " route(s).")
			cur.dirty = false
			FRP.LoadRoute(res)
		end)
	end, "Add routes from someone else's string."), 104)
	y = y - 26
	Place(MakeButton(win, "Delete Saved", 202, function()
		local idx = cur.savedIndex
		local r = idx and db.routes[idx]
		if not r then Print("This route hasn't been saved.") return end
		Confirm("Delete the saved route '" .. r.name .. "'?", function()
			tremove(db.routes, idx)
			FRP.SetZone(cur.mapID)
		end)
	end, "Delete the selected saved route."))
	y = y - 26
	local followBtn = MakeButton(win, "Follow (TomTom)", 120, function()
		if follow then FRP.StopFollow() else FRP.StartFollow(cur) end
	end, "Point the TomTom arrow along this route, one point after another.")
	Place(followBtn)
	local distBtn = MakeButton(win, "", 78, function(self, button)
		FRP.CycleFollowDistance()
	end, "How close you must get (in yards) before the arrow moves to the next point. Click to change.")
	Place(distBtn, 124)
	FRP.UpdateFollowButton = function()
		followBtn:SetText(follow and "Stop Following" or "Follow (TomTom)")
		distBtn:SetText("At " .. db.followDist .. " yd")
	end
	FRP.UpdateFollowButton()
	y = y - 26
	local recBtn = MakeButton(win, "Record Path", 120, function() FRP.ToggleRecord() end,
		"Add a point every few yards as you walk. Points go in after the green (selected) point, so you can select a node on an optimized route and record the real path to the next one.")
	Place(recBtn)
	local stepBtn = MakeButton(win, "", 78, function() FRP.CycleRecordStep() end,
		"How far you walk between recorded points. Click to change.")
	Place(stepBtn, 124)
	FRP.UpdateRecordButton = function()
		recBtn:SetText(FRP.IsRecording() and "|cffff4040Stop Recording|r" or "Record Path")
		stepBtn:SetText("Every " .. db.recordStep .. " yd")
	end
	FRP.UpdateRecordButton()
	y = y - 30

	local mm = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
	mm:SetSize(24, 24); mm:SetPoint("TOPLEFT", sx, y)
	mm.label = mm:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	mm.label:SetPoint("LEFT", mm, "RIGHT", 2, 0); mm.label:SetText("Show routes on minimap")
	mm:SetScript("OnShow", function(self) self:SetChecked(db.minimap) end)
	mm:SetScript("OnClick", function(self) db.minimap = self:GetChecked() and true or false end)
	y = y - 24
	local others = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
	others:SetSize(24, 24); others:SetPoint("TOPLEFT", sx, y)
	others.label = others:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	others.label:SetPoint("LEFT", others, "RIGHT", 2, 0); others.label:SetText("Show other saved routes here")
	others:SetScript("OnShow", function(self) self:SetChecked(db.showOthers) end)
	others:SetScript("OnClick", function(self) db.showOthers = self:GetChecked() and true or false; FRP.RedrawLines() end)
	y = y - 24
	local wm = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
	wm:SetSize(24, 24); wm:SetPoint("TOPLEFT", sx, y)
	wm.label = wm:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	wm.label:SetPoint("LEFT", wm, "RIGHT", 2, 0); wm.label:SetText("Show routes on world map")
	wm:SetScript("OnShow", function(self) self:SetChecked(db.worldmap) end)
	wm:SetScript("OnClick", function(self) db.worldmap = self:GetChecked() and true or false; FRP.RedrawWorldMap() end)
	y = y - 24
	local ringCb = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
	ringCb:SetSize(24, 24); ringCb:SetPoint("TOPLEFT", sx, y)
	ringCb.label = ringCb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ringCb.label:SetPoint("LEFT", ringCb, "RIGHT", 2, 0); ringCb.label:SetText("Range ring on minimap")
	ringCb:SetScript("OnShow", function(self) self:SetChecked(db.ring) end)
	ringCb:SetScript("OnClick", function(self) db.ring = self:GetChecked() and true or false end)
	ringCb:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("A ring around you on the minimap. Default 185 yards, about the Find Minerals / Find Herbs range. 'GM dist' uses GatherMate2's tracking distance from /gm.", 1, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	ringCb:SetScript("OnLeave", GameTooltip_Hide)
	local RING_CHOICES = { 50, 75, 100, 125, 150, 185, 200, 240, "GM" }
	local ringBtn = MakeButton(win, "", 70, function(self)
		local nextV = RING_CHOICES[1]
		for i, v in ipairs(RING_CHOICES) do
			if v == db.ringYards then nextV = RING_CHOICES[i % #RING_CHOICES + 1] break end
		end
		db.ringYards = nextV
		self:SetText(type(nextV) == "number" and (nextV .. " yd") or "GM dist")
		FRP.SyncGatherMateDistance()
	end, "Ring size. Click to change. A yard value is also used as GatherMate2's tracking distance; 'GM dist' follows GatherMate2's own setting from /gm instead.")
	ringBtn:SetPoint("LEFT", ringCb.label, "RIGHT", 6, 0)
	ringBtn:SetText(type(db.ringYards) == "number" and (db.ringYards .. " yd") or "GM dist")
	y = y - 30

	local listLabel = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	listLabel:SetPoint("TOPLEFT", sx, y); listLabel:SetText("Saved routes in this zone")
	y = y - 16
	local listBox = CreateFrame("Frame", nil, win, Backdrop)
	listBox:SetPoint("TOPLEFT", sx - 4, y)
	listBox:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -14, 14)
	if listBox.SetBackdrop then
		listBox:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
		listBox:SetBackdropColor(0, 0, 0, 0.5)
	end
	local sf = CreateFrame("ScrollFrame", "FarmRoutePlannerListScroll", listBox, "UIPanelScrollFrameTemplate")
	sf:SetPoint("TOPLEFT", 6, -6); sf:SetPoint("BOTTOMRIGHT", -26, 6)
	routeListChild = CreateFrame("Frame", nil, sf)
	routeListChild:SetSize(196, 1)
	sf:SetScrollChild(routeListChild)
	win.emptyList = listBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	win.emptyList:SetPoint("TOP", 0, -12); win.emptyList:SetText("None yet")

	BuildZoneMenu()
	SetupDrawing()
	win:SetScript("OnHide", function() zoneMenu:Hide() end)
end

---------------------------------------------------------------------------
-- Node kinds panel: tick/untick individual GatherMate2 node kinds
---------------------------------------------------------------------------
local nodePanel
local nodeRows = {}

local function SetExcluded(typeKey, nodeID, excluded)
	db.gmExclude[typeKey] = db.gmExclude[typeKey] or {}
	db.gmExclude[typeKey][nodeID] = excluded or nil
end

function FRP.RefreshNodePanel()
	if not nodePanel or not nodePanel:IsShown() or not cur then return end
	nodePanel.title:SetText("Nodes in " .. MapName(cur.mapID))
	local kinds = ZoneNodeKinds(cur.mapID)
	local child = nodePanel.child
	local y, row = 0, 0
	local lastType
	for _, k in ipairs(kinds) do
		if k.typeKey ~= lastType then
			-- type header row
			row = row + 1
			local r = nodeRows[row] or CreateFrame("Frame", nil, child)
			nodeRows[row] = r
			r:SetSize(220, 18)
			r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y)
			r.text = r.text or r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			r.text:ClearAllPoints(); r.text:SetPoint("LEFT", 2, 0)
			r.text:SetText(k.typeLabel)
			if r.check then r.check:Hide() end
			if r.icon then r.icon:Hide() end
			r:Show()
			y, lastType = y + 18, k.typeKey
		end
		row = row + 1
		local r = nodeRows[row] or CreateFrame("Frame", nil, child)
		nodeRows[row] = r
		r:SetSize(220, 20)
		r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y)
		if not r.check then
			r.check = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
			r.check:SetSize(20, 20); r.check:SetPoint("LEFT", 8, 0)
		end
		if not r.icon then
			r.icon = r:CreateTexture(nil, "ARTWORK")
			r.icon:SetSize(14, 14)
		end
		r.icon:ClearAllPoints(); r.icon:SetPoint("LEFT", r.check, "RIGHT", 2, 0)
		r.text = r.text or r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		r.text:ClearAllPoints(); r.text:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
		r.text:SetText(k.name .. "  |cff999999(" .. k.count .. ")|r")
		r.icon:SetTexture(k.icon); r.icon:Show()
		r.check:SetChecked(not Excluded(k.typeKey, k.id)); r.check:Show()
		r.check:SetScript("OnClick", function(self)
			SetExcluded(k.typeKey, k.id, not self:GetChecked())
			DrawGatherMate(cur.mapID)
		end)
		r:Show()
		y = y + 20
	end
	for i = row + 1, #nodeRows do nodeRows[i]:Hide() end
	child:SetHeight(max(1, y))
	nodePanel.empty:SetShown(#kinds == 0)
	nodePanel.kinds = kinds
end

local function BuildNodePanel()
	nodePanel = CreateFrame("Frame", nil, win, Backdrop)
	nodePanel:SetSize(270, 330)
	nodePanel:SetPoint("BOTTOMLEFT", mapFrame, "BOTTOMLEFT", 4, 4)
	nodePanel:SetFrameStrata("DIALOG")
	ApplyBackdrop(nodePanel, 0.95)
	nodePanel:EnableMouse(true)
	nodePanel:Hide()

	nodePanel.title = nodePanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	nodePanel.title:SetPoint("TOPLEFT", 12, -12)
	nodePanel.title:SetPoint("RIGHT", -30, 0); nodePanel.title:SetJustifyH("LEFT")
	local close = CreateFrame("Button", nil, nodePanel, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -2, -2)

	local function SetAll(include)
		for _, k in ipairs(nodePanel.kinds or {}) do SetExcluded(k.typeKey, k.id, not include) end
		DrawGatherMate(cur.mapID)
	end
	local all = MakeButton(nodePanel, "All", 60, function() SetAll(true) end)
	all:SetPoint("TOPLEFT", 12, -32)
	local none = MakeButton(nodePanel, "None", 60, function() SetAll(false) end)
	none:SetPoint("LEFT", all, "RIGHT", 4, 0)
	local hint = nodePanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("LEFT", none, "RIGHT", 8, 0); hint:SetText("(count in this zone)")

	local sf = CreateFrame("ScrollFrame", "FarmRoutePlannerNodeScroll", nodePanel, "UIPanelScrollFrameTemplate")
	sf:SetPoint("TOPLEFT", 10, -60); sf:SetPoint("BOTTOMRIGHT", -30, 10)
	nodePanel.child = CreateFrame("Frame", nil, sf)
	nodePanel.child:SetSize(220, 1)
	sf:SetScrollChild(nodePanel.child)
	nodePanel.empty = nodePanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	nodePanel.empty:SetPoint("TOP", 0, -80); nodePanel.empty:SetWidth(230)
	nodePanel.empty:SetText("No GatherMate2 nodes of the ticked types in this zone.\n\nGatherMate2 only knows nodes you've gathered or imported. To import: /gm, then Import Data, tick the types, click Import.")
	nodePanel:SetScript("OnShow", FRP.RefreshNodePanel)
end

function FRP.ToggleNodePanel()
	if not nodePanel then BuildNodePanel() end
	nodePanel:SetShown(not nodePanel:IsShown())
end

function FRP.HideNodePanel()
	if nodePanel then nodePanel:Hide() end
end

function FRP.Toggle()
	if not win then BuildWindow() end
	if win:IsShown() then win:Hide() return end
	win:Show()
	if not cur then FRP.SetZone(PlayerZone()) else LoadMapArt(cur.mapID); FRP.UpdateControls() end
end

---------------------------------------------------------------------------
-- Minimap route display
---------------------------------------------------------------------------
local mmLayer
local mmPool, mmUsed = {}, {}
local indoors = "outdoor"
local MAX_MM_DOTS = 500

local function UpdateIndoors()
	local zoom = Minimap:GetZoom()
	if GetCVar("minimapZoom") == GetCVar("minimapInsideZoom") then
		Minimap:SetZoom(zoom < 2 and zoom + 1 or zoom - 1)
	end
	indoors = (tonumber(GetCVar("minimapZoom")) == Minimap:GetZoom()) and "outdoor" or "indoor"
	Minimap:SetZoom(zoom)
end

---------------------------------------------------------------------------
-- Line helper: uses the client's Line objects when they work, otherwise a
-- stretched, rotated texture. Coordinates are offsets from `anchor` on
-- `layer` with x to the right and y UP (standard frame offsets).
---------------------------------------------------------------------------
local function NewLine(layer)
	if layer.CreateLine then
		local ok, l = pcall(layer.CreateLine, layer, nil, "ARTWORK")
		if ok and l and l.SetStartPoint then l.isLine = true; return l end
	end
	local t = layer:CreateTexture(nil, "ARTWORK") -- below the minimap arrows (OVERLAY)
	t:SetTexture("Interface\\Buttons\\WHITE8X8")
	return t
end

local function PlaceLine(l, layer, anchor, ax, ay, bx, by, thick, c, alpha)
	if l.isLine then
		l:SetColorTexture(c[1], c[2], c[3], alpha)
		l:SetThickness(thick)
		l:SetStartPoint(anchor, layer, ax, ay)
		l:SetEndPoint(anchor, layer, bx, by)
	else
		local dx, dy = bx - ax, by - ay
		l:SetVertexColor(c[1], c[2], c[3], alpha)
		l:SetSize(max(sqrt(dx * dx + dy * dy), 1), thick)
		l:ClearAllPoints()
		l:SetPoint("CENTER", layer, anchor, (ax + bx) / 2, (ay + by) / 2)
		if l.SetRotation then l:SetRotation(atan2(dy, dx)) end
	end
	l:Show()
end

local mmLinePool, mmLinesUsed = {}, {}

local function AcquireMMDot()
	local t = tremove(mmPool)
	if not t then
		t = mmLayer:CreateTexture(nil, "OVERLAY")
		t:SetTexture("Interface\\Minimap\\MinimapArrow")
		if t.SetDesaturated then t:SetDesaturated(true) end
	end
	t:Show(); mmUsed[#mmUsed + 1] = t
	return t
end

-- Size of a map in yards (cached).
local mapSize = {}
local function MapYards(mapID)
	local s = mapSize[mapID]
	if s ~= nil then return s and s[1], s and s[2] end
	local w, h
	if C_Map.GetMapWorldSize then w, h = C_Map.GetMapWorldSize(mapID) end
	if (not w or w == 0) and C_Map.GetWorldPosFromMapPos then
		local _, tl = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(0, 0))
		local _, br = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(1, 1))
		if tl and br then
			local top, left = tl:GetXY()
			local bottom, right = br:GetXY()
			w, h = math.abs(left - right), math.abs(top - bottom)
		end
	end
	mapSize[mapID] = (w and w > 0 and h and h > 0) and { w, h } or false
	return w, h
end
FRP.MapYards = MapYards

-- Measure the minimap's real pixels-per-yard by asking HereBeDragons to place an
-- invisible marker a known distance from the player and seeing how far away it lands.
-- This matches GatherMate2's icons exactly (FarmHud, indoor/outdoor, any zoom).
local CALIB_YARDS = 20
local calibPin = CreateFrame("Frame", nil, UIParent)
calibPin:SetSize(1, 1)
local measuredPPY, measuredKey
function FRP.MeasureMinimapScale(mm, HBDPins, hpx, hpy, hinst)
	if not (HBDPins and HBDPins.AddMinimapIconWorld and hpx and hinst) then return nil end
	local zoom = (mm.GetZoom and mm:GetZoom()) or Minimap:GetZoom()
	local key = tostring(mm) .. ":" .. tostring(zoom) .. ":" .. floor(mm:GetWidth()) .. ":" .. indoors
	if key ~= measuredKey then measuredPPY, measuredKey = nil, key end
	-- read where HereBeDragons put the marker on the previous update
	if calibPin:IsVisible() then
		local cx, cy = mm:GetCenter()
		local px, py = calibPin:GetCenter()
		if cx and px then
			local k = calibPin:GetEffectiveScale() / mm:GetEffectiveScale()
			local dx, dy = px * k - cx, py * k - cy
			local d = sqrt(dx * dx + dy * dy)
			local moving = GetUnitSpeed and GetUnitSpeed("player") > 0
			-- only trust readings taken while standing still (movement skews them slightly)
			if d > 0 and (not moving or not measuredPPY) then
				local ppy = d / CALIB_YARDS
				measuredPPY = measuredPPY and (measuredPPY * 0.7 + ppy * 0.3) or ppy
			end
		end
	end
	-- place the marker again for the next update
	HBDPins:AddMinimapIconWorld(FRP, calibPin, hinst, hpx + CALIB_YARDS, hpy, false)
	return measuredPPY
end

local NODE_GAP_PX = 12  -- line stops this many pixels short of each route point
local ARROW_GAP_PX = 34 -- arrows (45px) are kept this far from each route point
local function UpdateMinimap()
	for i = #mmUsed, 1, -1 do mmUsed[i]:Hide(); mmPool[#mmPool + 1] = tremove(mmUsed, i) end
	for i = #mmLinesUsed, 1, -1 do mmLinesUsed[i]:Hide(); mmLinePool[#mmLinePool + 1] = tremove(mmLinesUsed, i) end
	-- nothing to gather in dungeons, raids or battlegrounds: keep the minimap clear there
	local _, instanceType = IsInInstance()
	local inDungeon = instanceType == "party" or instanceType == "raid" or instanceType == "pvp"
	if inDungeon or (not db.minimap and not db.ring) then
		if FRP.mmRing then FRP.mmRing:Hide() end
		mmLayer:Hide()
		return
	end

	-- Use the same minimap frame and world coordinates as HereBeDragons (what GatherMate2
	-- uses for its minimap icons), so routes line up with nodes - including on FarmHud,
	-- which tells HereBeDragons to draw on its HUD frame instead of the normal minimap.
	local HBD = LibStub and LibStub("HereBeDragons-2.0", true)
	local HBDPins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)
	local mm = (HBDPins and HBDPins.Minimap) or Minimap
	-- FarmHud hides its HUD right away when it closes but hands HereBeDragons back the
	-- normal minimap a moment later; draw on the normal minimap during that gap.
	if mm ~= Minimap and not mm:IsVisible() and Minimap:IsVisible() then mm = Minimap end
	-- Our layer is a child of UIParent, not of the minimap: FarmHud moves every Minimap
	-- child onto a hidden dummy frame while the HUD is open (and doesn't give ours back),
	-- so we only line our layer up over whichever minimap is active.
	-- re-anchor whenever the active minimap changes, or if anything else moved our anchors
	local _, anchorRel = mmLayer:GetPoint(1)
	if mmLayer.anchoredTo ~= mm or anchorRel ~= mm then
		mmLayer:ClearAllPoints()
		mmLayer:SetAllPoints(mm)
		mmLayer.anchoredTo = mm
	end
	if mmLayer:GetParent() ~= UIParent then mmLayer:SetParent(UIParent) end
	-- match the minimap's scale so offsets measured in its units land in the right place
	local layerScale = mm:GetEffectiveScale() / UIParent:GetEffectiveScale()
	if layerScale > 0 and math.abs(mmLayer:GetScale() - layerScale) > 0.0001 then mmLayer:SetScale(layerScale) end
	mmLayer:SetShown(mm:IsVisible())
	if not mm:IsVisible() then return end
	-- just above the minimap itself, below the node pins HereBeDragons puts on it
	mmLayer:SetFrameStrata(mm:GetFrameStrata())
	mmLayer:SetFrameLevel(min(mm:GetFrameLevel() + 1, 9000))

	local hpx, hpy, hinst
	if HBD and HBD.GetPlayerWorldPosition then hpx, hpy, hinst = HBD:GetPlayerWorldPosition() end

	local halfW = mm:GetWidth() / 2
	local zoom = (mm.GetZoom and mm:GetZoom()) or Minimap:GetZoom()
	local scale -- pixels per yard, worked out the same way HereBeDragons does
	local viewRadius = C_Minimap and C_Minimap.GetViewRadius and C_Minimap.GetViewRadius()
	if viewRadius and viewRadius > 0 then
		scale = halfW / viewRadius -- the game's own answer: exact at any zoom, indoors or out
	else
		scale = FRP.MeasureMinimapScale(mm, HBDPins, hpx, hpy, hinst)
			or halfW / ((MINIMAP_YARDS[indoors][zoom] or 400) / 2)
	end
	local radius = halfW / scale -- yards from the centre to the edge of the minimap
	local limit2 = (radius * 0.94) ^ 2

	-- Node range ring: GatherMate2's tracking distance (its icons turn into red circles inside it)
	if FRP.mmRing then FRP.mmRing:Hide() end -- old texture ring from an earlier version
	if db.ring then
		local dist = tonumber(db.ringYards)
		if not dist then -- "GM": follow GatherMate2's tracking distance setting
			local gm = GetGatherMate()
			local profile = gm and gm.db and gm.db.profile
			dist = (profile and tonumber(profile.trackDistance)) or 100
		end
		local r = dist * scale
		if r <= halfW * 1.02 then -- skip when the ring would be bigger than the minimap
			local c = db.ringColor or { 1, 0.85, 0.1 }
			local SEG = 72
			local px0, py0 = r, 0
			for s = 1, SEG do
				local ang = s / SEG * 2 * math.pi
				local px1, py1 = r * cos(ang), r * sin(ang)
				local l = tremove(mmLinePool) or NewLine(mmLayer)
				PlaceLine(l, mmLayer, "CENTER", px0, py0, px1, py1, 2, c, 0.7)
				mmLinesUsed[#mmLinesUsed + 1] = l
				px0, py0 = px1, py1
			end
		end
	end
	if not db.minimap then return end
	local facing = (GetCVar("rotateMinimap") == "1" and GetPlayerFacing and GetPlayerFacing()) or 0
	local ca, sa = cos(-facing), sin(-facing)
	local spacing = 50 / scale -- yards between arrows, so 45px arrows sit ~50px apart
	local count = 0
	local posCache = {}

	-- Each route point as yards from the player, screen-oriented (x east, y north).
	local function Offsets(route)
		local pts = route.points
		local out = {}
		if hpx and HBD.GetWorldCoordinatesFromZone then
			local cache = route._hbd
			if not cache then
				cache = {}
				for i, p in ipairs(pts) do
					local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(p[1], p[2], route.mapID)
					if not wx then cache = false break end
					cache[i] = { wx, wy }
					cache.inst = inst
				end
				route._hbd = cache
			end
			if cache and cache.inst == hinst then
				for i, w in ipairs(cache) do out[i] = { hpx - w[1], w[2] - hpy } end
				return out
			end
			if cache then return nil end -- different continent/instance
		end
		-- fallback: the route's own map coordinates
		local pos = posCache[route.mapID]
		if pos == nil then
			pos = C_Map.GetPlayerMapPosition(route.mapID, "player") or false
			posCache[route.mapID] = pos
		end
		if not pos then return nil end
		local mw, mh = MapYards(route.mapID)
		if not mw then return nil end
		local px, py = pos:GetXY()
		for i, p in ipairs(pts) do out[i] = { (p[1] - px) * mw, -(p[2] - py) * mh } end
		return out
	end

	local function Plot(route)
		local n = #route.points
		if n < 2 or not route.mapID then return end
		local off = Offsets(route)
		if not off then return end
		local c = route.color
		local last = (route.closed and n > 2) and n or n - 1
		-- Arrows are spaced by distance along the whole route (measured from its start).
		local carry = 0 -- distance into the current segment where the next arrow goes
		for i = 1, last do
			local a, b = off[i], off[i % n + 1]
			local ax, ay, bx, by = a[1], a[2], b[1], b[2]
			local dx, dy = bx - ax, by - ay
			local len = sqrt(dx * dx + dy * dy)
			if len > 0 then
				local inRange = not (max(ax, bx) < -radius or min(ax, bx) > radius
					or max(ay, by) < -radius or min(ay, by) > radius)
				-- direction in minimap screen space after rotation (the arrow texture points up)
				local vx, vy = dx * ca - dy * sa, dx * sa + dy * ca
				local heading = atan2(vy, vx) - math.pi / 2
				if inRange then
					-- line between the two points, clipped to the round minimap
					local sx1, sy1 = (ax * ca - ay * sa) * scale, (ax * sa + ay * ca) * scale
					local sdx, sdy = vx * scale, vy * scale
					local R = halfW * 0.96
					local qa = sdx * sdx + sdy * sdy
					local qb = 2 * (sx1 * sdx + sy1 * sdy)
					local qc = sx1 * sx1 + sy1 * sy1 - R * R
					local disc = qb * qb - 4 * qa * qc
					if qa > 0 and disc > 0 then
						local root = sqrt(disc)
						-- leave a gap around each point so the line never runs over the node there
						local gap = NODE_GAP_PX / (len * scale)
						local t0 = max(gap, (-qb - root) / (2 * qa))
						local t1 = min(1 - gap, (-qb + root) / (2 * qa))
						if t0 < t1 then
							local l = tremove(mmLinePool) or NewLine(mmLayer)
							PlaceLine(l, mmLayer, "CENTER", sx1 + sdx * t0, sy1 + sdy * t0,
								sx1 + sdx * t1, sy1 + sdy * t1, 3, c, 0.85)
							mmLinesUsed[#mmLinesUsed + 1] = l
						end
					end
				end
				local keepOut = ARROW_GAP_PX / scale -- yards: no arrows this close to a point
				while carry <= len do
					if inRange and carry >= keepOut and (len - carry) >= keepOut then
						local t = carry / len
						local x, y = ax + dx * t, ay + dy * t
						if x * x + y * y <= limit2 then
							local rx, ry = x * ca - y * sa, x * sa + y * ca
							local d = AcquireMMDot()
							d:SetVertexColor(c[1], c[2], c[3], 1)
							d:SetSize(45, 45)
							if d.SetRotation then d:SetRotation(heading) end
							d:ClearAllPoints()
							d:SetPoint("CENTER", mmLayer, "CENTER", rx * scale, ry * scale)
							count = count + 1
							if count >= MAX_MM_DOTS then return end
						end
					end
					carry = carry + spacing
				end
				carry = carry - len
			end
		end
	end

	for idx, r in ipairs(db.routes) do
		if r.visible ~= false and not (cur and cur.savedIndex == idx and cur.dirty) then Plot(r) end
		if count >= MAX_MM_DOTS then return end
	end
	-- the route being edited (if unsaved or modified)
	if cur and #cur.points > 1 and (cur.dirty or not cur.savedIndex) then Plot(cur) end
end

---------------------------------------------------------------------------
-- Routes on Blizzard's world map
---------------------------------------------------------------------------
local wmCanvas, wmLayer
local wmLinePool, wmUsed = {}, {}

-- A route's points in another map's 0-1 coordinates (e.g. zone route on the continent map)
local function PointsOnMap(route, mapID)
	if route.mapID == mapID then return route.points end
	local world = GetWorld(route)
	if not world or not C_Map.GetMapPosFromWorldPos then return nil end
	local out = {}
	for i, wp in ipairs(world) do
		local _, pos = C_Map.GetMapPosFromWorldPos(world.inst, CreateVector2D(wp[1], wp[2]), mapID)
		if not pos then return nil end
		local x, y = pos:GetXY()
		if x < -0.5 or x > 1.5 or y < -0.5 or y > 1.5 then return nil end
		out[i] = { x, y }
	end
	return out
end

function FRP.RedrawWorldMap()
	if not wmLayer then return end
	for i = #wmUsed, 1, -1 do wmUsed[i]:Hide(); wmLinePool[#wmLinePool + 1] = tremove(wmUsed, i) end
	if not db.worldmap or not WorldMapFrame:IsShown() then return end
	-- Map art/exploration layers are pin frames with high frame levels; stay above them.
	local top = wmCanvas:GetFrameLevel()
	for _, child in ipairs({ wmCanvas:GetChildren() }) do
		if child ~= wmLayer then
			local t = child.pinTemplate
			-- map art detail layers have no pin template; explored terrain is the exploration pin
			if t == nil or (type(t) == "string" and t:find("Exploration")) then
				top = max(top, child:GetFrameLevel())
			end
		end
	end
	wmLayer:SetFrameStrata(wmCanvas:GetFrameStrata())
	wmLayer:SetFrameLevel(min(top + 1, 9000))
	local mapID = WorldMapFrame:GetMapID()
	local w, h = wmCanvas:GetSize()
	if not mapID or not w or w == 0 then return end
	local scale = wmCanvas:GetScale() or 1

	local function Draw(route)
		local pts = PointsOnMap(route, mapID)
		local n = pts and #pts or 0
		if n < 2 then return end
		local c = route.color
		local thick = (route.width or 3) / scale
		local last = (route.closed and n > 2) and n or n - 1
		for i = 1, last do
			local a, b = pts[i], pts[i % n + 1]
			local l = tremove(wmLinePool) or NewLine(wmLayer)
			PlaceLine(l, wmLayer, "TOPLEFT", a[1] * w, -a[2] * h, b[1] * w, -b[2] * h, thick, c, 0.9)
			wmUsed[#wmUsed + 1] = l
		end
	end

	for idx, r in ipairs(db.routes) do
		if r.visible ~= false and not (cur and cur.savedIndex == idx and cur.dirty) then Draw(r) end
	end
	if cur and #cur.points > 1 and (cur.dirty or not cur.savedIndex) then Draw(cur) end
end

local function SetupWorldMap()
	if wmLayer or not WorldMapFrame or not WorldMapFrame.ScrollContainer then return end
	wmCanvas = WorldMapFrame.ScrollContainer.Child
	wmLayer = CreateFrame("Frame", nil, wmCanvas)
	wmLayer:SetAllPoints()
	if WorldMapFrame.OnMapChanged then hooksecurefunc(WorldMapFrame, "OnMapChanged", FRP.RedrawWorldMap) end
	WorldMapFrame:HookScript("OnShow", FRP.RedrawWorldMap)
	wmCanvas:HookScript("OnSizeChanged", FRP.RedrawWorldMap)
	-- "FRP" button in the map's top-right corner: closes the world map and opens the
	-- planner on the zone being viewed
	local btn = CreateFrame("Button", "FarmRoutePlannerWorldMapButton", WorldMapFrame, "UIPanelButtonTemplate")
	btn:SetSize(46, 22); btn:SetText("FRP")
	btn:SetPoint("TOPRIGHT", WorldMapFrame.ScrollContainer, "TOPRIGHT", -6, -6)
	btn:SetFrameLevel(min(WorldMapFrame.ScrollContainer:GetFrameLevel() + 50, 9000))
	btn:SetScript("OnClick", function()
		local mapID = WorldMapFrame:GetMapID()
		local info = mapID and C_Map.GetMapInfo(mapID)
		HideUIPanel(WorldMapFrame)
		if not win or not win:IsShown() then FRP.Toggle() end
		if info and Enum and Enum.UIMapType and info.mapType == Enum.UIMapType.Zone then FRP.SetZone(mapID) end
	end)
	btn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Farm Route Planner", 1, 1, 1)
		GameTooltip:AddLine("Open the planner on this zone.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", GameTooltip_Hide)

	local lastScale, lastMap
	wmLayer:SetScript("OnUpdate", function()
		local s, m = wmCanvas:GetScale(), WorldMapFrame:GetMapID()
		if s ~= lastScale or m ~= lastMap then lastScale, lastMap = s, m; FRP.RedrawWorldMap() end
	end)
end

---------------------------------------------------------------------------
-- TomTom follow mode: point the TomTom arrow at the next spot on the route,
-- and move on once the player is within db.followDist yards of it.
---------------------------------------------------------------------------
local FOLLOW_DISTANCES = { 5, 10, 15, 20, 30, 40, 50, 75, 100 }
local follow -- { route=, idx=, uid= }
local followFrame = CreateFrame("Frame")

local function TomTomOK() return TomTom and TomTom.AddWaypoint and TomTom.RemoveWaypoint end

local function FollowDist(i, px, py, mw, mh)
	local p = follow.route.points[i]
	local dx, dy = (p[1] - px) * mw, (p[2] - py) * mh
	return sqrt(dx * dx + dy * dy)
end

local function NextIndex(i)
	local n = #follow.route.points
	if i < n then return i + 1 end
	if follow.route.closed then return 1 end
	return nil
end

local function SetFollowWaypoint()
	if follow.uid then TomTom:RemoveWaypoint(follow.uid); follow.uid = nil end
	local r = follow.route
	local p = r.points[follow.idx]
	follow.uid = TomTom:AddWaypoint(r.mapID, p[1], p[2], {
		title = r.name .. " (" .. follow.idx .. "/" .. #r.points .. ")",
		persistent = false, minimap = true, world = true, crazy = true, silent = true,
		cleardistance = 0, arrivaldistance = db.followDist,
	})
	if FRP.RedrawLines then FRP.RedrawLines() end -- move the target marker in the planner
end

function FRP.IsFollowing() return follow ~= nil end

-- The point TomTom is currently pointing at: mapID, x, y (or nil)
function FRP.GetFollowTarget()
	if not follow then return nil end
	local p = follow.route.points[follow.idx]
	if not p then return nil end
	return follow.route.mapID, p[1], p[2]
end

function FRP.StopFollow(quiet)
	followFrame:SetScript("OnUpdate", nil)
	if follow and follow.uid and TomTomOK() then TomTom:RemoveWaypoint(follow.uid) end
	follow = nil
	if not quiet then Print("Stopped following the route.") end
	if FRP.UpdateFollowButton then FRP.UpdateFollowButton() end
end

function FRP.StartFollow(route)
	if not TomTomOK() then Print("TomTom isn't loaded. Install/enable TomTom to use follow mode.") return end
	if not route or #route.points < 2 then Print("Draw or load a route with at least 2 points first.") return end
	local pos = C_Map.GetPlayerMapPosition(route.mapID, "player")
	if not pos then Print("Go to " .. MapName(route.mapID) .. " to follow this route.") return end
	local mw, mh = MapYards(route.mapID)
	if not mw then Print("Can't measure distances on this map.") return end
	if follow then FRP.StopFollow(true) end

	local copy = CopyRoute(route)
	if copy.name == "" then copy.name = "Route" end
	follow = { route = copy, idx = 1 }

	-- start at the closest point
	local px, py = pos:GetXY()
	local best, bestD = 1, math.huge
	for i = 1, #copy.points do
		local d = FollowDist(i, px, py, mw, mh)
		if d < bestD then best, bestD = i, d end
	end
	-- if a point is selected (green) in the planner, start there instead of the closest one
	if route.sel and route.sel >= 1 and route.sel <= #copy.points then best = route.sel end
	follow.idx = best
	SetFollowWaypoint()
	Print("Following '" .. copy.name .. "'. The arrow moves on when you are within " .. db.followDist .. " yards.")

	local elapsed = 0
	followFrame:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed < 0.2 then return end
		elapsed = 0
		local p = C_Map.GetPlayerMapPosition(follow.route.mapID, "player")
		if not p then return end -- left the zone; keep the waypoint and wait
		local x, y = p:GetXY()
		if FollowDist(follow.idx, x, y, mw, mh) > db.followDist then return end
		-- reached it: skip ahead past every point already within range
		local idx, guard = follow.idx, 0
		repeat
			idx = NextIndex(idx)
			guard = guard + 1
		until not idx or guard > #follow.route.points or FollowDist(idx, x, y, mw, mh) > db.followDist
		if not idx then
			Print("Reached the end of '" .. follow.route.name .. "'.")
			FRP.StopFollow(true)
			return
		end
		follow.idx = idx
		SetFollowWaypoint()
	end)
	if FRP.UpdateFollowButton then FRP.UpdateFollowButton() end
end

function FRP.CycleFollowDistance()
	local nextD = FOLLOW_DISTANCES[1]
	for i, d in ipairs(FOLLOW_DISTANCES) do
		if d == db.followDist then nextD = FOLLOW_DISTANCES[i % #FOLLOW_DISTANCES + 1] break end
	end
	db.followDist = nextD
	if follow then SetFollowWaypoint() end
	if FRP.UpdateFollowButton then FRP.UpdateFollowButton() end
end

---------------------------------------------------------------------------
-- Record a path while walking: adds a point every db.recordStep yards,
-- inserted after the selected point (so it can fill in the path between nodes).
---------------------------------------------------------------------------
local RECORD_STEPS = { 5, 10, 15, 20, 30, 50 }
local rec -- { route=, mapID=, lastX=, lastY=, added= }
local recFrame = CreateFrame("Frame")

function FRP.IsRecording() return rec ~= nil end

function FRP.StopRecord(reason)
	if not rec then return end
	recFrame:SetScript("OnUpdate", nil)
	local added = rec.added
	rec = nil
	Print("Stopped recording" .. (reason and (" (" .. reason .. ")") or "") .. ". Added " .. added ..
		" point(s). Click Save to keep the route.")
	if FRP.UpdateRecordButton then FRP.UpdateRecordButton() end
	if FRP.UpdateControls then FRP.UpdateControls() end
end

function FRP.StartRecord()
	if rec then return end
	local zone = PlayerZone()
	local pos = zone and C_Map.GetPlayerMapPosition(zone, "player")
	if not pos then Print("Can't read your position here, so recording isn't possible.") return end
	local mw, mh = MapYards(zone)
	if not mw then Print("Can't measure distances in this zone.") return end

	if not cur or cur.mapID ~= zone then
		if cur and cur.dirty and #cur.points > 0 then
			Print("Your open route has unsaved changes in another zone. Save it (or click New) first.")
			return
		end
		if win then FRP.SetZone(zone) else NewWorking(zone) end
	end
	if #cur.points == 0 then cur.closed = false end
	PushUndo()
	local x, y = pos:GetXY()
	rec = { route = cur, mapID = zone, lastX = x, lastY = y, added = 0 }
	AddAfterSelection(x, y)
	rec.added = 1
	Print("Recording in " .. MapName(zone) .. ": a point every " .. db.recordStep ..
		" yards. Click Stop Recording (or /frp record) when done.")
	if FRP.UpdateRecordButton then FRP.UpdateRecordButton() end

	local elapsed = 0
	recFrame:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed < 0.2 then return end
		elapsed = 0
		if cur ~= rec.route then FRP.StopRecord("another route was opened") return end
		local p = C_Map.GetPlayerMapPosition(rec.mapID, "player")
		if not p then FRP.StopRecord("you left " .. MapName(rec.mapID)) return end
		local px, py = p:GetXY()
		local dx, dy = (px - rec.lastX) * mw, (py - rec.lastY) * mh
		if dx * dx + dy * dy >= db.recordStep * db.recordStep then
			rec.lastX, rec.lastY = px, py
			AddAfterSelection(px, py)
			rec.added = rec.added + 1
		end
	end)
end

function FRP.ToggleRecord()
	if rec then FRP.StopRecord() else FRP.StartRecord() end
end

function FRP.CycleRecordStep()
	local nextS = RECORD_STEPS[1]
	for i, s in ipairs(RECORD_STEPS) do
		if s == db.recordStep then nextS = RECORD_STEPS[i % #RECORD_STEPS + 1] break end
	end
	db.recordStep = nextS
	if FRP.UpdateRecordButton then FRP.UpdateRecordButton() end
end

---------------------------------------------------------------------------
-- Minimap button
---------------------------------------------------------------------------
local function BuildMinimapButton()
	local b = CreateFrame("Button", "FarmRoutePlannerMinimapButton", Minimap)
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	local icon = b:CreateTexture(nil, "BACKGROUND")
	icon:SetTexture("Interface\\Icons\\INV_Misc_Map_01")
	icon:SetSize(20, 20); icon:SetPoint("CENTER", 0, 1)
	local border = b:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53); border:SetPoint("TOPLEFT")

	local function Place()
		local a = math.rad(db.buttonAngle or 200)
		local r = Minimap:GetWidth() / 2 + 10
		b:ClearAllPoints()
		b:SetPoint("CENTER", Minimap, "CENTER", cos(a) * r, sin(a) * r)
	end
	Place()
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetScript("OnClick", function(_, button)
		if button ~= "RightButton" then FRP.Toggle() return end
		-- right-click: start/stop TomTom following
		if FRP.IsFollowing() then FRP.StopFollow() return end
		local route = (cur and #cur.points >= 2) and cur or nil
		if not route then
			local zone = PlayerZone()
			for _, r in ipairs(db.routes) do
				if r.mapID == zone and r.visible ~= false then route = r break end
			end
		end
		if route then FRP.StartFollow(route) else Print("No route to follow here. Open or draw one in the planner first.") end
	end)
	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local s = Minimap:GetEffectiveScale()
			local cx, cy = GetCursorPosition()
			db.buttonAngle = math.deg(atan2(cy / s - my, cx / s - mx))
			Place()
		end)
	end)
	b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Farm Route Planner")
		GameTooltip:AddLine("Left-click: open the planner", 1, 1, 1)
		GameTooltip:AddLine("Right-click: " .. (FRP.IsFollowing() and "stop following (TomTom)" or "follow a route with TomTom"), 1, 1, 1)
		GameTooltip:AddLine("Drag: move this button", 1, 1, 1)
		if FRP.IsRecording() then GameTooltip:AddLine("Recording a path...", 1, 0.3, 0.3) end
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)
	b:SetShown(not db.hideButton)
	FRP.minimapButton = b
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------
local function Init()
	FarmRoutePlannerDB = FarmRoutePlannerDB or {}
	db = FarmRoutePlannerDB
	db.routes = db.routes or {}
	if db.minimap == nil then db.minimap = true end
	if db.showOthers == nil then db.showOthers = true end

	db.gm = db.gm or { ["Mining"] = true, ["Herb Gathering"] = true }
	db.followDist = db.followDist or 20
	db.recordStep = db.recordStep or 10
	if db.ring == nil then db.ring = true end
	-- default: 185 yards, the observed Find Minerals / Find Herbs range (existing installs switched over once)
	if db.ringYards == nil or not db.ringDefaultV3 then db.ringYards = 185; db.ringDefaultV3 = true end
	FRP.SyncGatherMateDistance()
	if db.gmEnabled == nil then db.gmEnabled = true end
	db.gmExclude = db.gmExclude or {}

	-- Parented to UIParent on purpose (see UpdateMinimap): FarmHud re-parents Minimap children.
	mmLayer = CreateFrame("Frame", "FarmRoutePlannerMinimapLayer", UIParent)
	mmLayer:SetAllPoints(Minimap)
	mmLayer.anchoredTo = Minimap
	mmLayer:SetFrameStrata(Minimap:GetFrameStrata())
	mmLayer:SetFrameLevel(Minimap:GetFrameLevel() + 1)
	-- the update loop runs on its own always-shown frame, so hiding the layer can't stop it
	local driver = CreateFrame("Frame")
	local elapsed = 0
	driver:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed > 0.05 then
			elapsed = 0
			local ok, err = pcall(UpdateMinimap)
			if not ok and not FRP.reportedMinimapError then
				-- Lua errors may be hidden in-game; report the first one so it can be fixed
				FRP.reportedMinimapError = true
				Print("|cffff6060Minimap drawing error:|r " .. tostring(err))
			end
		end
	end)
	UpdateIndoors()
	BuildMinimapButton()
	if db.worldmap == nil then db.worldmap = true end
	SetupWorldMap()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("MINIMAP_UPDATE_ZOOM")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:RegisterEvent("ZONE_CHANGED_INDOORS")
ev:SetScript("OnEvent", function(_, event, arg)
	if event == "ADDON_LOADED" then
		if arg == ADDON then Init()
		elseif arg == "Blizzard_WorldMap" and db then SetupWorldMap() end
	elseif db then
		UpdateIndoors()
	end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_FARMROUTEPLANNER1, SLASH_FARMROUTEPLANNER2 = "/frp", "/farmroute"
SlashCmdList.FARMROUTEPLANNER = function(msg)
	local cmd = (msg or ""):lower():match("^(%S*)")
	if cmd == "minimap" then
		db.minimap = not db.minimap
		Print("Routes on minimap: " .. (db.minimap and "on" or "off"))
	elseif cmd == "button" then
		db.hideButton = not db.hideButton
		FRP.minimapButton:SetShown(not db.hideButton)
	elseif cmd == "exportall" then
		if #db.routes == 0 then Print("No saved routes.") return end
		ShowDialog("All saved routes - copy with Ctrl+C", FRP.Export(db.routes))
	elseif cmd == "follow" then
		local name = Clean(msg:sub(7)):lower()
		local zone = PlayerZone()
		local pick
		for _, r in ipairs(db.routes) do
			if r.mapID == zone and (name == "" or r.name:lower() == name) then pick = r break end
		end
		if pick then FRP.StartFollow(pick) else Print("No saved route " .. (name ~= "" and ("named '" .. name .. "' ") or "") .. "in this zone.") end
	elseif cmd == "stop" then
		FRP.StopFollow()
	elseif cmd == "record" then
		FRP.ToggleRecord()
	elseif cmd == "ring" then
		local yards = tonumber(msg:match("%d+"))
		if yards and yards > 0 then
			db.ringYards, db.ring = yards, true
			FRP.SyncGatherMateDistance()
			Print("Range ring: " .. yards .. " yards (also set as GatherMate2's tracking distance).")
		else
			db.ring = not db.ring
			Print("Range ring: " .. (db.ring and "on" or "off"))
		end
	elseif cmd == "dist" then
		local d = tonumber(msg:match("%d+"))
		if d and d > 0 then
			db.followDist = d
			if FRP.UpdateFollowButton then FRP.UpdateFollowButton() end
			Print("Arrow moves on at " .. d .. " yards.")
		else
			Print("Usage: /frp dist 25")
		end
	elseif cmd == "debug" then
		local zone = PlayerZone()
		local pos = zone and C_Map.GetPlayerMapPosition(zone, "player")
		local w, h
		if zone then w, h = MapYards(zone) end
		Print("zone=" .. tostring(zone) .. " (" .. MapName(zone) .. ") pos=" ..
			(pos and string.format("%.3f, %.3f", pos:GetXY()) or "nil") ..
			" size=" .. tostring(w) .. "x" .. tostring(h) .. " minimapZoom=" .. Minimap:GetZoom() ..
			" " .. indoors .. " dots=" .. #mmUsed .. " minimapOn=" .. tostring(db.minimap))
		local shown = 0
		for _, r in ipairs(db.routes) do
			if r.mapID == zone then shown = shown + 1 end
		end
		Print(shown .. " saved route(s) in this zone. GatherMate2 " .. (GetGatherMate() and "found" or "not found") .. ".")
		local pins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)
		local mmf = (pins and pins.Minimap) or Minimap
		Print("Minimap drawing on: " .. (mmf:GetName() or "unnamed frame") .. " (" .. floor(mmf:GetWidth()) .. "px wide, visible " ..
			tostring(mmf:IsVisible()) .. "), HereBeDragons " ..
			((LibStub and LibStub("HereBeDragons-2.0", true)) and "found" or "not found") .. ".")
		if mmLayer then
			local _, rel = mmLayer:GetPoint(1)
			local parent = mmLayer:GetParent()
			Print("Route layer: shown " .. tostring(mmLayer:IsShown()) .. ", visible " .. tostring(mmLayer:IsVisible()) ..
				", parent " .. ((parent and parent:GetName()) or "?") ..
				", anchored to " .. ((rel and rel.GetName and rel:GetName()) or "?") ..
				", scale " .. string.format("%.2f", mmLayer:GetScale()) ..
				", lines " .. #mmLinesUsed .. ", arrows " .. #mmUsed ..
				", strata " .. mmLayer:GetFrameStrata() .. "/" .. mmLayer:GetFrameLevel())
		end
		if wmLayer then
			local maxLevel = 0
			for _, child in ipairs({ wmCanvas:GetChildren() }) do maxLevel = max(maxLevel, child:GetFrameLevel()) end
			Print("World map: layer level " .. wmLayer:GetFrameLevel() .. " (highest map child " .. maxLevel .. "), lines drawn " ..
				#wmUsed .. ", map shown " .. tostring(WorldMapFrame:IsShown()) .. ", map " .. tostring(WorldMapFrame:GetMapID()) ..
				", option " .. tostring(db.worldmap))
		else
			Print("World map layer was not created (WorldMapFrame " .. (WorldMapFrame and "exists" or "missing") ..
				", CreateLine " .. (UIParent.CreateLine and "yes" or "no") .. ").")
		end
	elseif cmd == "help" then
		Print("/frp - open the planner | /frp minimap - toggle minimap routes | /frp button - toggle minimap button | /frp exportall - export every saved route")
	else
		FRP.Toggle()
	end
end
