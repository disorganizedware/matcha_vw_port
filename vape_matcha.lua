-- Vape (BedWars) port for the Matcha LuaVM. Core: services, entities, inventory, remotes, module registry.
-- Modules live in the mods_*.lua sections and register with V.module{...}. Stop: _G.VapeStop()
if _G.VapeStop then pcall(_G.VapeStop) end

local V = { mods = {}, cats = {}, drawings = {}, conns = {}, running = true, entities = {} }
_G.Vape = V

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
V.Players, V.RS, V.RunService, V.HttpService = Players, RS, RunService, HttpService
V.lp = Players.LocalPlayer
local lp = V.lp

V.CATEGORIES = { "Combat", "Blatant", "Render", "Utility", "World", "Inventory", "Minigames", "Legit" }

-- ===== small utils =====
function V.notify(msg, title, dur) notify(tostring(msg), title or "Vape", dur or 3) end
function V.cam() return workspace.CurrentCamera end
function V.flat(v) return Vector3.new(v.X, 0, v.Z) end
function V.roundPos(v) return Vector3.new(math.round(v.X / 3) * 3, math.round(v.Y / 3) * 3, math.round(v.Z / 3) * 3) end
-- Matcha resumes threads and fires signal callbacks from C++: an uncaught Lua error there aborts app.exe
-- (0xc0000409 in ucrtbase). Every thread and callback in Vape goes through these two, which never let one escape.
local function report(err) warn("[Vape] " .. tostring(err)) end
function V.spawn(fn, ...)
	local args = { ... }
	task.spawn(function()
		local ok, err = pcall(fn, unpack(args))
		if not ok then report(err) end
	end)
end
function V.connect(signal, fn)
	local c = signal:Connect(function(...)
		local ok, err = pcall(fn, ...)
		if not ok then report(err) end
	end)
	V.conns[#V.conns + 1] = c
	return c
end

-- Drawing that is tracked for cleanup and starts hidden (fresh Drawings flash at 0,0)
function V.draw(class, props)
	local d = Drawing.new(class)
	d.Visible = false
	for k, v in pairs(props or {}) do d[k] = v end
	V.drawings[d] = true
	return d
end
function V.undraw(d) if d and V.drawings[d] then V.drawings[d] = nil; pcall(function() d:Remove() end) end end

-- ===== remotes =====
local function child(root, ...)
	for _, n in ipairs({ ... }) do root = root and root:FindFirstChild(n) end
	return root
end
V.net = child(RS, "rbxts_include", "node_modules", "@rbxts", "net", "out", "_NetManaged")
V.blockNet = child(RS, "rbxts_include", "node_modules", "@easy-games", "block-engine", "node_modules", "@rbxts", "net", "out", "_NetManaged")
local remoteCache = {}
function V.remote(name)
	local r = remoteCache[name]
	if r and r.Parent then return r end
	r = (V.net and V.net:FindFirstChild(name)) or (V.blockNet and V.blockNet:FindFirstChild(name)) or RS:FindFirstChild(name, true)
	remoteCache[name] = r
	return r
end
-- Fires a RemoteEvent or invokes a RemoteFunction. Returns ok, result. Never throws.
function V.call(name, ...)
	local r = V.remote(name)
	if not r then return false, "no remote " .. name end
	local args = { ... }
	return pcall(function()
		if r.ClassName == "RemoteFunction" then return r:InvokeServer(unpack(args)) end
		r:FireServer(unpack(args))
		return true
	end)
end
-- Same as V.call but on its own thread (InvokeServer yields)
function V.callAsync(name, ...)
	V.spawn(V.call, name, ...)
end

-- ===== UI value access (UI.GetValue is nil until the tab drew once) =====
-- Values are cached and the cache is dropped every scheduler tick (~13/s), so render code can read options
-- every frame without a Matcha UI call each time.
local NIL = {}
local vals = {}
function V.get(id, default)
	local v = vals[id]
	if v == nil then
		v = UI.GetValue(id)
		if v == nil then v = V.cfgVal[id] end -- loaded config value for a widget not drawn yet
		if v == nil then v = NIL end
		vals[id] = v
	end
	if v == NIL then return default end
	return v
end
function V.set(id, v) UI.SetValue(id, v); vals[id] = nil end

-- ===== local character =====
function V.char() return lp.Character end
function V.root() local c = lp.Character; return c and c:FindFirstChild("HumanoidRootPart") end
function V.hum() local c = lp.Character; return c and c:FindFirstChildOfClass("Humanoid") end
function V.alive()
	local c = lp.Character
	if not (c and c:FindFirstChild("HumanoidRootPart")) then return false end
	local h = c:FindFirstChildOfClass("Humanoid")
	return h ~= nil and (c:GetAttribute("Health") or h.Health or 1) > 0
end
function V.team(plr) return plr and plr:GetAttribute("Team") end
function V.inMatch() return game.PlaceId ~= 6872265039 end

-- ===== friends / targets (from the Vape settings tab, comma separated names) =====
local setCache = {}
local function nameSet(str)
	str = tostring(str or "")
	local s = setCache[str]
	if s then return s end
	s = {}
	for n in str:gmatch("[^,%s]+") do s[n:lower()] = true end
	setCache[str] = s
	return s
end
function V.isFriend(plr) return plr and V.get("vape_friends_on", true) and nameSet(V.get("vape_friends", ""))[plr.Name:lower()] or false end
function V.isTarget(plr) return plr and nameSet(V.get("vape_targets", ""))[plr.Name:lower()] or false end

-- ===== entities =====
-- V.entities: { Player?, Character, RootPart, Head, Humanoid, Health, MaxHealth, NPC, Targetable, Friend, Target, Id }
-- refreshed every 0.25s; Health uses BedWars' Health attribute + shield attributes.
-- shield attribute names per character, re-listed every 5s (GetAttributes is slow; Matcha returns names)
local shieldNames = {}
local function shield(char)
	local c = shieldNames[char.Address]
	if not c or tick() - c.t > 5 then
		c = { t = tick() }
		for _, n in ipairs(char:GetAttributes() or {}) do
			if tostring(n):find("Shield") then c[#c + 1] = n end
		end
		shieldNames[char.Address] = c
	end
	local s = 0
	for _, n in ipairs(c) do
		local v = char:GetAttribute(n)
		if type(v) == "number" and v > 0 then s = s + v end
	end
	return s
end
local function makeEntity(char, plr)
	local root = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
	if not root then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hp = (char:GetAttribute("Health") or (hum and hum.Health) or 100)
	if hp <= 0 then return end
	local e = {
		Player = plr, Character = char, RootPart = root, HumanoidRootPart = root,
		Head = char:FindFirstChild("Head") or root, Humanoid = hum,
		Health = hp + shield(char), MaxHealth = char:GetAttribute("MaxHealth") or (hum and hum.MaxHealth) or 100,
		NPC = plr == nil, Id = char.Address,
	}
	if plr then
		e.Friend = V.isFriend(plr)
		e.Target = V.isTarget(plr)
		e.Targetable = not e.Friend and (V.team(plr) == nil or V.team(plr) ~= V.team(lp))
	else
		local t = char:GetAttribute("Team")
		e.Targetable = t == nil or t ~= V.team(lp)
	end
	return e
end
-- NPC models are re-found every 2s; between scans only their health/position are refreshed
local npcModels, npcScan = {}, 0
function V.refreshEntities()
	local list, pchars = {}, {}
	for _, plr in ipairs(Players:GetPlayers()) do
		local c = plr.Character
		if c then pchars[c.Address] = true end
		if plr ~= lp and c then
			local e = makeEntity(c, plr)
			if e then list[#list + 1] = e end
		end
	end
	-- NPCs (dummies, monsters, drones): top-level workspace models with a Humanoid that aren't player characters
	if tick() - npcScan > 2 then
		npcScan, npcModels = tick(), {}
		for _, m in ipairs(workspace:GetChildren()) do
			if m.ClassName == "Model" and not pchars[m.Address] and not m.Name:find("PreviewClone") and m:FindFirstChildOfClass("Humanoid") then
				npcModels[#npcModels + 1] = m
			end
		end
	end
	for _, m in ipairs(npcModels) do
		if m.Parent and not pchars[m.Address] then
			local e = makeEntity(m, nil)
			if e then list[#list + 1] = e end
		end
	end
	V.entities = list
end

-- nearest targetable entity. opts: {range=, players=true, npcs=true, wallcheck=false, part="RootPart", sort="Distance"|"Health"|"Angle", limit=n, maxAngle=deg}
-- returns the best entity (or a list when opts.limit is set)
function V.targets(opts)
	opts = opts or {}
	local root = V.root()
	if not root then return opts.limit and {} or nil end
	local me, range = root.Position, opts.range or 18
	local look = V.flat(V.cam().CFrame.LookVector).Unit
	local out = {}
	for _, e in ipairs(V.entities) do
		if e.Targetable and ((e.NPC and opts.npcs ~= false) or (not e.NPC and opts.players ~= false)) and e.RootPart.Parent then
			local p = e[opts.part or "RootPart"].Position
			local d = (p - me).Magnitude
			if d <= range then
				local ok = true
				if opts.maxAngle and opts.maxAngle < 360 then
					local dir = V.flat(p - me)
					if dir.Magnitude > 0 then ok = math.deg(math.acos(math.clamp(look:Dot(dir.Unit), -1, 1))) <= opts.maxAngle / 2 end
				end
				if ok and opts.wallcheck then
					local hit = workspace:Raycast(me, (p - me))
					if hit and hit.Instance and not hit.Instance:IsDescendantOf(e.Character) then ok = false end
				end
				if ok then e.Distance = d; out[#out + 1] = e end
			end
		end
	end
	local sort = opts.sort or "Distance"
	table.sort(out, function(a, b)
		if a.Target ~= b.Target then return a.Target and true or false end
		if sort == "Health" then return a.Health < b.Health end
		if sort == "Angle" then
			local fa = look:Dot(V.flat(a.RootPart.Position - me).Unit)
			local fb = look:Dot(V.flat(b.RootPart.Position - me).Unit)
			return fa > fb
		end
		return a.Distance < b.Distance
	end)
	if opts.limit then
		local r = {}
		for i = 1, math.min(opts.limit, #out) do r[i] = out[i] end
		return r
	end
	return out[1]
end
-- entity nearest to the mouse cursor in screen space (for aim modules)
function V.targetMouse(fovPx, opts)
	opts = opts or {}
	local mouse = lp:GetMouse()
	local best, bestD = nil, fovPx or 200
	for _, e in ipairs(V.entities) do
		if e.Targetable and e.RootPart.Parent then
			local pos, on = WorldToScreen(e[opts.part or "RootPart"].Position)
			if on then
				local d = (Vector2.new(pos.X, pos.Y) - Vector2.new(mouse.X, mouse.Y)).Magnitude
				if d < bestD then best, bestD = e, d end
			end
		end
	end
	return best
end

-- ===== inventory =====
-- items live in ReplicatedStorage.Inventories.<name> (Character.InventoryFolder.Value), one Tool per item type with an Amount attribute
function V.invFolder(plr)
	plr = plr or lp
	local c = plr.Character
	local f = c and c:FindFirstChild("InventoryFolder")
	return (f and f.Value) or child(RS, "Inventories", plr.Name)
end
function V.items(plr)
	local f, out = V.invFolder(plr), {}
	if not f then return out end
	for _, t in ipairs(f:GetChildren()) do
		out[#out + 1] = { itemType = t.Name, tool = t, amount = t:GetAttribute("Amount") or 1 }
	end
	return out
end
function V.getItem(pattern, exact)
	for _, it in ipairs(V.items()) do
		if (exact and it.itemType == pattern) or (not exact and it.itemType:find(pattern)) then return it end
	end
end
function V.hand()
	local c = lp.Character
	local h = c and c:FindFirstChild("HandInvItem")
	return h and h.Value
end
function V.handName() local h = V.hand(); return h and h.Name or "" end

-- sword ranking by name (ItemMeta is unreachable without require)
V.SWORD_ORDER = { "wood_sword", "stone_sword", "iron_sword", "diamond_sword", "emerald_sword", "rageblade", "void_sword" }
V.PICK_ORDER = { "wood_pickaxe", "stone_pickaxe", "iron_pickaxe", "diamond_pickaxe" }
V.AXE_ORDER = { "wood_axe", "stone_axe", "iron_axe", "diamond_axe" }
local function best(order, fallbackPattern)
	local have, bestIt, bestRank = {}, nil, 0
	for _, it in ipairs(V.items()) do have[it.itemType] = it end
	for i, n in ipairs(order) do if have[n] then bestIt, bestRank = have[n], i end end
	if not bestIt and fallbackPattern then
		for n, it in pairs(have) do if n:find(fallbackPattern) then return it end end
	end
	return bestIt
end
function V.getSword() return best(V.SWORD_ORDER, "sword") or best({}, "blade") or best({}, "scythe") or best({}, "dao") or best({}, "summoner_claw") end
function V.getPickaxe() return best(V.PICK_ORDER, "pickaxe") end
function V.getAxe() return best(V.AXE_ORDER, "axe") end
function V.getWool()
	for _, it in ipairs(V.items()) do
		if it.itemType:find("wool") or it.itemType:find("_block") or it.itemType:find("planks") or it.itemType == "stone_brick" then return it end
	end
end
function V.getBow()
	return best({ "wood_bow", "wood_crossbow", "tactical_crossbow" }, "bow")
end

-- server-side equip (SetInvItem). The game's own UI follows HandInvItem.
function V.equip(item)
	local tool = type(item) == "table" and item.tool or item
	if not tool or V.hand() == tool then return true end
	local ok, res = V.call("SetInvItem", { hand = tool })
	return ok and res ~= false
end

-- ===== blocks =====
-- In a match placed blocks are Parts on a 3-stud grid under workspace.Map (path varies, located lazily).
-- ponytail: grid index rebuilt every 2s by V.indexBlocks; blocks placed in between are missed until then.
V.blockGrid = {}
function V.blockFolder()
	local m = workspace:FindFirstChild("Map")
	if not m then return nil end
	if V._blockFolder and V._blockFolder.Parent then return V._blockFolder end
	local worlds = m:FindFirstChild("Worlds")
	local f = worlds and worlds:GetChildren()[1]
	f = (f and f:FindFirstChild("Blocks")) or m:FindFirstChild("Blocks", true) or m
	V._blockFolder = f
	return f
end
local function key(v) return math.round(v.X / 3) .. "," .. math.round(v.Y / 3) .. "," .. math.round(v.Z / 3) end
-- V.blockGrid is only ever replaced, never edited, because other threads may be mid-`pairs` over it (editing it
-- raised "invalid key to 'next'"). Blocks placed/broken since the last index live in these overlays instead.
local placed, broken = {}, {}
-- blocks never move, so a block's grid key is read once per instance (by Address); rescans only read new blocks
local keyByAddr = {}
function V.indexBlocks()
	local f = V.blockFolder()
	local g, seen = {}, {}
	if f then
		for _, b in ipairs(f:GetChildren()) do
			local a = b.Address
			local k = keyByAddr[a]
			if k == nil then
				local p
				local cls = b.ClassName
				if cls == "Part" or cls == "MeshPart" or cls == "UnionOperation" then
					p = b.Position
				elseif cls == "Model" then -- beds and other multi-part blocks
					local pp = b.PrimaryPart
					p = pp and pp.Position
				end
				k = p and key(p) or false
				keyByAddr[a] = k
			end
			if k then g[k] = b end
			seen[a] = k
		end
	end
	keyByAddr = seen
	placed, broken = {}, {}
	V.blockGrid = g
end
function V.needBlocks() return tick() - V._blockUse < 10 or next(V.blockGrid) == nil end
-- block lookups mark the grid as in use; the scheduler only re-indexes the map while that's recent
V._blockUse = 0
function V.grid() V._blockUse = tick(); return V.blockGrid end
function V.blockAt(pos)
	V._blockUse = tick()
	local k = key(pos)
	if broken[k] then return nil end
	return placed[k] or V.blockGrid[k]
end
function V.blockPos(pos) return Vector3.new(math.round(pos.X / 3), math.round(pos.Y / 3), math.round(pos.Z / 3)) end -- block-engine grid coords
function V.markPlaced(worldPos, part) local k = key(worldPos); broken[k] = nil; placed[k] = part or true end

-- place a block at a world position (snapped to grid) with held/any wool
function V.placeBlock(worldPos, blockType)
	blockType = blockType or (V.getWool() or {}).itemType
	if not blockType then return false end
	local bp = V.blockPos(worldPos)
	local ok = V.call("PlaceBlock", { blockType = blockType, blockData = 0, position = bp })
	if ok then V.markPlaced(bp * 3) end
	return ok
end
-- damage a block at world position. DamageBlock (RemoteFunction) returns true for any accepted hit (verified in the
-- training arena), so a broken block is detected by its instance losing its Parent.
function V.hitBlock(worldPos, normal)
	if not V.root() then return false end
	local bp = V.blockPos(worldPos)
	local k = key(worldPos)
	local ok, res = V.call("DamageBlock", {
		blockRef = { blockPosition = bp },
		hitPosition = bp * 3,
		hitNormal = normal or Vector3.new(1, 0, 0),
	})
	local b = placed[k] or V.blockGrid[k]
	if b and (b == true or not b.Parent) then broken[k] = true; placed[k] = nil end
	return ok, res
end

-- ===== memory (Humanoid walkspeed etc.) =====
-- offsets.imtheo.lol matches live builds; refuses to write when the build differs.
function V.offsets()
	if V._off ~= nil then return V._off or nil end
	V._off = false
	local ok, body = pcall(httpget, "https://offsets.imtheo.lol/offsets.json")
	if ok and body ~= "" then
		local ok2, j = pcall(function() return HttpService:JSONDecode(body) end)
		if ok2 and j and j["Roblox Version"] == getrbxversion() then V._off = j.Offsets end
	end
	return V._off or nil
end
function V.setWalkSpeed(ws)
	local h, o = V.hum(), V.offsets()
	if not (h and o and o.Humanoid) then return false end
	local a = h.Address
	memory_write("float", a + o.Humanoid.Walkspeed, ws)
	if o.Humanoid.WalkspeedCheck then memory_write("float", a + o.Humanoid.WalkspeedCheck, ws) end
	return true
end
function V.getWalkSpeed()
	local h, o = V.hum(), V.offsets()
	if not (h and o and o.Humanoid) then return 16 end
	return memory_read("float", h.Address + o.Humanoid.Walkspeed)
end

-- ===== movement helpers =====
-- move direction from WASD relative to camera (Humanoid.MoveDirection isn't bound)
function V.moveDir()
	local cf = V.cam().CFrame
	local f, r = V.flat(cf.LookVector), V.flat(cf.RightVector)
	f = f.Magnitude > 0 and f.Unit or f
	r = r.Magnitude > 0 and r.Unit or r
	local d = Vector3.zero
	if iskeypressed(0x57) then d = d + f end
	if iskeypressed(0x53) then d = d - f end
	if iskeypressed(0x44) then d = d + r end
	if iskeypressed(0x41) then d = d - r end
	return d.Magnitude > 0 and d.Unit or d
end
function V.typing() return not isrbxactive() end

-- ===== module registry =====
-- V.module{
--   name, cat (one of V.CATEGORIES), key (VK, 0 = none), tip,
--   ui(sec, m)           -- add options; use m.id("opt") for ids and m.opt("opt", default) to read
--   enable(m), disable(m) -- on toggle transitions
--   render(m, dt)        -- RenderStepped while enabled (Drawings, per-frame memory writes)
--   step(m)              -- ~13/s (Matcha wait granularity) on a task.spawn thread while enabled (may yield / call remotes)
-- }
local function slug(s) return (s:lower():gsub("[^%w]", "")) end
function V.module(def)
	local m = def
	m.slug = slug(m.name)
	m.id = function(opt) return "vape_" .. m.slug .. "_" .. slug(opt) end
	m.opt = function(opt, default) return V.get(m.id(opt), default) end
	m.enabled = false
	m.errors = 0
	V.mods[#V.mods + 1] = m
	V.cats[m.cat] = V.cats[m.cat] or {}
	table.insert(V.cats[m.cat], m)
	return m
end
local function safe(m, fn, ...)
	if not fn then return end
	local ok, err = pcall(fn, m, ...)
	if not ok then
		m.errors = m.errors + 1
		if m.errors <= 3 then warn("[Vape] " .. m.name .. ": " .. tostring(err)) end
	end
end
V.safe = safe
function V.isOn(m)
	if type(m) == "string" then
		for _, x in ipairs(V.mods) do if x.name == m then m = x break end end
		if type(m) == "string" then return false end
	end
	return m.enabled
end

-- ===== configs =====
-- Saved as JSON in the Matcha workspace: vape/configs/<name>.json = { values = {id = value}, keys = {id = {key, type}} }.
-- Matcha widgets only exist once their tab has been drawn, so a loaded value is kept in V.cfgVal (V.get falls back
-- to it) and pushed into the widget the first time it's drawn (see V.wrapSec).
-- ponytail: a module's keybind from a config takes effect once its tab has been opened, since the keybind widget
-- (m.kbw) only exists after that.
local CFG_DIR = "vape/configs/"
V.cfgVal, V.cfgRaw, V.cfgKeys = {}, {}, {}
V.widgets, V.kbs = {}, {}
local pendingVal, pendingKey = {}, {}

local function enc(v)
	local t = typeof(v)
	if t == "Color3" then return { __c = { v.R, v.G, v.B } } end
	if t == "EnumItem" then return { __e = tostring(v) } end
	if t == "table" then
		local o = {}
		for k, x in pairs(v) do o[k] = enc(x) end
		return o
	end
	if t == "number" or t == "boolean" or t == "string" then return v end
	return nil
end
local function dec(v)
	if type(v) ~= "table" then return v end
	if v.__c then
		local r, g, b = v.__c[1], v.__c[2], v.__c[3]
		if r > 1 or g > 1 or b > 1 then return Color3.fromRGB(r, g, b) end
		return Color3.new(r, g, b)
	end
	if v.__e then
		local name = tostring(v.__e):match("Enum%.KeyCode%.(.+)")
		local ok, e = pcall(function() return Enum.KeyCode[name] end)
		return ok and e or 0
	end
	local o = {}
	for k, x in pairs(v) do o[k] = dec(x) end
	return o
end
local function applyKey(w, kv)
	if kv.key ~= nil then pcall(w.SetKey, w, dec(kv.key)) end
	if kv.type then pcall(w.SetType, w, kv.type) end
end
local function saved(id) return type(id) == "string" and id:sub(1, 9) ~= "vape_cfg_" end

-- called for every id widget as it's drawn: records it and applies any pending loaded value
function V.onWidget(kind, id, w, ...)
	if not saved(id) then return end
	V.widgets[id] = kind
	if kind == "Keybind" then
		V.kbs[id] = w
		local kv = pendingKey[id]
		if kv and w then applyKey(w, kv); pendingKey[id] = nil end
	end
	if pendingVal[id] ~= nil then
		pcall(UI.SetValue, id, pendingVal[id])
		pendingVal[id] = nil
		vals[id] = nil
	end
	if kind == "ColorPicker2" then
		local id2 = select(2, ...)
		if id2 then V.onWidget("ColorPicker", id2, nil) end
	end
end

-- section proxy that reports id widgets to V.onWidget; non-function fields (sec.page) pass through
local ID_WIDGETS = { Toggle = true, Keybind = true, SliderInt = true, SliderFloat = true, Combo = true, ColorPicker = true, ColorPicker2 = true, InputText = true }
local wrappers = {}
local secMeta = { __index = function(p, k)
	local real = rawget(p, "__sec")
	local v = real[k]
	if type(v) ~= "function" then return v end
	local w = wrappers[k]
	if not w then
		if ID_WIDGETS[k] then
			w = function(self, id, ...)
				local s = rawget(self, "__sec")
				local r = s[k](s, id, ...)
				V.onWidget(k, id, r, ...)
				return r
			end
		else
			w = function(self, ...) local s = rawget(self, "__sec"); return s[k](s, ...) end
		end
		wrappers[k] = w
	end
	return w
end }
function V.wrapSec(sec) return setmetatable({ __sec = sec }, secMeta) end

-- every option id, found by dry-running each module's ui() against a recording section at boot
-- (UI.GetValue/SetValue work on ids whose tab was never opened, so configs cover all of them)
V.allIds = {}
local function registerIds()
	local stubW = setmetatable({ value = false }, { __index = function() return function() return 0 end end })
	local rec = setmetatable({ page = 0 }, { __index = function(_, k)
		return function(_, id, ...)
			if ID_WIDGETS[k] and saved(id) then
				V.allIds[id] = k
				if k == "ColorPicker2" then local id2 = select(2, ...); if saved(id2) then V.allIds[id2] = "ColorPicker" end end
			end
			return stubW
		end
	end })
	for _, m in ipairs(V.mods) do
		V.allIds[m.id("on")] = "Toggle"
		if m.ui then pcall(m.ui, m, rec) end
	end
	for _, id in ipairs({ "vape_friends_on", "vape_friends", "vape_targets" }) do V.allIds[id] = "Toggle" end
end

function V.cfgList()
	local out = {}
	if isfolder(CFG_DIR) then
		for _, p in ipairs(listfiles(CFG_DIR)) do
			local n = tostring(p):match("([^/\\]+)%.json$")
			if n then out[#out + 1] = n end
		end
	end
	return out
end

function V.saveConfig(name)
	name = tostring(name or ""):gsub("[^%w_%- ]", "")
	if name == "" then return false end
	local out = { values = {}, keys = {} }
	for id, raw in pairs(V.cfgRaw) do out.values[id] = raw end
	for id, kind in pairs(V.allIds) do
		if kind ~= "Keybind" then
			local v = enc(UI.GetValue(id))
			if v ~= nil then out.values[id] = v end
		end
	end
	for id, kv in pairs(V.cfgKeys) do out.keys[id] = kv end
	for id, w in pairs(V.kbs) do
		local ok, k = pcall(w.GetKey, w)
		local ok2, t = pcall(w.GetType, w)
		out.keys[id] = { key = ok and enc(k) or 0, type = ok2 and t or "toggle" }
	end
	local ok = pcall(writefile, CFG_DIR .. name .. ".json", HttpService:JSONEncode(out))
	return ok
end

function V.loadConfig(name)
	local path = CFG_DIR .. tostring(name) .. ".json"
	if not isfile(path) then return false end
	local ok, data = pcall(function() return HttpService:JSONDecode(readfile(path)) end)
	if not ok or type(data) ~= "table" then return false end
	V.cfgVal, V.cfgRaw, V.cfgKeys = {}, {}, data.keys or {}
	pendingVal, pendingKey = {}, {}
	for id, raw in pairs(data.values or {}) do
		if saved(id) then
			local v = dec(raw)
			V.cfgRaw[id], V.cfgVal[id] = raw, v
			pcall(UI.SetValue, id, v)
			if not V.widgets[id] then pendingVal[id] = v end -- re-applied when its tab first draws
		end
	end
	for id, kv in pairs(V.cfgKeys) do
		local w = V.kbs[id]
		if w then applyKey(w, kv) else pendingKey[id] = kv end
	end
	vals = {}
	return true
end

function V.deleteConfig(name)
	return pcall(delfile, CFG_DIR .. tostring(name) .. ".json")
end

-- set-and-forget modules: toggle only, no keybind widget
V.NOBIND = {}
for _, n in ipairs({
	"NoClickDelay", "Sprint", "NoSlowdown", "AntiVoid", "NoFall", "PickupRange", "Kit Speed Fix",
	"ArmorSwitch", "AutoBank", "AutoBuy", "AutoConsume", "AutoHotbar", "FastConsume", "FastDrop",
	"Crosshair", "Damage Indicator", "FOV", "Hit Color", "Kill Effect", "Reach Display", "Viewmodel",
	"BedPlates", "BedESP", "Health", "KitESP", "NameTags", "StorageESP",
	"AutoBalloon", "AutoKit", "AutoPearl", "AutoShoot", "AutoToxic", "AutoVoidDrop", "StaffDetector",
	"Anti-AFK", "AutoSuffocate", "AutoTool", "AutoWhisper", "ChestSteal",
}) do V.NOBIND[n] = true end

-- ===== boot (called at the end of the concatenated file) =====
function V.boot()
	registerIds()
	for _, cat in ipairs(V.CATEGORIES) do
		local list = V.cats[cat]
		if list then
			UI.AddTab("Vape " .. cat, function(tab)
				for i, m in ipairs(list) do
					local sec = V.wrapSec(tab:Section(m.name, i % 2 == 1 and "Left" or "Right"))
					sec:Toggle(m.id("on"), "Enabled", false)
					if not V.NOBIND[m.name] then m.kbw = sec:Keybind(m.id("kb"), m.key or 0, "toggle") end
					if m.tip then sec:Tip(m.tip) end
					if m.ui then safe(m, m.ui, sec) end
				end
			end)
		end
	end
	local cfgNames, cfgCombo = V.cfgList(), nil
	local function refreshList()
		cfgNames = V.cfgList()
		if cfgCombo then
			pcall(function()
				cfgCombo:Clear()
				for _, n in ipairs(cfgNames) do cfgCombo:Add(n) end
			end)
		end
	end
	local function selected()
		local ok, t = pcall(function() return cfgCombo and cfgCombo:GetText() end)
		if ok and t and t ~= "" then return t end
		return cfgNames[1]
	end
	UI.AddTab("Vape", function(tab)
		local s = V.wrapSec(tab:Section("Friends & Targets", "Left"))
		s:Toggle("vape_friends_on", "Use friends", true)
		s:InputText("vape_friends", "Friends (comma list)", "")
		s:InputText("vape_targets", "Priority targets", "")
		local c = tab:Section("Config", "Right")
		c:InputText("vape_cfg_name", "Config name", "default")
		c:Button("Save", function()
			local name = V.get("vape_cfg_name", "default")
			if V.saveConfig(name) then refreshList(); V.notify("Saved config " .. name) else V.notify("Couldn't save " .. tostring(name)) end
		end)
		cfgCombo = c:Combo("vape_cfg_list", "Saved configs", cfgNames, 0)
		c:Button("Load", function()
			local name = selected()
			if name and V.loadConfig(name) then V.notify("Loaded config " .. name) else V.notify("No config to load") end
		end)
		c:Button("Delete", function()
			local name = selected()
			if name then V.deleteConfig(name); refreshList(); V.notify("Deleted config " .. name) end
		end)
		c:Button("Set autoload", function()
			local name = selected()
			if name then pcall(writefile, "vape/autoload.txt", name); V.notify("Autoload: " .. name) end
		end)
		c:Button("Clear autoload", function() pcall(delfile, "vape/autoload.txt"); V.notify("Autoload cleared") end)
		c:Button("Refresh list", refreshList)
		local s2 = tab:Section("Session", "Right")
		s2:Text("Vape for Matcha")
		s2:Button("Uninject", function() V.spawn(_G.VapeStop) end)
	end)
	if isfile("vape/autoload.txt") then
		local name = readfile("vape/autoload.txt")
		if V.loadConfig(name) then V.notify("Loaded config " .. name, "Vape", 3) end
	end

	-- module enabled = toggle on and (no key bound or keybind active)
	local function wanted(m)
		if not V.get(m.id("on"), false) then return false end
		local kb = m.kbw
		if kb then
			local ok, key = pcall(kb.GetKey, kb)
			if ok and key ~= 0 and key ~= nil and not kb.value then return false end
		end
		return true
	end

	-- enable/disable transitions run in RenderStepped (enable may need WorldToScreen), but the toggle/keybind
	-- state is only polled ~13/s by the scheduler; the per-frame loop touches active modules only.
	V.active = {}
	local pending = {}
	V.connect(RunService.RenderStepped, function(dt)
		if #pending > 0 then
			for _, m in ipairs(pending) do
				safe(m, m.enabled and m.enable or m.disable)
				m._ready = m.enabled
				if not m.enabled and m.cleanup then for _, d in ipairs(m.cleanup) do V.undraw(d) end m.cleanup = nil end
			end
			pending = {}
		end
		for _, m in ipairs(V.active) do
			if m.render and m._ready and m.enabled then safe(m, m.render, dt) end
		end
	end)

	V.spawn(function()
		local n = 0
		while V.running do
			local ok, err = pcall(function()
			vals = {}
			local active, changed = {}, false
			for _, m in ipairs(V.mods) do
				local w = wanted(m)
				if w ~= m.enabled then m.enabled = w; changed = true; pending[#pending + 1] = m end
				if w then active[#active + 1] = m end
			end
			if changed then V.active = active end
			if #V.active > 0 then
				if n % 5 == 0 then pcall(V.refreshEntities) end
				if n % 40 == 0 and V.inMatch() and V.needBlocks() then pcall(V.indexBlocks) end
			end
			n = n + 1
			for _, m in ipairs(V.active) do
				if m._ready and m.enabled and m.step and not m._busy then
					m._busy = true
					V.spawn(function() safe(m, m.step); m._busy = false end)
				end
			end
			end)
			if not ok then warn("[Vape] scheduler: " .. tostring(err)) end
			task.wait(0.05)
		end
	end)
	V.notify("Loaded " .. #V.mods .. " modules", "Vape", 4)
end

_G.VapeStop = function()
	V.running = false
	for _, m in ipairs(V.mods) do if m.enabled then m.enabled = false; safe(m, m.disable) end end
	for _, c in ipairs(V.conns) do pcall(function() c:Disconnect() end) end
	local ds = V.drawings
	V.drawings = {}
	for d in pairs(ds) do pcall(function() d:Remove() end) end
	for _, cat in ipairs(V.CATEGORIES) do pcall(UI.RemoveTab, "Vape " .. cat) end
	pcall(UI.RemoveTab, "Vape")
	_G.VapeStop, _G.Vape = nil, nil
end
-- mods_a: AimAssist, AutoClicker, NoClickDelay, Reach, Sprint, TriggerBot, Velocity, AntiVoid, FastBreak, Fly, HitBoxes, InfiniteFly, KeepSprint
-- Shared helpers live on V.A (hand type, crosshair picks, block ray march) and V.attack (aimed SwordHit with the reach shift).
local A = {}
V.A = A

do
	local hf = { "wood_pickaxe", "pickaxe", "axe", "shears" }
	function A.handType()
		local n = V.handName()
		if n == "" then return "none" end
		if n:find("sword") or n:find("blade") or n:find("scythe") or n:find("dao") or n:find("claw") then return "sword" end
		for _, p in ipairs(hf) do if n:find(p) then return "tool" end end
		if n:find("wool") or n:find("_block") or n:find("planks") or n == "stone_brick" or n:find("clay") or n:find("glass") then return "block" end
		return "other"
	end

	-- aimed SwordHit (payload from "bedwars - reach.lua"). Beyond 13 studs selfPosition is shifted toward the target (server tolerates 4).
	function V.attack(ent)
		local root, weapon = V.root(), V.hand()
		if not (root and weapon and ent and ent.RootPart.Parent) then return false end
		local me, them = root.Position, ent.RootPart.Position
		local off = them - me
		if off.Magnitude < 0.01 then return false end
		local dir = off.Unit
		local fake = me + dir * math.clamp(off.Magnitude - 13, 0, 4)
		local camPos = fake + Vector3.new(0, 1.5, 0) - dir * 4
		return V.call("SwordHit", {
			weapon = weapon, entityInstance = ent.Character,
			validate = {
				raycast = { cameraPosition = { value = camPos }, cursorDirection = { value = (them - camPos).Unit } },
				targetPosition = { value = them }, selfPosition = { value = fake },
			},
			chargedAttack = { chargeRatio = 0 },
		})
	end

	-- entity closest to the crosshair inside a cone (deg) and range
	function A.pickAimed(range, cone)
		local root = V.root()
		if not root then return end
		local cam = V.cam().CFrame
		local look, me = cam.LookVector, root.Position
		local best, bd = nil, math.cos(math.rad(cone))
		for _, e in ipairs(V.entities) do
			if e.Targetable and e.RootPart.Parent then
				local p = e.RootPart.Position
				local d = (p - me).Magnitude
				if d <= range and d > 0 then
					local dot = (p - cam.Position).Unit:Dot(look)
					if dot > bd then best, bd = e, dot; e.Distance = d end
				end
			end
		end
		return best
	end

	-- entity whose body the camera ray passes through
	function A.pickRay(range, width)
		local root = V.root()
		if not root then return end
		local cam = V.cam().CFrame
		local look, me = cam.LookVector, root.Position
		local best, bt = nil, math.huge
		for _, e in ipairs(V.entities) do
			if e.Targetable and e.RootPart.Parent then
				local p = e.RootPart.Position
				local v = p - cam.Position
				local t = v:Dot(look)
				if t > 0 and (v - look * t).Magnitude <= width and (p - me).Magnitude <= range and t < bt then best, bt = e, t; e.Distance = (p - me).Magnitude end
			end
		end
		return best
	end

	-- random CPS between a min/max slider pair
	function A.cps(m, kmin, kmax, dmin, dmax)
		local lo = m.opt(kmin, dmin)
		local hi = math.max(lo, m.opt(kmax, dmax))
		return math.max(1, lo + math.random() * (hi - lo))
	end

	-- march the camera ray through the block grid: returns (hitBlockWorldPos, placeWorldPos)
	function A.aimBlock(maxd)
		local root = V.root()
		if not root then return end
		local cam = V.cam().CFrame
		local o, look = cam.Position, cam.LookVector
		local d0 = (root.Position - o).Magnitude
		local prev
		for d = d0, d0 + (maxd or 18), 1.5 do
			local p = o + look * d
			if V.blockAt(p) then return p, prev end
			prev = V.roundPos(p)
		end
	end

	local function gridXYZ(k)
		local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
		return tonumber(x), tonumber(y), tonumber(z)
	end
	-- lowest block Y, recomputed only when the grid is rebuilt
	local lowGrid, lowY
	function A.lowGround()
		local g = V.grid()
		if g ~= lowGrid then
			lowGrid, lowY = g, nil
			for k in pairs(g) do
				local _, y = gridXYZ(k)
				if y and (not lowY or y < lowY) then lowY = y end
			end
		end
		return lowY and lowY * 3
	end
	-- top surface of the highest block below `pos` in its column (walks down at most 60 cells)
	function A.groundY(pos)
		local x, z = math.round(pos.X / 3) * 3, math.round(pos.Z / 3) * 3
		local y = math.round((pos.Y - 3) / 3) * 3
		if y * 1 >= pos.Y - 3 then y = y - 3 end
		for _ = 1, 60 do
			if V.blockAt(Vector3.new(x, y, z)) then return y + 1.5 end
			y = y - 3
		end
	end
	function A.nearBlock(pos)
		local bx, bd = nil, math.huge
		for k in pairs(V.grid()) do
			local x, y, z = gridXYZ(k)
			if x then
				local d = (x * 3 - pos.X) ^ 2 + (z * 3 - pos.Z) ^ 2 + ((y * 3 - pos.Y) ^ 2) * 0.1
				if d < bd then bx, bd = Vector3.new(x * 3, y * 3, z * 3), d end
			end
		end
		return bx
	end
	function A.setPos(root, x, y, z)
		local c = { root.CFrame:GetComponents() }
		c[1], c[2], c[3] = x, y, z
		root.CFrame = CFrame.new(unpack(c))
	end
end

-- Shared click assist for Reach / HitBoxes / NoClickDelay: on a fresh left click send our own aimed SwordHit.
-- The game's own swing still happens, so Reach/HitBoxes only add a hit when the target is beyond native reach (11 studs).
do
	local was, last = false, 0
	V.connect(V.RunService.RenderStepped, function()
		local down = ismouse1pressed()
		local edge = down and not was
		was = down
		if not edge or not V.running or not isrbxactive() or not V.alive() or A.handType() ~= "sword" then return end
		local nd, rc, hb = V.isOn("NoClickDelay"), V.isOn("Reach"), V.isOn("HitBoxes")
		if not (nd or rc or hb) then return end
		local range = nd and 12 or 0
		if rc then range = math.max(range, math.min(V.get("vape_reach_range", 18), 17)) end
		if hb then range = math.max(range, math.min(V.get("vape_hitboxes_expand", 14.4), 17)) end
		if tick() - last < (nd and 0.05 or 0.3) then return end
		local e = A.pickAimed(range, 35)
		if e and (nd or e.Distance > 11) then
			last = tick()
			V.attack(e)
		end
	end)
end

do
	local sortItems = { "Damage", "Distance", "Health", "Angle" }
	local sortMap = { Damage = "Health", Distance = "Distance", Health = "Health", Angle = "Angle" }
	local lastDown, ax, ay = 0, 0, 0
	V.module{
		name = "AimAssist", cat = "Combat", tip = "Smoothly aims to closest valid target with sword (moves the mouse)",
		ui = function(m, sec)
			sec:Toggle(m.id("players"), "Players", true)
			sec:Toggle(m.id("npcs"), "NPCs", false)
			sec:Toggle(m.id("walls"), "Wall check", true)
			sec:Combo(m.id("sort"), "Target Mode", sortItems, 0)
			sec:SliderInt(m.id("speed"), "Aim Speed", 1, 20, 6)
			sec:SliderInt(m.id("dist"), "Distance", 1, 30, 30)
			sec:SliderInt(m.id("angle"), "Max angle", 1, 360, 70)
			sec:Toggle(m.id("click"), "Click Aim", true)
			sec:Toggle(m.id("kill"), "Use killaura target", false)
			sec:Toggle(m.id("shop"), "Shop Check", false)
			sec:Toggle(m.id("fp"), "First Person Check", false)
			sec:Toggle(m.id("strafe"), "Strafe increase", false)
		end,
		render = function(m, dt)
			if ismouse1pressed() then lastDown = tick() end
			if not V.alive() or not isrbxactive() or A.handType() ~= "sword" then return end
			if m.opt("click", true) and tick() - lastDown > 0.4 then return end
			local ent = m.opt("kill", false) and V.killauraTarget or V.targets{
				range = m.opt("dist", 30), part = "RootPart", maxAngle = m.opt("angle", 70),
				wallcheck = m.opt("walls", true), players = m.opt("players", true), npcs = m.opt("npcs", false),
				sort = sortMap[sortItems[m.opt("sort", 0) + 1]],
			}
			if not ent or not ent.RootPart.Parent then return end
			local cam = V.cam()
			if m.opt("fp", false) and (cam.CFrame.Position - V.root().Position).Magnitude > 2 then return end
			if m.opt("shop", false) then
				local pg = V.lp:FindFirstChild("PlayerGui")
				if pg and pg:FindFirstChild("ItemShop") then return end
			end
			local pos, on = WorldToScreen(ent.RootPart.Position)
			if not on then return end
			local vp = cam.ViewportSize
			local speed = m.opt("speed", 6) + ((m.opt("strafe", false) and (iskeypressed(0x41) or iskeypressed(0x44))) and 10 or 0)
			local f = math.clamp(speed * dt, 0, 1)
			ax = ax + (pos.X - vp.X / 2) * f
			ay = ay + (pos.Y - vp.Y / 2) * f
			local ix, iy = ax >= 0 and math.floor(ax) or math.ceil(ax), ay >= 0 and math.floor(ay) or math.ceil(ay)
			ax, ay = ax - ix, ay - iy
			if ix ~= 0 or iy ~= 0 then mousemoverel(ix, iy) end
		end,
	}
end

do
	local nextClick = 0
	V.module{
		name = "AutoClicker", cat = "Combat", tip = "Hold attack to auto click: sends SwordHit at the crosshair target / places blocks at the crosshair",
		ui = function(m, sec)
			sec:SliderInt(m.id("cpsmin"), "CPS min", 1, 9, 4)
			sec:SliderInt(m.id("cpsmax"), "CPS max", 1, 9, 4)
			sec:Toggle(m.id("blocks"), "Place Blocks", true)
			sec:SliderInt(m.id("bcpsmin"), "Block CPS min", 1, 12, 12)
			sec:SliderInt(m.id("bcpsmax"), "Block CPS max", 1, 12, 12)
		end,
		render = function(m)
			if tick() < nextClick or not ismouse1pressed() or not isrbxactive() or not V.alive() then return end
			local t = A.handType()
			if t == "sword" then
				nextClick = tick() + 1 / A.cps(m, "cpsmin", "cpsmax", 4, 4)
				local e = A.pickAimed(14, 30)
				if e then V.attack(e) end
			elseif t == "block" and m.opt("blocks", true) then
				nextClick = tick() + 1 / A.cps(m, "bcpsmin", "bcpsmax", 12, 12)
				local _, place = A.aimBlock(18)
				if place then
					local name = V.handName()
					V.spawn(function() V.placeBlock(place, name) end)
				end
			end
		end,
	}
end

V.module{
	name = "NoClickDelay", cat = "Combat",
	tip = "Approximation: every fresh left click also sends our own SwordHit (no client CPS cap; server cooldown still applies)",
}

V.module{
	name = "Reach", cat = "Combat", tip = "Clicks send an extra SwordHit with shifted selfPosition; server caps around 17 studs",
	ui = function(m, sec) sec:SliderInt(m.id("range"), "Range", 0, 18, 18) end,
}

do
	local held = false
	local function release() if held then held = false; keyrelease(0xA0) end end
	V.module{
		name = "Sprint", cat = "Combat", tip = "Holds Left Shift while you move forward until the Sprinting attribute is set (needs the Roblox window focused)",
		step = function(m)
			local want = V.alive() and isrbxactive() and iskeypressed(0x57) and not V.lp:GetAttribute("Sprinting")
			if want and not held then held = true; keypress(0xA0)
			elseif not (V.alive() and isrbxactive() and iskeypressed(0x57)) then release() end
		end,
		disable = release,
	}
end

do
	local nextHit = 0
	V.module{
		name = "TriggerBot", cat = "Combat", tip = "Automatically attacks when the crosshair is over an enemy",
		ui = function(m, sec)
			sec:SliderInt(m.id("cpsmin"), "CPS min", 1, 9, 4)
			sec:SliderInt(m.id("cpsmax"), "CPS max", 1, 9, 4)
		end,
		render = function(m)
			if tick() < nextHit or not isrbxactive() or not V.alive() or A.handType() ~= "sword" then return end
			local e = A.pickRay(14, 2.5)
			if e then
				nextHit = tick() + 1 / A.cps(m, "cpsmin", "cpsmax", 4, 4)
				V.attack(e)
			end
		end,
	}
end

-- Knockback is client-applied from GC constants (recon): kbDirectionStrength (horizontal), kbUpwardStrength (vertical).
do
	local KEYS = { h = "kbDirectionStrength", v = "kbUpwardStrength" }
	local cache, orig, cur, scanning
	local function set(h, v)
		if not cache or (cur and cur.h == h and cur.v == v) then return end
		cur = { h = h, v = v }
		applygc(cache[KEYS.h], KEYS.h, orig[KEYS.h] * h)
		applygc(cache[KEYS.v], KEYS.v, orig[KEYS.v] * v)
	end
	local function restore() set(1, 1); cur = nil end
	V.module{
		name = "Velocity", cat = "Combat", tip = "Scales knockback constants found via getgc (first enable scans the GC and may freeze for ~15s)",
		ui = function(m, sec)
			sec:SliderInt(m.id("h"), "Horizontal %", 0, 100, 0)
			sec:SliderInt(m.id("v"), "Vertical %", 0, 100, 0)
			sec:SliderInt(m.id("chance"), "Chance %", 0, 100, 100)
			sec:Toggle(m.id("target"), "Only when targeting", false)
		end,
		step = function(m)
			if not cache then
				if scanning then return end
				scanning = true
				V.notify("Velocity: scanning GC...")
				local all = getgc({ KEYS.h, KEYS.v })
				cache, orig = {}, {}
				for _, k in pairs(KEYS) do
					cache[k] = {}
					for _, e in ipairs(all) do
						local n = tonumber(e.value)
						if e.key == k and n and n > 1 then cache[k][#cache[k] + 1] = e; orig[k] = n end -- skip 0-valued decoys
					end
					if not orig[k] then cache, orig = nil, nil; scanning = false; V.notify("Velocity: constants not found"); return end
				end
				scanning = false
			end
			local active = math.random() * 100 <= m.opt("chance", 100)
			if active and m.opt("target", false) then active = V.targets{ range = 50, npcs = false } ~= nil end
			if active then set(m.opt("h", 0) / 100, m.opt("v", 0) / 100) else set(1, 1) end
		end,
		disable = restore,
	}
end

do
	local platY, lastCalc, debounce = nil, 0, 0
	local modes = { "Normal", "Collide", "Velocity" }
	V.module{
		name = "AntiVoid", cat = "Blatant", tip = "No invisible part on Matcha: watches the void line (lowest block - 2) and rescues you.\nNormal - teleport to nearest block\nCollide - hold you at the line\nVelocity - launch upward",
		ui = function(m, sec)
			sec:Combo(m.id("mode"), "Move Mode", modes, 0)
			sec:Toggle(m.id("show"), "Show line", true)
			sec:ColorPicker(m.id("col"), 0.5, 0.3, 1, 1)
		end,
		enable = function(m)
			m.lines = {}
			for i = 1, 4 do m.lines[i] = V.draw("Line", { Thickness = 2 }) end
			m.cleanup = m.lines
		end,
		render = function(m)
			if tick() - lastCalc > 2 then
				lastCalc = tick()
				local low = A.lowGround()
				platY = low and (low - 2)
			end
			local root = V.root()
			if not (root and platY) then for _, l in ipairs(m.lines) do l.Visible = false end return end
			local pos = root.Position
			if m.opt("show", true) then
				local col = m.opt("col", Color3.new(0.5, 0.3, 1))
				if typeof(col) ~= "Color3" then col = Color3.new(0.5, 0.3, 1) end
				local cx, cz, r = math.round(pos.X / 10) * 10, math.round(pos.Z / 10) * 10, 40
				local pts, on = {}, {}
				for i, o in ipairs({ { -r, -r }, { r, -r }, { r, r }, { -r, r } }) do
					pts[i], on[i] = WorldToScreen(Vector3.new(cx + o[1], platY, cz + o[2]))
				end
				for i = 1, 4 do
					local j = i % 4 + 1
					local l = m.lines[i]
					if on[i] and on[j] then l.From, l.To, l.Color, l.Visible = pts[i], pts[j], col, true else l.Visible = false end
				end
			else
				for _, l in ipairs(m.lines) do l.Visible = false end
			end
			if not V.alive() or V.isOn("Fly") or V.isOn("InfiniteFly") or V.isOn("LongJump") then return end
			if pos.Y - 3 > platY + 0.5 or tick() < debounce then return end
			debounce = tick() + 0.1
			local mode = modes[m.opt("mode", 0) + 1]
			local vel = root.AssemblyLinearVelocity
			if mode == "Velocity" then
				root.AssemblyLinearVelocity = Vector3.new(vel.X, 100, vel.Z)
			elseif mode == "Collide" then
				A.setPos(root, pos.X, platY + 3.5, pos.Z)
				root.AssemblyLinearVelocity = Vector3.new(vel.X, 0, vel.Z)
			else
				local b = A.nearBlock(pos)
				if b then
					A.setPos(root, b.X, b.Y + 6, b.Z)
					root.AssemblyLinearVelocity = Vector3.zero
					debounce = tick() + 1
				end
			end
		end,
	}
end

do
	local nextHit = 0
	V.module{
		name = "FastBreak", cat = "Blatant", tip = "Holding attack with a tool repeats DamageBlock on the block under the crosshair at the chosen interval",
		ui = function(m, sec) sec:SliderFloat(m.id("time"), "Break speed", 0, 0.3, 0.25, "%.2f") end,
		render = function(m)
			if tick() < nextHit or not ismouse1pressed() or not isrbxactive() or not V.alive() or A.handType() ~= "tool" then return end
			local hit = A.aimBlock(18)
			if hit then
				nextHit = tick() + math.max(m.opt("time", 0.25), 0.04)
				V.spawn(function() V.hitBlock(hit) end)
			end
		end,
	}
end

do
	local airStart, oldy, back
	local function grounded(root)
		local p = root.Position
		return V.blockAt(p - Vector3.new(0, 4.5, 0)) ~= nil or V.blockAt(p - Vector3.new(0, 3.2, 0)) ~= nil
	end
	V.module{
		name = "Fly", cat = "Blatant", tip = "Velocity fly with Vape's anti-gravity wobble. Space up, Shift down. Balloon inflate/pop not ported",
		ui = function(m, sec)
			sec:SliderInt(m.id("speed"), "Speed", 1, 23, 23)
			sec:SliderInt(m.id("vspeed"), "Vertical Speed", 1, 150, 50)
			sec:Toggle(m.id("wall"), "Wall Check", true)
			sec:Toggle(m.id("bar"), "Progress Bar", true)
			sec:Toggle(m.id("tp"), "TP Down", true)
		end,
		enable = function(m)
			airStart, oldy = nil, nil
			m.bg = V.draw("Square", { Filled = true, Color = Color3.new(0, 0, 0), Transparency = 0.5, Size = Vector2.new(200, 20) })
			m.fill = V.draw("Square", { Filled = true, Color = Color3.fromRGB(120, 90, 255), Transparency = 1, Size = Vector2.new(200, 20) })
			m.txt = V.draw("Text", { Center = true, Outline = true, Size = 16, Color = Color3.new(0.9, 0.9, 0.9) })
			m.cleanup = { m.bg, m.fill, m.txt }
		end,
		render = function(m)
			local root, char = V.root(), V.char()
			if not (root and char and V.alive()) then return end
			local allowed = (char:GetAttribute("InflatedBalloons") or 0) > 0
			local typing = V.typing()
			local up = (not typing and iskeypressed(0x20) and 1 or 0) + (not typing and iskeypressed(0xA0) and -1 or 0)
			local mass = 1.95 + (allowed and 6 or 0) * (tick() % 0.4 < 0.2 and -1 or 1) + up * m.opt("vspeed", 50)
			local dir = typing and Vector3.zero or V.moveDir() * m.opt("speed", 23)
			local pos = root.Position
			if m.opt("wall", true) and dir.Magnitude > 0 and (V.blockAt(pos + dir.Unit * 3) or V.blockAt(pos + dir.Unit * 3 + Vector3.new(0, 3, 0))) then dir = Vector3.zero end

			local air = not grounded(root)
			if not air then airStart = nil elseif not airStart then airStart = tick() end
			if not allowed and m.opt("tp", true) then
				if oldy then
					if tick() >= back then
						A.setPos(root, pos.X, oldy, pos.Z)
						oldy, airStart = nil, tick()
					else
						mass = 0
					end
				elseif airStart and tick() - airStart > 2 then
					local gy = A.groundY(pos)
					if gy then
						oldy, back = pos.Y, tick() + 0.11
						A.setPos(root, pos.X, gy + 3, pos.Z)
					end
				end
			end
			root.AssemblyLinearVelocity = Vector3.new(dir.X, mass, dir.Z)

			local show = m.opt("bar", true) and not allowed
			if show then
				local vp = V.cam().ViewportSize
				local frac = airStart and math.clamp(1 - (tick() - airStart) / 2.6, 0, 1) or 1
				m.bg.Position = Vector2.new(vp.X / 2 - 100, vp.Y - 200)
				m.fill.Position, m.fill.Size = m.bg.Position, Vector2.new(200 * frac, 20)
				m.txt.Position, m.txt.Text = Vector2.new(vp.X / 2, vp.Y - 225), string.format("%.1fs", frac * 2.6)
			end
			m.bg.Visible, m.fill.Visible, m.txt.Visible = show, show, show
		end,
	}
end

do
	V.module{
		name = "HitBoxes", cat = "Blatant", tip = "Approximation: clicks send an extra SwordHit at targets up to Expand studs away (server cap ~17)",
		ui = function(m, sec)
			sec:SliderFloat(m.id("expand"), "Expand amount", 0, 14.4, 14.4, "%.1f")
		end,
	}
end
-- mods_b: Killaura, AutoCharge, LongJump, NoFall, BlockIn, NoSlowdown, ProjectileAimbot, ProjectileAura, Kit Speed Fix, Speed
do
	local GRAV = 196.2 -- workspace.Gravity reads nil on Matcha
	local MB = {}

	local function track(m, d)
		m.cleanup = m.cleanup or {}
		m.cleanup[#m.cleanup + 1] = d
		return d
	end
	local function optColor(m, id, def)
		local c = m.opt(id)
		if c ~= nil and typeof(c) == "Color3" then return c end
		return def
	end
	local function pick(m, id, items, def)
		return items[(m.opt(id, def) or def) + 1] or items[def + 1]
	end
	local function guid() return V.HttpService:GenerateGUID(true) end
	local function shortGuid() return (tostring(V.HttpService:GenerateGUID(false)):match("^[^-]+") or "A"):upper() end
	-- workspace:GetServerTimeNow is missing on Matcha; unix seconds is what it returns on the server
	local function svTime() local ok, t = pcall(os.time); return (ok and t or 0) - 0.045 end
	local function look(root) return root.CFrame.LookVector end
	-- CFrame.lookAt doesn't exist on Matcha: yaw-only facing
	local function faceTo(root, target)
		local p = root.Position
		local d = target - p
		if d.X == 0 and d.Z == 0 then return end
		root.CFrame = CFrame.new(p.X, p.Y, p.Z) * CFrame.Angles(0, math.atan2(-d.X, -d.Z), 0)
	end
	local function ring(lines, center, radius, col)
		local n = #lines
		local prev, prevVis = WorldToScreen(center + Vector3.new(radius, 0, 0))
		for i = 1, n do
			local a = i * math.pi * 2 / n
			local pt, vis = WorldToScreen(center + Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius))
			local l = lines[i]
			if vis and prevVis then
				l.From, l.To, l.Color, l.Visible = prev, pt, col, true
			else
				l.Visible = false
			end
			prev, prevVis = pt, vis
		end
	end
	local function boxOn(box, e, col)
		local p, on = WorldToScreen(e.RootPart.Position)
		if not on then box.Visible = false return end
		local top = WorldToScreen(e.RootPart.Position + Vector3.new(0, 3, 0))
		local bot = WorldToScreen(e.RootPart.Position - Vector3.new(0, 3, 0))
		local h = math.abs(bot.Y - top.Y)
		local w = h * 0.6
		box.Size = Vector2.new(w, h)
		box.Position = Vector2.new(p.X - w / 2, math.min(top.Y, bot.Y))
		box.Color = col
		box.Visible = true
	end

	-- ===== Killaura =====
	do
		local SORTS = { "Damage", "Distance", "Health", "Angle" }
		local SORTMAP = { Damage = "Health", Distance = "Distance", Health = "Health", Angle = "Angle" }
		local REACH, CLAIM, MAX_SHIFT = 17, 13, 4 -- measured server limits, see bedwars - reach.lua

		local function hit(tool, e, me)
			local them = e.RootPart.Position
			local off = them - me
			local dist = off.Magnitude
			if dist <= 0 then return end
			local dir = off.Unit
			local fake = me + dir * math.clamp(dist - CLAIM, 0, MAX_SHIFT)
			local camPos = fake + Vector3.new(0, 1.5, 0) - dir * 4
			V.call("SwordHit", {
				weapon = tool, entityInstance = e.Character,
				validate = {
					raycast = { cameraPosition = { value = camPos }, cursorDirection = { value = (them - camPos).Unit } },
					targetPosition = { value = them }, selfPosition = { value = fake },
				},
				chargedAttack = { chargeRatio = 0 },
			})
		end

		V.module{
			name = "Killaura", cat = "Blatant",
			tip = "Attack players around you without aiming at them. Real reach is capped near 17 studs by the server.",
			ui = function(m, sec)
				sec:Toggle(m.id("players"), "Players", true)
				sec:Toggle(m.id("npcs"), "NPCs", true)
				sec:Toggle(m.id("walls"), "Walls", false)
				sec:SliderInt(m.id("range"), "Attack range", 1, 30, 18)
				sec:Toggle(m.id("rangevis"), "Range Visualiser", false)
				sec:SliderInt(m.id("angle"), "Max angle", 1, 360, 360)
				sec:SliderInt(m.id("rate"), "Update rate", 1, 120, 60)
				sec:SliderInt(m.id("maxt"), "Max targets", 1, 5, 5)
				sec:Combo(m.id("sort"), "Target Mode", SORTS, 0)
				sec:Toggle(m.id("mouse"), "Require mouse down", false)
				sec:Toggle(m.id("gui"), "GUI check", false)
				sec:Tip("GUI check: only attacks while the Roblox window is focused")
				sec:Toggle(m.id("show"), "Show target", false)
				sec:ColorPicker(m.id("boxcol"), 1, 0, 0, 1)
				sec:Toggle(m.id("face"), "Face target", false)
				sec:Toggle(m.id("limit"), "Limit to items", false)
				sec:Toggle(m.id("legit"), "Swing only", false)
				sec:Tip("Swing only: attacks while left mouse is held")
				sec:Toggle(m.id("sigrid"), "Sigrid Check", false)
			end,
			enable = function(m)
				m.attacked, m.last = {}, 0
			end,
			disable = function(m)
				m.attacked, m.boxes, m.ring = {}, nil, nil
				V.attacking = false
			end,
			step = function(m)
				m.attacked = {}
				V.attacking = false
				local root = V.root()
				if not (root and V.alive()) then return end
				if m.opt("mouse", false) or m.opt("legit", false) then
					if not ismouse1pressed() then return end
				end
				if m.opt("gui", false) and not isrbxactive() then return end
				local char = V.char()
				if m.opt("sigrid", false) and char:FindFirstChild("elk") then return end

				local sword
				if m.opt("limit", false) then
					local h = V.hand()
					if h and h.Name:find("sword") then sword = { tool = h, itemType = h.Name } end
				else
					sword = V.getSword()
				end
				if not sword then return end

				local range = math.min(m.opt("range", 18), REACH)
				local list = V.targets{
					range = range, players = m.opt("players", true), npcs = m.opt("npcs", true),
					wallcheck = m.opt("walls", false), limit = m.opt("maxt", 5),
					sort = SORTMAP[pick(m, "sort", SORTS, 0)],
				}
				local me, facing = root.Position, V.flat(look(root))
				local maxAng, attacked = math.rad(m.opt("angle", 360)) / 2, {}
				for _, e in ipairs(list) do
					local d = V.flat(e.RootPart.Position - me)
					local ok = true
					if maxAng < math.pi and d.Magnitude > 0 and facing.Magnitude > 0 then
						ok = math.acos(math.clamp(facing.Unit:Dot(d.Unit), -1, 1)) <= maxAng
					end
					if ok then attacked[#attacked + 1] = e end
				end
				m.attacked = attacked
				if #attacked == 0 then return end
				V.attacking = true

				local cooldown = math.max(0.3, 1 / m.opt("rate", 60)) -- ponytail: fixed 0.3s sword cooldown, see reach script
				if tick() - m.last >= cooldown then
					V.equip(sword)
					for _, e in ipairs(attacked) do hit(sword.tool, e, me) end
					m.last = tick()
					V.lastAttack = tick()
				end
				if m.opt("face", false) then faceTo(root, attacked[1].RootPart.Position) end
			end,
			render = function(m)
				if m.opt("show", false) then
					if not m.boxes then
						m.boxes = {}
						for i = 1, 5 do m.boxes[i] = track(m, V.draw("Square", { Filled = false, Thickness = 2 })) end
					end
					local col = optColor(m, "boxcol", Color3.fromRGB(255, 0, 0))
					for i = 1, 5 do
						local e = m.attacked[i]
						if e and e.RootPart.Parent then boxOn(m.boxes[i], e, col) else m.boxes[i].Visible = false end
					end
				elseif m.boxes then
					for _, b in ipairs(m.boxes) do b.Visible = false end
				end
				if m.opt("rangevis", false) then
					if not m.ring then
						m.ring = {}
						for i = 1, 36 do m.ring[i] = track(m, V.draw("Line", { Thickness = 1 })) end
					end
					local root = V.root()
					if root then
						ring(m.ring, root.Position - Vector3.new(0, 3, 0), math.min(m.opt("range", 18), REACH), optColor(m, "boxcol", Color3.fromRGB(255, 0, 0)))
					end
				elseif m.ring then
					for _, l in ipairs(m.ring) do l.Visible = false end
				end
			end,
		}
	end

	-- ===== LongJump =====
	do
		local ORDER = { "tnt", "siege_tnt", "pirate_gunpowder_barrel", "fireball", "grappling_hook", "jade_hammer", "void_axe",
			"wood_dao", "stone_dao", "iron_dao", "diamond_dao", "emerald_dao" }
		local BASE = 20 -- Vape's getSpeed() with no modifiers

		local function setJump(m, speed, dur, dir)
			m.js, m.jt = speed, tick() + dur
			m.dir = Vector3.new(dir.X, 0, dir.Z).Unit
		end
		local function fire(item, ammo, proj, pos, vel)
			V.call("ProjectileFire", item.tool, ammo, proj, pos, pos, vel, guid(), { drawDurationSeconds = 1, shotId = guid() }, svTime())
		end
		local function tntLike(m, item, pos, dir)
			local r = V.roundPos(pos)
			V.placeBlock(r, item.itemType)
			m.armUntil, m.hint = tick() + 6, r
		end
		local function dao(m, item, pos, dir, val)
			V.equip(item)
			task.wait(0.1)
			V.call("useAbility", "dash", { direction = dir, origin = pos, weapon = item.itemType })
			setJump(m, 4.5 * val, 2.4, dir)
		end
		local function jade(m, item, pos, dir, val)
			V.equip(item)
			task.wait(0.1)
			V.call("useAbility", item.itemType .. "_jump") -- payload unverified
			setJump(m, 1.4 * val, 2.5, dir)
		end
		local METHODS = {
			tnt = tntLike, siege_tnt = tntLike, pirate_gunpowder_barrel = tntLike,
			fireball = function(m, item, pos, dir)
				V.equip(item); task.wait(0.1)
				fire(item, "fireball", "fireball", pos - dir * 0.1, Vector3.new(0, -60, 0))
				m.armUntil, m.hint = tick() + 4, pos
			end,
			grappling_hook = function(m, item, pos, dir, val)
				V.equip(item); task.wait(0.1)
				fire(item, "grappling_hook_projectile", "grappling_hook_projectile", pos - dir * 0.1, Vector3.new(0, -140, 0))
				task.wait(0.3)
				setJump(m, 2.5 * val, 2.5, dir)
			end,
			jade_hammer = jade, void_axe = jade,
			wood_dao = dao, stone_dao = dao, iron_dao = dao, diamond_dao = dao, emerald_dao = dao,
			cat = function(m, _, pos, dir, val)
				V.call("useAbility", "CAT_POUNCE") -- payload unverified
				task.wait(0.15)
				setJump(m, 4 * val, 2.5, dir)
			end,
		}

		local function run(m)
			local root = V.root()
			if not root then return end
			local cam = V.cam().CFrame.LookVector
			local dir = m.opt("camdir", false) and cam or look(root)
			local val, pos = m.opt("speed", 37), root.Position
			local hand = V.handName()
			local item = METHODS[hand] and V.getItem(hand, true)
			local fn = item and METHODS[hand]
			if not fn then
				for _, n in ipairs(ORDER) do
					item = V.getItem(n, true)
					if item then fn = METHODS[n] break end
				end
			end
			if not fn and V.lp:GetAttribute("PlayingAsKits") == "cat" then fn = METHODS.cat; item = {} end
			if not fn then
				V.notify("Unable to find tool to use Long Jump with", "LongJump", 3)
				V.set(m.id("on"), false)
				return
			end
			fn(m, item, pos, dir, val)
		end

		V.module{
			name = "LongJump", cat = "Blatant",
			tip = "Lets you jump farther. Hold/own a TNT, fireball, dao, hammer or hook. Direction and boost approximate Vape's.",
			ui = function(m, sec)
				sec:SliderInt(m.id("speed"), "Speed", 1, 37, 37)
				sec:Toggle(m.id("camdir"), "Camera Direction", false)
			end,
			enable = function(m)
				m.jt, m.js, m.dir, m.began, m.t0, m.armUntil, m.hint = 0, 0, nil, false, tick(), 0, nil
				local c = V.char()
				m.lastHP = c and c:GetAttribute("Health")
				V.spawn(function() local ok, e = pcall(run, m); if not ok then warn("[Vape] LongJump: " .. tostring(e)) end end)
			end,
			disable = function(m) m.jt, m.js, m.dir = 0, 0, nil end,
			step = function(m)
				-- self-damage (TNT/fireball) knockback stands in for Vape's EntityDamageEvent
				local c = V.char()
				local hp = c and c:GetAttribute("Health")
				if hp and m.lastHP and hp < m.lastHP and tick() < m.armUntil and m.js == 0 then
					local root = V.root()
					local dir = look(root)
					if m.hint and root then
						local v = V.flat(root.Position - m.hint)
						if v.Magnitude > 1 then dir = v end
					end
					setJump(m, m.opt("speed", 37), 2.5, dir)
				end
				m.lastHP = hp
				if not m.began and m.jt == 0 and tick() - m.t0 > 10 then
					V.notify("LongJump timed out", "LongJump", 2)
					V.set(m.id("on"), false)
				end
			end,
			render = function(m, dt)
				local root = V.root()
				if not root then return end
				if m.jt > tick() and m.dir then
					local boost = (m.jt - tick()) > 1.1 and m.js or 0
					local vy
					if not m.began then
						m.began, vy = true, 15
					else
						vy = root.AssemblyLinearVelocity.Y + dt * (GRAV - 23)
					end
					root.AssemblyLinearVelocity = m.dir * (BASE + boost) + Vector3.new(0, vy, 0)
				elseif m.began then
					m.began = false
					V.set(m.id("on"), false)
				end
			end,
		}
	end

	-- ===== NoFall =====
	do
		local ITEMS = { "HumanoidState", "VelocityClamp", "TeleportBuffer", "ItemDeploy" }
		local function ground(root)
			local p = root.Position
			local r = workspace:Raycast(p - Vector3.new(0, 4, 0), Vector3.new(0, -50, 0))
			if r and r.Instance and not r.Instance:IsDescendantOf(V.char()) then
				return p.Y - r.Position.Y, r.Position
			end
			return math.huge
		end
		local function clamp(root, v)
			root.AssemblyLinearVelocity = Vector3.new(v.X, -50, v.Z)
		end
		V.module{
			name = "NoFall", cat = "Utility",
			tip = "Prevents fall damage. HumanoidState (no ChangeState on Matcha) clamps fall speed past -85.",
			ui = function(m, sec)
				sec:SliderInt(m.id("risk"), "Risk Threshold", 5, 100, 30)
				sec:Combo(m.id("mode"), "Mitigation Strategies", ITEMS, 0)
			end,
			enable = function(m) m.hist = {} end,
			disable = function(m) m.hist = {} end,
			step = function(m)
				local root = V.root()
				if not root then return end
				local v = root.AssemblyLinearVelocity
				local h = m.hist
				h[#h + 1] = v.Y
				if #h > 10 then table.remove(h, 1) end
				local mode = pick(m, "mode", ITEMS, 0)
				if mode == "HumanoidState" then
					if v.Y < -85 then clamp(root, v) end
					return
				end
				if #h < 10 then return end
				local risk = 0
				for i = 2, #h do
					if h[i] < h[i - 1] and h[i] < 0 then risk = risk + (h[i - 1] - h[i]) end
				end
				local dist, gpos = ground(root)
				if risk * (dist > 10 and 1.5 or 1) <= m.opt("risk", 30) then return end
				if mode == "VelocityClamp" then
					if v.Y < -50 then clamp(root, v) end
				elseif mode == "TeleportBuffer" then
					if gpos and dist > 10 then root.CFrame = CFrame.new(gpos.X, gpos.Y + 3, gpos.Z) end
				else
					local w = V.getWool()
					if w then
						if dist < 10 then V.placeBlock(root.Position - Vector3.new(0, 3, 0), w.itemType) end
					elseif v.Y < -50 then
						clamp(root, v)
					end
				end
			end,
		}
	end

	-- ===== BlockIn =====
	do
		local PATTERN = {
			Vector3.new(3, 0, 0), Vector3.new(0, 0, 3), Vector3.new(-3, 0, 0), Vector3.new(0, 0, -3),
			Vector3.new(3, 3, 0), Vector3.new(0, 3, 3), Vector3.new(-3, 3, 0), Vector3.new(0, 3, -3),
			Vector3.new(0, 6, 0),
		}
		local function blocks()
			local out = {}
			for _, it in ipairs(V.items()) do
				local n = it.itemType
				if n:find("wool") or n:find("_block") or n:find("planks") or n:find("clay") or n:find("obsidian") or n == "stone_brick" then
					out[#out + 1] = it
				end
			end
			return out
		end
		local function off(m) V.set(m.id("on"), false) end
		V.module{
			name = "BlockIn", cat = "Utility",
			tip = "Shields you from attacks for when you are attacking a bed",
			ui = function(m, sec)
				sec:Toggle(m.id("handcheck"), "Hand Check", false)
				sec:Toggle(m.id("autoswitch"), "Auto Switch", true)
			end,
			enable = function(m)
				local root = V.root()
				if not (root and V.alive()) then V.notify("Player data missing", "BlockIn", 3) off(m) return end
				local auto = m.opt("autoswitch", true)
				if m.opt("handcheck", false) and not auto then
					local n = V.handName()
					if not (n:find("wool") or n:find("_block") or n:find("planks") or n:find("clay")) then
						V.notify("You aren't holding a block!", "BlockIn", 2) off(m) return
					end
				end
				local list = blocks()
				if #list == 0 then V.notify("No suitable blocks available", "BlockIn", 3) off(m) return end
				local origin = root.Position
				V.spawn(function()
					local idx = 1
					for _, o in ipairs(PATTERN) do
						if not m.enabled then break end
						local pos = origin + o
						if not V.blockAt(pos) then
							local b = list[idx]
							if auto then V.equip(b) end
							V.placeBlock(pos, b.itemType)
							idx = idx % #list + 1
							task.wait(0.05)
						end
					end
					off(m)
				end)
			end,
		}
	end

	-- ===== NoSlowdown =====
	-- Vape patched the movement modifier table; here we just lift WalkSpeed back up each frame.
	V.module{
		name = "NoSlowdown", cat = "Blatant",
		tip = "Prevents slowing down when using items (restores WalkSpeed in memory if it drops below Min speed).",
		ui = function(m, sec)
			sec:SliderInt(m.id("min"), "Min speed", 4, 30, 16)
		end,
		render = function(m)
			if not V.offsets() then return end
			local want, ws = m.opt("min", 16), V.getWalkSpeed()
			if ws >= 1 and ws < want then V.setWalkSpeed(want) end
		end,
	}

	-- ===== projectile math (Matcha has no ProjectileMeta; speed/gravity are sliders) =====
	-- aim point such that a projectile of `speed` launched from origin hits target moving at tvel
	function MB.solve(origin, speed, grav, tpos, tvel)
		local aim = tpos
		for _ = 1, 4 do
			local t = (aim - origin).Magnitude / speed
			aim = tpos + tvel * t + Vector3.new(0, 0.5 * grav * t * t, 0)
		end
		return aim
	end
	local function partVel(p) return p.AssemblyLinearVelocity or Vector3.zero end

	-- ===== ProjectileAimbot =====
	do
		local PARTS = { "RootPart", "Head" }
		local function isProj(name, other)
			if name:find("bow") then return true end
			return other and (name == "snowball" or name == "fireball" or name:find("knife") or name:find("pearl") or name == "spear") or false
		end
		V.module{
			name = "ProjectileAimbot", cat = "World",
			tip = "Aim assist: while holding left mouse with a bow/projectile it nudges the mouse toward a lead-compensated aim point (Vape hooked the launch calc, impossible here).",
			ui = function(m, sec)
				sec:Toggle(m.id("players"), "Players", true)
				sec:Toggle(m.id("walls"), "Walls", true)
				sec:Combo(m.id("part"), "Part", PARTS, 0)
				sec:SliderInt(m.id("fov"), "FOV", 1, 1000, 1000)
				sec:SliderInt(m.id("range"), "Range", 10, 500, 100)
				sec:SliderInt(m.id("speed"), "Projectile speed", 50, 600, 300)
				sec:SliderInt(m.id("grav"), "Projectile gravity", 0, 400, 196)
				sec:SliderFloat(m.id("smooth"), "Smoothing", 0.05, 1.0, 0.35, "%.2f")
				sec:Toggle(m.id("vis"), "Target Visualiser", true)
				sec:Toggle(m.id("other"), "Other Projectiles", true)
			end,
			disable = function(m) m.box = nil end,
			render = function(m)
				if m.box then m.box.Visible = false end
				if not (isrbxactive() and ismouse1pressed()) then return end
				if not isProj(V.handName(), m.opt("other", true)) then return end
				local root = V.root()
				if not root then return end
				local cam = V.cam()
				local vp = cam.ViewportSize
				local cx, cy = vp.X / 2, vp.Y / 2
				local part, range, fov = pick(m, "part", PARTS, 0), m.opt("range", 100), m.opt("fov", 1000)
				local best, bestD = nil, fov
				for _, e in ipairs(V.entities) do
					if e.Targetable and e.RootPart.Parent and (e.NPC or m.opt("players", true)) then
						local p = e[part]
						if (p.Position - root.Position).Magnitude <= range then
							local s, on = WorldToScreen(p.Position)
							local d = on and (Vector2.new(s.X, s.Y) - Vector2.new(cx, cy)).Magnitude or math.huge
							if d < bestD then
								local ok = true
								if m.opt("walls", true) then
									local hitr = workspace:Raycast(cam.CFrame.Position, p.Position - cam.CFrame.Position)
									if hitr and hitr.Instance and not hitr.Instance:IsDescendantOf(e.Character) and not hitr.Instance:IsDescendantOf(V.char()) then ok = false end
								end
								if ok then best, bestD = e, d end
							end
						end
					end
				end
				if not best then return end
				local p = best[part]
				local aim = MB.solve(cam.CFrame.Position, m.opt("speed", 300), m.opt("grav", 196), p.Position, partVel(p))
				local s, on = WorldToScreen(aim)
				if not on then return end
				local k = m.opt("smooth", 0.35)
				local dx, dy = math.floor((s.X - cx) * k), math.floor((s.Y - cy) * k)
				if dx ~= 0 or dy ~= 0 then mousemoverel(dx, dy) end
				if m.opt("vis", true) then
					if not m.box then m.box = track(m, V.draw("Square", { Filled = false, Thickness = 2 })) end
					boxOn(m.box, best, Color3.fromRGB(255, 0, 0))
				end
			end,
		}
	end

	-- ===== ProjectileAura =====
	do
		local FIRE_DELAY = 0.9
		local BOWS = { wood_bow = "", wood_crossbow = "crossbow_", tactical_crossbow = "tactical_crossbow_" }
		-- kit projectiles: item -> { projectile type, ammo (nil = none), speed, flat aim?, drawDuration }
		local KITS = {
			light_sword = { proj = "sword_wave1", ammo = "light_sword", speed = 80, flat = true, draw = 0 },
			ninja_chakram_4 = { proj = "ninja_chakram_4", speed = 160, draw = 1 },
			mage_spellbook = { proj = "mage_spell_base", speed = 160, draw = 1 },
		}
		local delays = {}

		local function allowed(m)
			local set = { sword_wave1 = true, ninja_chakram_4 = true }
			for n in tostring(m.opt("list", "arrow,snowball")):gmatch("[^,%s]+") do set[n:lower()] = true end
			return set
		end
		local function arrowAmmo(set)
			for _, it in ipairs(V.items()) do
				if it.itemType:find("arrow") and set[it.itemType] then return it.itemType end
			end
		end

		local function shoot(m, e, root)
			local set = allowed(m)
			local pos = root.Position
			local tp = e.RootPart
			local aim = MB.solve(pos, m.opt("speed", 300), m.opt("grav", 196), tp.Position, partVel(tp))
			for _, it in ipairs(V.items()) do
				local n = it.itemType
				if (delays[n] or 0) < tick() then
					local kit, prefix = KITS[n], BOWS[n]
					if kit then
						local tpos = tp.Position + partVel(tp) * ((tp.Position - pos).Magnitude / kit.speed)
						local vel = (kit.flat and V.flat(tpos - pos).Unit or (tpos - pos).Unit) * kit.speed
						V.equip(it)
						V.callAsync("ProjectileFire", it.tool, kit.ammo, kit.proj, pos + Vector3.new(0, 2, 0), pos, vel, shortGuid(),
							{ shotId = shortGuid(), drawDurationSec = kit.draw }, svTime())
						delays[n] = tick() + 0.3
					elseif prefix or set[n] then
						local ammo, proj
						if prefix then
							ammo = arrowAmmo(set)
							if ammo then proj = (ammo == "iron_arrow" and prefix ~= "") and (prefix .. "arrow_iron") or (prefix .. ammo) end
						elseif n ~= "arrow" and not n:find("arrow") then
							ammo, proj = n, n
						end
						if ammo then
							local vel = (aim - pos).Unit * m.opt("speed", 300)
							V.equip(it)
							V.callAsync("ProjectileFire", it.tool, ammo, proj, pos, pos, vel, guid(),
								{ drawDurationSeconds = 1, shotId = guid() }, svTime())
							delays[n] = tick() + FIRE_DELAY
						end
					end
				end
			end
		end

		V.module{
			name = "ProjectileAura", cat = "Blatant",
			tip = "Shoots people around you. Bow/crossbow ammo and projectile types are guessed from item names.",
			ui = function(m, sec)
				sec:Toggle(m.id("walls"), "Walls", true)
				sec:InputText(m.id("list"), "Projectiles (comma list)", "arrow,snowball")
				sec:SliderInt(m.id("range"), "Range", 1, 50, 50)
				sec:SliderInt(m.id("speed"), "Projectile speed", 50, 600, 300)
				sec:SliderInt(m.id("grav"), "Projectile gravity", 0, 400, 196)
			end,
			step = function(m)
				if tick() - (V.lastAttack or 0) <= 0.5 then return end
				local root = V.root()
				if not (root and V.alive()) then return end
				local e = V.targets{ range = m.opt("range", 50), wallcheck = m.opt("walls", true) }
				if e then shoot(m, e, root) end
			end,
		}
	end

	-- ===== Kit Speed Fix =====
	V.module{
		name = "Kit Speed Fix", cat = "World",
		tip = "Fixes movement kits not working when Speed is enabled (Speed no longer overrides a faster velocity).",
		enable = function() V.kitFix = true end,
		disable = function() V.kitFix = false end,
	}

	-- ===== Speed =====
	V.module{
		name = "Speed", cat = "Blatant",
		tip = "Increases your movement by setting horizontal velocity (collisions come from physics, so no wall check needed).",
		ui = function(m, sec)
			sec:SliderInt(m.id("value"), "Speed", 1, 23, 23)
			sec:Toggle(m.id("autojump"), "AutoJump", false)
			sec:Toggle(m.id("alwaysjump"), "Always Jump", false)
		end,
		disable = function(m)
			if m.space then keyrelease(0x20) m.space = false end
		end,
		render = function(m)
			if not isrbxactive() then return end
			if V.isOn("Fly") or V.isOn("InfiniteFly") or V.isOn("LongJump") then return end
			local root = V.root()
			if not root then return end
			if m.space and tick() > (m.rel or 0) then keyrelease(0x20) m.space = false end
			local dir = V.moveDir()
			local v = root.AssemblyLinearVelocity
			local speed = m.opt("value", 23)
			if V.kitFix then
				if dir.Magnitude > 0 and V.flat(v).Magnitude < speed then
					root.AssemblyLinearVelocity = dir * speed + Vector3.new(0, v.Y, 0)
				end
			else
				root.AssemblyLinearVelocity = dir * speed + Vector3.new(0, v.Y, 0)
			end
			if m.opt("autojump", false) and dir.Magnitude > 0 and (V.attacking or m.opt("alwaysjump", false))
				and not m.space and math.abs(v.Y) < 0.5 and tick() - (m.lastJump or 0) > 0.35 then
				keypress(0x20)
				m.space, m.rel, m.lastJump = true, tick() + 0.05, tick()
			end
		end,
	}
end
-- mods_c: BedESP, Health, KitESP, NameTags, StorageESP, AutoBalloon, AutoKit, AutoPearl, AutoPlay, AutoShoot,
-- AutoToxic, AutoVoidDrop, AutoSuffocate, MissileTP, PickupRange, RavenTP

-- ===== shared helpers (attached to V) =====
-- Named scan of the map (CollectionService:GetTagged returns nothing). Depth-limited, skips the Blocks folder and characters.
-- ponytail: walks Folders/Models up to 4 levels, cached per key; a tagged object that isn't named like its tag is missed.
local scanCache = {}
local SKIP = { Blocks = true, ItemDrops = true, Camera = true, Terrain = true }
-- one shared walk (every 2s) feeds every scan key; each key filters that flat list with its predicate
local flat, flatT = {}, 0
local function walkAll()
	local list, chars = {}, {}
	for _, p in ipairs(V.Players:GetPlayers()) do
		if p.Character then chars[p.Character.Address] = true end
	end
	local function walk(parent, depth)
		for _, ch in ipairs(parent:GetChildren()) do
			list[#list + 1] = ch
			if depth < 4 and not SKIP[ch.Name] and not chars[ch.Address] and (ch.ClassName == "Folder" or ch.ClassName == "Model") then
				walk(ch, depth + 1)
			end
		end
	end
	walk(workspace, 1)
	return list
end
function V.scan(key, match, ttl)
	local c = scanCache[key]
	if c and tick() - c.t < (ttl or 2) then return c.list end
	if tick() - flatT > 2 then flat, flatT = walkAll(), tick() end
	local list = {}
	for _, ch in ipairs(flat) do
		if ch.Parent and match(ch) then list[#list + 1] = ch end
	end
	scanCache[key] = { t = tick(), list = list }
	return list
end
function V.bedMatch(i) return i.Name:lower() == "bed" end
-- chests are blocks too (Blocks.chest with a ChestFolderValue, Blocks.personal_chest)
function V.chests(personal)
	local out = {}
	for _, b in pairs(V.grid()) do
		if b ~= true and ((personal and b.Name == "personal_chest") or (not personal and b.Name == "chest")) then out[#out + 1] = b end
	end
	return out
end
-- beds are block-engine blocks (in the Blocks folder the scan skips), so merge the block grid with the scan
function V.beds()
	local out, seen = {}, {}
	for _, b in pairs(V.grid()) do
		if b ~= true and b.Name == "bed" and not seen[b.Address] then seen[b.Address] = true; out[#out + 1] = b end
	end
	for _, b in ipairs(V.scan("bed", V.bedMatch, 2)) do
		if not seen[b.Address] then seen[b.Address] = true; out[#out + 1] = b end
	end
	return out
end

-- a positioned part for an instance (the part itself, PrimaryPart, or first part child)
function V.partOf(inst)
	if inst.ClassName ~= "Model" and inst.ClassName ~= "Folder" then return inst end
	local pp = inst.ClassName == "Model" and inst.PrimaryPart
	if pp then return pp end
	for _, c in ipairs(inst:GetChildren()) do
		if c.ClassName == "Part" or c.ClassName == "MeshPart" then return c end
	end
end

-- screen-space bounding box of an axis-aligned part (needs RenderStepped). returns x0,y0,x1,y1 or nil
function V.boxScreen(pos, size)
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	local x0, y0, x1, y1, n = math.huge, math.huge, -math.huge, -math.huge, 0
	for sx = -1, 1, 2 do
		for sy = -1, 1, 2 do
			for sz = -1, 1, 2 do
				local p, on = WorldToScreen(pos + Vector3.new(hx * sx, hy * sy, hz * sz))
				if on then
					n = n + 1
					x0, y0 = math.min(x0, p.X), math.min(y0, p.Y)
					x1, y1 = math.max(x1, p.X), math.max(y1, p.Y)
				end
			end
		end
	end
	if n == 0 then return nil end
	return x0, y0, x1, y1
end

-- drawing pools keyed by .Address; entries are tables of Drawings plus .seen
function V.poolEnt(pool, key, frame, make)
	local o = pool[key]
	if not o then o = make(); pool[key] = o end
	o.seen = frame
	return o
end
function V.poolPrune(pool, frame)
	for k, o in pairs(pool) do
		if o.seen ~= frame then
			for _, d in pairs(o) do if V.drawings[d] then V.undraw(d) end end
			pool[k] = nil
		end
	end
end
function V.poolClear(pool) V.poolPrune(pool, -1) end

-- ColorPicker value (Color3, alpha) with fallback
function V.colorOpt(id, dc, da)
	local ok, c, a = pcall(UI.GetValue, id)
	if ok and typeof(c) == "Color3" then return c, a or da end
	return dc, da
end

function V.kit() return V.lp:GetAttribute("PlayingAsKit") or V.lp:GetAttribute("PlayingAsKits") end

-- y below which you are falling into the void (lowest placed block - 50); nil until the block grid exists
function V.voidY()
	local c, g = V._voidY, V.grid()
	if c and c.g == g then return c.y end
	local lo
	for k in pairs(g) do
		local y = tonumber(k:match(",(-?%d+),"))
		if y and (not lo or y < lo) then lo = y end
	end
	local y = lo and (lo * 3 - 1.5 - 50) or nil
	V._voidY = { g = g, y = y }
	return y
end

-- send chat; false when the chat channel can't be driven from Matcha
function V.say(msg)
	return (pcall(function()
		local ch = game:GetService("TextChatService").TextChannels.RBXGeneral
		ch:SendAsync(msg)
	end))
end

-- ===== BedESP =====
do
	local pool, beds, frame = {}, {}, 0
	V.module{
		name = "BedESP", cat = "Render", tip = "Render Beds through walls",
		ui = function(m, sec)
			sec:Toggle(m.id("fill"), "Color", true)
			sec:ColorPicker(m.id("fillcol"), 1, 0.2, 0.2, 0.5)
		end,
		step = function(m)
			local out = {}
			for _, b in ipairs(V.beds()) do
				if b.Parent then
					local parts = {}
					if b.ClassName == "Model" then
						for _, p in ipairs(b:GetChildren()) do
							if p.Name ~= "Blanket" and (p.ClassName == "Part" or p.ClassName == "MeshPart") then parts[#parts + 1] = p end
						end
					else
						parts[1] = b
					end
					out[b.Address] = parts
				end
			end
			beds = out
		end,
		render = function(m)
			frame = frame + 1
			local col, alpha = V.colorOpt(m.id("fillcol"), Color3.new(1, 0.2, 0.2), 0.5)
			for id, parts in pairs(beds) do
				for i, p in ipairs(parts) do
					local pos, size = p.Position, p.Size
					if pos and size then
						local o = V.poolEnt(pool, id .. ":" .. i, frame, function()
							return { sq = V.draw("Square", { Filled = true, ZIndex = 2 }) }
						end)
						local legs = p.Name == "Legs"
						if legs then size = size - Vector3.new(0, 1, 0); pos = pos - Vector3.new(0, 0.4, 0) end
						local x0, y0, x1, y1 = V.boxScreen(pos, size)
						if x0 then
							o.sq.Position = Vector2.new(x0, y0)
							o.sq.Size = Vector2.new(x1 - x0, y1 - y0)
							o.sq.Color = legs and Color3.fromRGB(167, 112, 64) or col
							o.sq.Transparency = alpha or 0.5
							o.sq.Visible = true
						else
							o.sq.Visible = false
						end
					end
				end
			end
			V.poolPrune(pool, frame)
		end,
		disable = function() V.poolClear(pool); beds = {} end,
	}
end

-- ===== Health =====
do
	local txt
	V.module{
		name = "Health", cat = "Render", tip = "Displays your health in the center of your screen.",
		render = function(m)
			txt = txt or V.draw("Text", { Size = 18, Center = true, Outline = true, ZIndex = 3 })
			local c = V.char()
			local hp = c and c:GetAttribute("Health")
			if hp and V.alive() then
				local mx = c:GetAttribute("MaxHealth") or 100
				local vp = V.cam().ViewportSize
				txt.Text = math.round(hp) .. " HP"
				txt.Color = Color3.fromHSV(math.clamp(hp / mx, 0, 1) / 2.8, 0.86, 1)
				txt.Position = Vector2.new(vp.X / 2 + 6, vp.Y / 2 + 30)
				txt.Visible = true
			else
				txt.Visible = false
			end
		end,
		disable = function() V.undraw(txt); txt = nil end,
	}
end

-- ===== KitESP =====
do
	local KITS = {
		metal_detector = { { "hidden-metal", "iron" } },
		beekeeper = { { "bee", "bee" } },
		bigman = { { "treeOrb", "natures_essence_1" } },
		alchemist = { { "Thorns", "thorns" }, { "Mushrooms", "mushrooms" }, { "Flower", "wild_flower" } },
		star_collector = { { "CritStar", "crit_star" }, { "VitalityStar", "vitality_star" } },
		spirit_gardener = { { "SpiritGardenerEnergy", "spirit" } },
	}
	local pool, objs, frame = {}, {}, 0
	V.module{
		name = "KitESP", cat = "Render", tip = "Labels kit collectibles (text instead of icons)",
		ui = function(m, sec)
			sec:Toggle(m.id("background"), "Background", true)
			sec:ColorPicker(m.id("bgcolor"), 1, 0, 0, 0.5)
		end,
		step = function(m)
			local out = {}
			local defs = KITS[V.kit() or ""]
			if defs then
				for _, d in ipairs(defs) do
					local tag = d[1]
					for _, inst in ipairs(V.scan("kitesp_" .. tag, function(i) return i.Name == tag end, 1.5)) do
						if inst.Parent then
							local part = V.partOf(inst)
							if part then out[#out + 1] = { id = inst.Address, part = part, label = d[2] } end
						end
					end
				end
			end
			objs = out
		end,
		render = function(m)
			frame = frame + 1
			local bg = m.opt("background", true)
			local col, alpha = V.colorOpt(m.id("bgcolor"), Color3.new(1, 0, 0), 0.5)
			for _, ob in ipairs(objs) do
				local p3 = ob.part.Position
				if p3 then
					local o = V.poolEnt(pool, ob.id, frame, function()
						return {
							bg = V.draw("Square", { Filled = true, ZIndex = 1 }),
							tx = V.draw("Text", { Size = 13, Center = true, Outline = true, ZIndex = 2, Color = Color3.new(1, 1, 1) }),
						}
					end)
					local pos, on = WorldToScreen(p3 + Vector3.new(0, 3, 0))
					if on then
						local w = #ob.label * 7 + 10
						o.tx.Text = ob.label
						o.tx.Position = Vector2.new(pos.X, pos.Y - 7)
						o.tx.Visible = true
						o.bg.Size = Vector2.new(w, 18)
						o.bg.Position = Vector2.new(pos.X - w / 2, pos.Y - 9)
						o.bg.Color = col
						o.bg.Transparency = alpha or 0.5
						o.bg.Visible = bg
					else
						o.tx.Visible, o.bg.Visible = false, false
					end
				end
			end
			V.poolPrune(pool, frame)
		end,
		disable = function() V.poolClear(pool); objs = {} end,
	}
end

-- ===== NameTags =====
do
	local FONTS = { "UI", "System", "SystemBold", "Minecraft", "Monospace", "Pixel", "Fortnite", "ProximaSoftBold" }
	local ARMOR = { "helmet", "chestplate", "boots" }
	local pool, frame = {}, 0

	local function equipStr(plr)
		local parts = {}
		local c = plr.Character
		local hand = c and c:FindFirstChild("HandInvItem")
		hand = hand and hand.Value
		if hand then parts[#parts + 1] = hand.Name end
		for _, it in ipairs(V.items(plr)) do
			for _, a in ipairs(ARMOR) do
				if it.itemType:find(a) then parts[#parts + 1] = (it.itemType:gsub("_" .. a, "")) .. " " .. a:sub(1, 1) end
			end
		end
		local kit = plr:GetAttribute("PlayingAsKit")
		if kit then parts[#parts + 1] = "kit:" .. tostring(kit) end
		return table.concat(parts, ", ")
	end

	V.module{
		name = "NameTags", cat = "Render", tip = "Renders nametags on entities through walls.",
		ui = function(m, sec)
			sec:Toggle(m.id("players"), "Players", true)
			sec:Toggle(m.id("npcs"), "NPCs", false)
			sec:Combo(m.id("font"), "Font", FONTS, 1)
			sec:Toggle(m.id("pcolor"), "Player Color", true)
			sec:ColorPicker(m.id("pcolorval"), 1, 1, 1, 1)
			sec:SliderFloat(m.id("scale"), "Scale", 0.1, 1.5, 1, "%.1f")
			sec:SliderFloat(m.id("transparency"), "Transparency", 0, 1, 0.5, "%.1f")
			sec:Toggle(m.id("health"), "Health", false)
			sec:Toggle(m.id("distance"), "Distance", false)
			sec:Toggle(m.id("equipment"), "Equipment", false)
			sec:Toggle(m.id("displayname"), "Use Displayname", true)
			sec:Toggle(m.id("priority"), "Priority Only", true)
			sec:Toggle(m.id("distcheck"), "Distance Check", false)
			sec:SliderInt(m.id("distmin"), "Min Distance", 0, 256, 0)
			sec:SliderInt(m.id("distmax"), "Max Distance", 0, 256, 64)
		end,
		render = function(m)
			frame = frame + 1
			local wantP, wantN = m.opt("players", true), m.opt("npcs", false)
			local fontName = FONTS[(m.opt("font", 1)) + 1] or "System"
			local font = Drawing.Fonts[fontName]
			local scale = m.opt("scale", 1)
			local bgT = m.opt("transparency", 0.5)
			local showHP, showDist, showEq = m.opt("health", false), m.opt("distance", false), m.opt("equipment", false)
			local useDN, prio = m.opt("displayname", true), m.opt("priority", true)
			local dcheck, dmin, dmax = m.opt("distcheck", false), m.opt("distmin", 0), m.opt("distmax", 64)
			local custom = m.opt("pcolor", true)
			local pcol = V.colorOpt(m.id("pcolorval"), Color3.new(1, 1, 1), 1)
			local root = V.root()
			local me = root and root.Position
			local now = tick()
			local size = 15 * scale

			for _, e in ipairs(V.entities) do
				local ok = (e.Player and wantP) or (e.NPC and wantN)
				if ok and prio and not e.Targetable and not e.Friend then ok = false end
				local rp = ok and e.RootPart.Position
				if rp then
					local dist = me and (rp - me).Magnitude or math.huge
					if not (dcheck and (dist < dmin or dist > dmax)) then
						local o = V.poolEnt(pool, e.Id, frame, function()
							return {
								bg = V.draw("Square", { Filled = true, Color = Color3.new(0, 0, 0), ZIndex = 1 }),
								tx = V.draw("Text", { Center = true, Outline = true, ZIndex = 2 }),
							}
						end)
						local pos, on = WorldToScreen(rp + Vector3.new(0, 3.5, 0))
						if on then
							local name
							if e.Player then
								name = (useDN and e.Player.DisplayName) or e.Player.Name
							else
								name = e.Character.Name
							end
							local t = name
							if showHP then t = t .. " " .. math.round(e.Health) end
							if showDist and me then t = "[" .. math.floor(dist) .. "] " .. t end
							if showEq and e.Player then
								if not o.eqT or now - o.eqT > 1.5 then o.eq, o.eqT = equipStr(e.Player), now end
								if o.eq and o.eq ~= "" then t = t .. " | " .. o.eq end
							end
							local w, h = #t * 0.5 * size + 8, size + 7
							o.tx.Text = t
							o.tx.Size = size
							if font then o.tx.Font = font end
							o.tx.Color = custom and pcol or Color3.new(1, 1, 1)
							o.tx.Position = Vector2.new(pos.X, pos.Y - h + 2.5)
							o.tx.Visible = true
							o.bg.Size = Vector2.new(w, h)
							o.bg.Position = Vector2.new(pos.X - w / 2, pos.Y - h)
							o.bg.Transparency = 1 - bgT
							o.bg.Visible = bgT < 1
						else
							o.tx.Visible, o.bg.Visible = false, false
						end
					end
				end
			end
			V.poolPrune(pool, frame)
		end,
		disable = function() V.poolClear(pool) end,
	}
end

-- ===== StorageESP =====
do
	local pool, chests, frame = {}, {}, 0
	local function wanted(list, name)
		for _, w in ipairs(list) do
			if name == w or name:find(w, 1, true) then return true end
		end
		return false
	end
	V.module{
		name = "StorageESP", cat = "Render", tip = "Displays items in chests (comma list, default diamond,emerald)",
		ui = function(m, sec)
			sec:InputText(m.id("item"), "Item", "diamond,emerald")
			sec:Toggle(m.id("background"), "Background", true)
			sec:ColorPicker(m.id("bgcolor"), 1, 0, 0, 0.5)
		end,
		step = function(m)
			local list = {}
			for w in tostring(m.opt("item", "diamond,emerald")):gmatch("[^,%s]+") do list[#list + 1] = w:lower() end
			local out = {}
			for _, c in ipairs(V.chests()) do
				if c.Parent then
					local cv = c:FindFirstChild("ChestFolderValue")
					local folder = cv and cv.Value
					local part = V.partOf(c)
					if folder and part then
						local seen, names = {}, {}
						for _, it in ipairs(folder:GetChildren()) do
							local n = it.Name
							if not seen[n] and wanted(list, n:lower()) then seen[n] = true; names[#names + 1] = n end
						end
						if #names > 0 then out[c.Address] = { part = part, text = table.concat(names, ", ") } end
					end
				end
			end
			chests = out
		end,
		render = function(m)
			frame = frame + 1
			local bg = m.opt("background", true)
			local col, alpha = V.colorOpt(m.id("bgcolor"), Color3.new(1, 0, 0), 0.5)
			for id, c in pairs(chests) do
				local p3 = c.part.Position
				if p3 then
					local o = V.poolEnt(pool, id, frame, function()
						return {
							bg = V.draw("Square", { Filled = true, ZIndex = 1 }),
							tx = V.draw("Text", { Size = 13, Center = true, Outline = true, ZIndex = 2, Color = Color3.new(1, 1, 1) }),
						}
					end)
					local pos, on = WorldToScreen(p3 + Vector3.new(0, 3, 0))
					if on then
						local w = #c.text * 6.5 + 10
						o.tx.Text = c.text
						o.tx.Position = Vector2.new(pos.X, pos.Y - 7)
						o.tx.Visible = true
						o.bg.Size = Vector2.new(w, 18)
						o.bg.Position = Vector2.new(pos.X - w / 2, pos.Y - 9)
						o.bg.Color = col
						o.bg.Transparency = alpha or 0.5
						o.bg.Visible = bg
					else
						o.tx.Visible, o.bg.Visible = false, false
					end
				end
			end
			V.poolPrune(pool, frame)
		end,
		disable = function() V.poolClear(pool); chests = {} end,
	}
end

-- ===== AutoBalloon =====
do
	local last = 0
	V.module{
		name = "AutoBalloon", cat = "Utility", tip = "Inflates when you fall into the void",
		step = function(m)
			if tick() - last < 0.2 then return end
			last = tick()
			local vy, root = V.voidY(), V.root()
			if not (vy and root and V.alive()) then return end
			if root.Position.Y < vy and (V.char():GetAttribute("InflatedBalloons") or 0) < 3 and V.getItem("balloon", true) then
				for _ = 1, 3 do V.call("InflateBalloon") end
				task.wait(0.1)
			end
		end,
	}
end

-- ===== AutoKit =====
do
	local NAMES = {
		necromancer = "Necromancer", battery = "Battery", beekeeper = "Beekeeper", bigman = "Bigman",
		dragon_slayer = "Dragon Slayer", farmer_cletus = "Farmer Cletus", hannah = "Hannah", jailor = "Jailor",
		grim_reaper = "Grim Reaper", melody = "Melody", metal_detector = "Metal Detector", miner = "Miner",
		pinata = "Pinata", star_collector = "Star Collector", summoner = "Summoner", warlock = "Warlock",
	}
	local sorted = {}
	for k in pairs(NAMES) do sorted[#sorted + 1] = k end
	table.sort(sorted, function(a, b) return NAMES[a] < NAMES[b] end)

	local function legit(m) return m.opt("legit", false) end
	local function root() return V.root() end
	local function sid() local ok, t = pcall(function() return workspace:GetServerTimeNow() end); return ok and t or tick() end

	-- run fn(obj) on objects named `name` within range
	local function collect(m, name, range, specific, fn)
		local r = root()
		if not r then return end
		local lim = (not legit(m) and specific) and math.huge or range
		local me = r.Position
		for _, v in ipairs(V.scan("autokit_" .. name, function(i) return i.Name == name end, 1.5)) do
			local part = v.Parent and V.partOf(v)
			local p = part and part.Position
			if p and (p - me).Magnitude <= lim then fn(v) end
		end
	end

	local lastTarget
	local K = {
		beekeeper = function(m) collect(m, "bee", 18, false, function(v) V.callAsync("PickUpBee", { beeId = v:GetAttribute("BeeId") }) end) end,
		bigman = function(m) collect(m, "treeOrb", 12, false, function(v) V.callAsync("ConsumeTreeOrb", { treeOrbSecret = v:GetAttribute("TreeOrbSecret") }) end) end,
		dragon_slayer = function(m) collect(m, "KaliyahPunchInteraction", 18, true, function(v) V.call("RequestDragonPunch", { target = v }) end) end,
		farmer_cletus = function(m) collect(m, "HarvestableCrop", 10, false, function(v) V.callAsync("CropHarvest", { position = V.blockPos(V.partOf(v).Position) }) end) end,
		hannah = function(m) collect(m, "HannahExecuteInteraction", 30, true, function(v) V.callAsync("HannahPromptTrigger", { user = V.lp, victimEntity = v }) end) end,
		jailor = function(m) collect(m, "jailor_soul", 20, false, function(v) V.call("CollectCollectableEntity", { id = v:GetAttribute("Id"), collectableName = "JailorSoul" }) end) end,
		star_collector = function(m) collect(m, "stars", 20, false, function(v) V.call("CollectCollectableEntity", { id = v:GetAttribute("Id"), collectableName = v.Name }) end) end,
		metal_detector = function(m) collect(m, "hidden-metal", 20, false, function(v) V.call("CollectCollectableEntity", { id = v:GetAttribute("Id") }) end) end,
		miner = function(m) collect(m, "petrified-player", 6, true, function(v) V.call("DestroyPetrifiedPlayer", { petrifyId = v:GetAttribute("PetrifyId") }) end) end,
		pinata = function(m)
			if not V.getItem("candy", true) then return end
			collect(m, V.lp.Name .. ":pinata", 6, true, function(v) V.callAsync("DepositCoins", v) end)
		end,
		grim_reaper = function(m)
			local c = V.char()
			if not (c and (c:GetAttribute("Health") or 0) <= (c:GetAttribute("MaxHealth") or 100) / 4 and not c:GetAttribute("GrimReaperChannel")) then return end
			collect(m, "GrimReaperSoul", 120, false, function(v) V.callAsync("ConsumeGrimReaperSoul", { secret = v:GetAttribute("GrimReaperSoulSecret") }) end)
		end,
		battery = function(m)
			collect(m, "Battery", 10, false, function(v)
				local id = v:GetAttribute("BatteryId")
				if id then V.call("ConsumeBattery", { batteryId = id }) end
			end)
		end,
		necromancer = function(m)
			for _, v in ipairs(V.scan("autokit_grave", function(i) return i.Name == "Gravestone" and i.ClassName == "Model" end, 1.5)) do
				local a = {
					v:GetAttribute("ArmorType"), v:GetAttribute("SwordType"), v:GetAttribute("GravestonePlayerUserId"),
					v:GetAttribute("GravestoneSecret"), v:GetAttribute("GravestonePosition"),
				}
				if a[1] and a[2] and a[3] and a[4] and a[5] and v.Parent then
					V.callAsync("ActivateGravestone", {
						skeletonData = { armorType = a[1], weaponType = a[2], associatedPlayerUserId = a[3] },
						secret = a[4], position = a[5],
					})
				end
			end
		end,
		melody = function(m)
			local r = root()
			if not (r and V.getItem("guitar", true)) then return end
			local mag, hp, ent = 30, math.huge, nil
			for _, e in ipairs(V.entities) do
				if e.Player and V.team(e.Player) ~= nil and V.team(e.Player) == V.team(V.lp) then
					local d = (r.Position - e.RootPart.Position).Magnitude
					if d <= mag and e.Health < hp and e.Health < e.MaxHealth then mag, hp, ent = d, e.Health, e end
				end
			end
			if ent then V.call("PlayGuitar", { healTarget = ent.Character }) end
		end,
		summoner = function(m)
			local r = root()
			local e = r and V.targets({ range = 31, players = true, npcs = false, sort = "Health" })
			if e and (V.char():GetAttribute("Health") or 0) > 0 then
				local from = r.Position
				local dir = (e.RootPart.Position - from).Unit
				from = from + dir * math.max((from - e.RootPart.Position).Magnitude - 16, 0)
				V.call("SummonerClawAttackRequest", { position = from, direction = dir, clientTime = sid() })
			end
		end,
		warlock = function(m)
			if V.handName() ~= "warlock_staff" then lastTarget = nil; return end
			local e = V.targets({ range = 30, players = true, npcs = true })
			if e and e.Character ~= lastTarget then
				local ok, res = V.call("WarlockLinkTarget", { target = e.Character })
				if not (ok and res) then e = nil end
			end
			lastTarget = e and e.Character
		end,
	}
	local lastRun = 0

	V.module{
		name = "AutoKit", cat = "Utility",
		tip = "Automatically uses kit abilities",
		ui = function(m, sec)
			sec:Toggle(m.id("legit"), "Legit Range", false)
			for _, k in ipairs(sorted) do sec:Toggle(m.id("kit_" .. k), NAMES[k], true) end
		end,
		step = function(m)
			if tick() - lastRun < 0.1 then return end
			lastRun = tick()
			local kit = V.kit()
			local fn = kit and K[kit]
			if fn and V.alive() and m.opt("kit_" .. kit, true) then fn(m) end
		end,
	}
end

-- ===== AutoPearl =====
do
	-- ponytail: telepearl launchVelocity/gravity aren't reachable without require; 100 / 196.2 are guesses. Tune if pearls land short.
	local PEARL_V, G = 100, 196.2
	local lastY, lastT, check = nil, 0, false

	local function solve(from, to)
		local d = to - from
		local h = Vector3.new(d.X, 0, d.Z)
		local x = h.Magnitude
		if x < 0.1 then return Vector3.new(0, PEARL_V, 0) end
		local y, v2 = d.Y, PEARL_V * PEARL_V
		local disc = v2 * v2 - G * (G * x * x + 2 * y * v2)
		local ang = disc < 0 and math.atan2(y, x) or math.atan2(v2 - math.sqrt(disc), G * x)
		return (h.Unit * math.cos(ang) + Vector3.new(0, math.sin(ang), 0)) * PEARL_V
	end
	local function groundBelow(pos, depth)
		for dy = 3, depth, 3 do
			if V.blockAt(pos - Vector3.new(0, dy, 0)) then return true end
		end
		return false
	end
	local function nearGround(pos, radius)
		local best, bd
		for dx = -radius, radius, 3 do
			for dz = -radius, radius, 3 do
				local d = dx * dx + dz * dz
				if d <= radius * radius and (not bd or d < bd) then
					for dy = 3, 45, 3 do
						local p = pos + Vector3.new(dx, -dy, dz)
						if V.blockAt(p) then best, bd = V.roundPos(p) + Vector3.new(0, 4.5, 0), d; break end
					end
				end
			end
		end
		return best
	end

	V.module{
		name = "AutoPearl", cat = "Utility",
		tip = "Throws a pearl onto nearby ground when falling into the void (pearl physics guessed)",
		disable = function() lastY, check = nil, false end,
		step = function(m)
			local root = V.root()
			if not (root and V.alive()) then lastY = nil; return end
			local now, y = tick(), root.Position.Y
			if lastY and now - lastT < 0.1 then return end
			local vy = lastY and (y - lastY) / (now - lastT) or 0
			lastY, lastT = y, now
			local vyv = V.voidY()
			local pearl = V.getItem("telepearl", true)
			local falling = vy < -50
			local belowMap = vyv and y < vyv + 40
			if pearl and falling and (belowMap or not groundBelow(root.Position, 50)) then
				if not check then
					check = true
					local spot = nearGround(root.Position, 20)
					if spot then
						local pos = root.Position
						local prev = V.hand()
						if V.equip(pearl) then
							task.wait(0.05)
							local id = V.HttpService:GenerateGUID(true)
							local ok, t = pcall(function() return workspace:GetServerTimeNow() end)
							V.call("ProjectileFire", pearl.tool, "telepearl", "telepearl", pos, pos, solve(pos, spot), id,
								{ drawDurationSeconds = 1, shotId = V.HttpService:GenerateGUID(false) }, (ok and t or tick()) - 0.045)
							if prev then V.equip(prev) end
						end
					end
				end
			else
				check = false
			end
		end,
	}
end

-- ===== AutoShoot =====
do
	local shooting, wasDown = false, false
	V.module{
		name = "AutoShoot", cat = "Utility",
		tip = "Crossbow macro: when you shoot a bow, fires your other crossbows too (polls the mouse; no projectile hook)",
		step = function(m)
			local down = ismouse1pressed()
			local edge = down and not wasDown
			wasDown = down
			if not edge or shooting or not isrbxactive() or not V.handName():find("bow") then return end
			shooting = true
			task.wait(0.15)
			local cur = V.hand()
			for _, it in ipairs(V.items()) do
				if it.itemType:find("crossbow") and it.tool ~= cur then
					if V.equip(it) then
						task.wait(0.05)
						mouse1click()
						task.wait(0.05)
					end
				end
			end
			if cur then V.equip(cur) end
			shooting = false
		end,
	}
end

-- ===== AutoToxic =====
do
	local DEFAULTS = {
		Kill = "vxp on top | <obj>",
		Death = "my gaming chair subscription expired :( | <obj>",
		Bed = "nice bed lul | <obj>",
	}
	local prev, beds, lastSay, said = {}, {}, 0, {}
	local lastPos, wasAlive = nil, true

	local function send(m, name, obj)
		if not m.opt(name:lower(), false) then return end
		local pool = {}
		for s in tostring(m.opt(name:lower() .. "msgs", "")):gmatch("[^|]+") do pool[#pool + 1] = s end
		local msg = #pool > 0 and pool[math.random(1, #pool)] or DEFAULTS[name]
		if not msg or tick() - lastSay < 2 then return end
		lastSay = tick()
		msg = msg:gsub("<obj>", obj or "")
		if not V.say(msg) then V.notify(msg, "AutoToxic (chat unavailable)", 4) end
	end
	local function dn(plr) return plr.DisplayName or plr.Name end

	V.module{
		name = "AutoToxic", cat = "Utility",
		tip = "Kill/Death/Bed approximated from nearby entities vanishing. Separate messages with |",
		ui = function(m, sec)
			for _, v in ipairs({ "Kill", "Death", "Bed" }) do
				sec:Toggle(m.id(v:lower()), v .. " ", false)
				sec:InputText(m.id(v:lower() .. "msgs"), v .. " messages", "")
			end
		end,
		disable = function() prev, beds, lastPos = {}, {}, nil end,
		step = function(m)
			local now = tick()
			local root = V.root()
			-- kills: an enemy near us disappears and does not respawn within ~6s
			local cur = {}
			for _, e in ipairs(V.entities) do
				if e.Player and e.Targetable then
					cur[e.Player.UserId] = true
					prev[e.Player.UserId] = { plr = e.Player, pos = e.RootPart.Position, t = now }
				end
			end
			for id, p in pairs(prev) do
				if not cur[id] then
					prev[id] = nil
					if root and now - p.t < 1 and (p.pos - root.Position).Magnitude < 30 then
						V.spawn(function()
							task.wait(6.5)
							local c = p.plr.Character
							local r = c and c:FindFirstChild("HumanoidRootPart")
							if p.plr.Parent and not (r and (c:GetAttribute("Health") or 1) > 0) then send(m, "Kill", dn(p.plr)) end
						end)
					end
				end
			end
			-- own death: killer = last enemy seen close by
			local alive = V.alive()
			if alive and root then lastPos = root.Position end
			if wasAlive and not alive and lastPos then
				local killer, bd
				for _, p in pairs(prev) do
					local d = (p.pos - lastPos).Magnitude
					if d < 40 and (not bd or d < bd) then killer, bd = p.plr, d end
				end
				if killer then
					V.spawn(function()
						task.wait(7)
						if not V.alive() then send(m, "Death", dn(killer)) end
					end)
				end
			end
			wasAlive = alive
			-- beds: one vanishing while we're next to it
			local seen = {}
			for _, b in ipairs(V.beds()) do
				local part = b.Parent and V.partOf(b)
				if part and part.Position then
					seen[b.Address] = true
					beds[b.Address] = part.Position
				end
			end
			for id, pos in pairs(beds) do
				if not seen[id] then
					beds[id] = nil
					if root and (pos - root.Position).Magnitude < 30 then send(m, "Bed", "white") end
				end
			end
		end,
	}
end

-- ===== AutoVoidDrop =====
do
	local last = 0
	V.module{
		name = "AutoVoidDrop", cat = "Utility", tip = "Drops resources when you fall into the void",
		ui = function(m, sec) sec:Toggle(m.id("owlcheck"), "Owl check", true) end,
		step = function(m)
			if tick() - last < 0.1 then return end
			last = tick()
			local vy, root = V.voidY(), V.root()
			if not (vy and root and V.alive()) then return end
			if root.Position.Y < vy and (V.char():GetAttribute("InflatedBalloons") or 0) <= 0 and not V.getItem("balloon", true) then
				if m.opt("owlcheck", true) and root:FindFirstChild("OwlLiftForce") then return end
				for _, n in ipairs({ "iron", "diamond", "emerald", "gold" }) do
					local it = V.getItem(n, true)
					if it then
						local ok, drop = V.call("DropItem", { item = it.tool, amount = it.amount })
						if ok and drop and drop ~= true then pcall(function() drop:SetAttribute("ClientDropTime", tick() + 100) end) end
					end
				end
			end
		end,
	}
end

-- ===== AutoSuffocate =====
do
	local last = 0
	local SIDES = { Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) }
	local function blockName(n)
		return n:find("wool") or n:find("_block") or n:find("planks") or n:find("clay") or n:find("glass")
	end
	V.module{
		name = "AutoSuffocate", cat = "World", tip = "Places blocks on nearby confined entities",
		ui = function(m, sec)
			sec:SliderInt(m.id("range"), "Range", 1, 20, 20)
			sec:Toggle(m.id("limititem"), "Limit to Items", true)
		end,
		step = function(m)
			if tick() - last < 0.09 then return end
			last = tick()
			local hand = V.handName()
			local item = blockName(hand) and hand
			if not item and not m.opt("limititem", true) then
				local w = V.getWool()
				item = w and w.itemType
			end
			if not item then return end
			local list = V.targets({ range = m.opt("range", 20), players = true, npcs = false, limit = 20 })
			for _, ent in ipairs(list) do
				local need = {}
				for _, s in ipairs(SIDES) do
					local p = V.roundPos(ent.RootPart.Position + s * 2)
					if not V.blockAt(p) then need[#need + 1] = p end
				end
				if #need < 3 then
					need[#need + 1] = V.roundPos(ent.Head.Position)
					need[#need + 1] = V.roundPos(ent.RootPart.Position - Vector3.new(0, 1, 0))
					for _, p in ipairs(need) do
						if not V.blockAt(p) then V.placeBlock(p, item); break end
					end
				end
			end
		end,
	}
end

-- ===== MissileTP / RavenTP =====
-- target is picked in enable (runs inside RenderStepped, the only place WorldToScreen works); the rest runs on a thread.
local function setPos(part, p)
	if not part then return end
	if not pcall(function() part.CFrame = CFrame.new(p.X, p.Y, p.Z) end) then pcall(function() part.Position = p end) end
end

V.module{
	name = "MissileTP", cat = "Utility",
	tip = "Spawns and teleports a missile to a player near your mouse. No anti-gravity body force on Matcha: position is re-pinned every 0.1s",
	enable = function(m)
		V.set(m.id("on"), false)
		local e = V.targetMouse(1000)
		if not (e and V.getItem("guided_missile", true)) then return end
		V.spawn(function()
			local ok, proj = V.call("FireGuidedProjectile", "guided_missile")
			local model = ok and type(proj) ~= "boolean" and proj and proj.model
			if not model then V.notify("Missile on cooldown.", "MissileTP", 3); return end
			for _ = 1, 100 do
				local pp = model.Parent and model.PrimaryPart
				local rp = e.RootPart.Parent and e.RootPart.Position
				if not (pp and rp) then break end
				setPos(pp, rp)
				task.wait(0.1)
			end
		end)
	end,
}

V.module{
	name = "RavenTP", cat = "Utility", tip = "Spawns and teleports a raven to a player near your mouse.",
	enable = function(m)
		V.set(m.id("on"), false)
		local e = V.targetMouse(1000)
		if not (e and V.getItem("raven", true)) then return end
		V.spawn(function()
			local ok, proj = V.call("SpawnRaven")
			local pp = ok and type(proj) ~= "boolean" and proj and proj.PrimaryPart
			if not pp then return end
			for _ = 1, 20 do
				local rp = e.RootPart.Parent and e.RootPart.Position
				if rp then setPos(pp, rp) end
				task.wait(0.05)
			end
			task.wait(0.3)
			V.call("DetonateRaven")
		end)
	end,
}

-- ===== PickupRange =====
do
	local tried, last = {}, 0
	V.module{
		name = "PickupRange", cat = "Utility", tip = "Picks up items from a farther distance",
		ui = function(m, sec)
			sec:SliderInt(m.id("range"), "Range", 1, 10, 10)
			sec:Toggle(m.id("feet"), "Feet Check", false)
		end,
		step = function(m)
			local now = tick()
			if now - last < 0.1 then return end
			last = now
			local root, folder = V.root(), workspace:FindFirstChild("ItemDrops")
			if not (root and folder and V.alive()) then return end
			local me, range, feet = root.Position, m.opt("range", 10), m.opt("feet", false)
			local fired = 0
			for _, d in ipairs(folder:GetChildren()) do
				local p = d.Position
				if p and (me - p).Magnitude <= range and fired < 6 then
					local id = d.Address
					if now - (d:GetAttribute("ClientDropTime") or 0) >= 2 and now - (tried[id] or 0) > 0.4
						and not (feet and (me.Y - p.Y) < 1) then
						tried[id] = now
						fired = fired + 1
						V.callAsync("PickupItemDrop", { itemDrop = d })
					end
				end
			end
			for id, t in pairs(tried) do if now - t > 5 then tried[id] = nil end end
		end,
	}
end
-- mods_d: Scaffold, ShopTierBypass, StaffDetector, TrapDisabler, Anti-AFK, AutoTool, BetterDavey, BedProtector,
-- ChestSteal, Schematica, AutoWhisper, ArmorSwitch, AutoBuy, AutoConsume
-- Shared helpers added to V: isBlockName, scan, posOf, nearBed, setVelY

local BLOCK_PATTERNS = { "wool", "plank", "stone_brick", "ceramic", "obsidian", "clay", "glass", "end_stone", "_block", "bricks" }
function V.isBlockName(n)
	n = tostring(n):lower()
	for _, p in ipairs(BLOCK_PATTERNS) do if n:find(p, 1, true) then return true end end
	return false
end

-- V.scan is defined in mods_c
function V.posOf(i)
	if not i then return nil end
	local p = i.Position
	if p then return p end
	local pp = i.PrimaryPart
	if pp then return pp.Position end
	for _, c in ipairs(i:GetChildren()) do
		if c.ClassName == "Part" or c.ClassName == "MeshPart" then return c.Position end
	end
end
function V.nearBed(range)
	local root = V.root()
	if not root then return nil end
	local t = V.lp:GetAttribute("Team") or -1
	for _, b in ipairs(V.beds()) do
		local p = V.posOf(b)
		if p and (root.Position - p).Magnitude < range and b:GetAttribute("Team" .. t .. "NoBreak") then return b, p end
	end
end
-- vertical velocity set via memory (property assignment costs thousands of writes); falls back to the property
function V.setVelY(root, y)
	local o = V.offsets()
	if o and o.BasePart and o.BasePart.Primitive and o.Primitive and o.Primitive.AssemblyLinearVelocity then
		local prim = memory_read("uintptr_t", root.Address + o.BasePart.Primitive)
		if prim and prim ~= 0 then
			memory_write("float", prim + o.Primitive.AssemblyLinearVelocity + 4, y)
			return true
		end
	end
	local v = root.AssemblyLinearVelocity
	if v then root.AssemblyLinearVelocity = Vector3.new(v.X, y, v.Z) end
end
local function splitList(str)
	local t = {}
	for s in tostring(str or ""):gmatch("[^,]+") do
		s = s:match("^%s*(.-)%s*$")
		if s ~= "" then t[#t + 1] = s end
	end
	return t
end
local function lowerSet(list)
	local s = {}
	for _, v in ipairs(list) do s[v:lower()] = true end
	return s
end

-- ===== Scaffold =====
do
	local lastpos = Vector3.zero
	local adjacent = {}
	for x = -3, 3, 3 do for y = -3, 3, 3 do for z = -3, 3, 3 do
		if x ~= 0 or y ~= 0 or z ~= 0 then adjacent[#adjacent + 1] = Vector3.new(x, y, z) end
	end end end
	V.adjacent = adjacent

	local function checkAdjacent(pos)
		for _, v in ipairs(adjacent) do if V.blockAt(pos + v) then return true end end
		return false
	end
	V.checkAdjacent = checkAdjacent

	local function clamp3(v, lo, hi) return Vector3.new(math.clamp(v.X, lo.X, hi.X), math.clamp(v.Y, lo.Y, hi.Y), math.clamp(v.Z, lo.Z, hi.Z)) end
	-- nearest existing block (within 21 studs) -> point on its 3-stud neighbourhood closest to pos
	local function blockProximity(pos)
		local mag, ret = 60, nil
		for _, b in pairs(V.grid()) do
			if type(b) ~= "boolean" then
				local bp = b.Position
				if bp and math.abs(bp.X - pos.X) < 21 and math.abs(bp.Y - pos.Y) < 21 and math.abs(bp.Z - pos.Z) < 21 then
					local d = pos - bp
					local c = d.Magnitude > 0 and clamp3(bp + d.Unit * 100, bp - Vector3.new(3, 3, 3), bp + Vector3.new(3, 3, 3)) or bp
					local m = (pos - c).Magnitude
					if m < mag then mag, ret = m, c end
				end
			end
		end
		return ret
	end

	local function getBlock(m)
		local hand = V.hand()
		if hand and V.isBlockName(hand.Name) then
			local isWool = hand.Name:find("wool")
			if not m.opt("woolonly", false) or isWool then return { itemType = hand.Name, tool = hand }, hand:GetAttribute("Amount") or 1 end
		elseif not m.opt("limititem", false) or m.opt("autoswitch", false) then
			local w = V.getWool()
			if w and (not m.opt("woolonly", false) or w.itemType:find("wool")) then return w, w.amount end
			if not m.opt("woolonly", false) then
				for _, it in ipairs(V.items()) do
					if V.isBlockName(it.itemType) then return it, it.amount end
				end
			end
		end
		return nil, 0
	end

	V.module{
		name = "Scaffold", cat = "Utility", tip = "Helps you make bridges/scaffold walk.",
		ui = function(m, sec)
			sec:SliderInt(m.id("expand"), "Expand", 1, 6, 1)
			sec:Toggle(m.id("tower"), "Tower", true)
			sec:Toggle(m.id("downwards"), "Downwards", true)
			sec:Toggle(m.id("diagonal"), "Diagonal", true)
			sec:Toggle(m.id("woolonly"), "Wool Only", false)
			sec:Toggle(m.id("limititem"), "Limit to items", false)
			sec:Toggle(m.id("mouse"), "Require mouse down", false)
			sec:Toggle(m.id("autoswitch"), "Auto Switch", false)
			sec:Toggle(m.id("count"), "Block Count", false)
		end,
		enable = function(m)
			m.label = V.draw("Text", { Size = 18, Center = true, Outline = true, Color = Color3.new(0, 1, 0), Text = "0" })
			m.cleanup = { m.label }
		end,
		disable = function(m) m.label = nil end,
		render = function(m)
			local l = m.label
			if not l then return end
			if m.opt("count", false) then
				local vp = V.cam().ViewportSize
				l.Position = Vector2.new(vp.X / 2 + 6, vp.Y / 2 + 60)
				l.Text = (m.count or 0) .. " (Scaffold)"
				l.Color = Color3.fromHSV(math.clamp(((m.count or 0) / 128) / 2.8, 0, 0.36), 0.86, 1)
				l.Visible = true
			else
				l.Visible = false
			end
		end,
		step = function(m)
			if not V.alive() then return end
			local root = V.root()
			local item, amount = getBlock(m)
			m.count = amount or 0
			if m.opt("mouse", false) and not ismouse1pressed() then item = nil end
			if not item then return end
			if m.opt("autoswitch", false) then V.equip(item) end
			local focused = isrbxactive()
			if m.opt("tower", true) and focused and iskeypressed(0x20) then V.setVelY(root, 38) end

			local md = V.moveDir()
			local down = m.opt("downwards", true) and focused and iskeypressed(0xA0)
			local base = Vector3.new(root.Position.X, root.Position.Y - (down and 6.5 or 3.5), root.Position.Z)
			for i = m.opt("expand", 1), 1, -1 do
				local cur = V.roundPos(base + md * (i * 3))
				if m.opt("diagonal", true) and md.Magnitude > 0 and math.abs(math.round(math.deg(math.atan2(-md.X, -md.Z)) / 45) * 45) % 90 == 45 then
					local d = lastpos - cur
					if ((d.X == 0 and d.Z ~= 0) or (d.X ~= 0 and d.Z == 0)) and V.flat(lastpos - root.Position).Magnitude < 2.5 then cur = lastpos end
				end
				if not V.blockAt(cur) then
					local at = checkAdjacent(cur) and cur or blockProximity(cur)
					if at then
						V.markPlaced(V.roundPos(at))
						local name = item.itemType
						V.spawn(function() V.placeBlock(at, name) end)
					end
				end
				lastpos = cur
			end
		end,
	}
end

-- ===== ShopTierBypass =====
do
end

-- ===== StaffDetector =====
do
	local blacklistedclans = { gg = true, gg2 = true, dv = true, dv2 = true }
	local blacklisteduserids = {}
	for _, id in ipairs({ 1502104539, 3826146717, 4531785383, 1049767300, 4926350670, 653085195, 184655415, 2752307430, 5087196317, 5744061325, 1536265275 }) do blacklisteduserids[id] = true end
	local admins = {}
	for _, id in ipairs({ 87365146, 225721992, 21406719, 308165, 281575310, 3361695884, 22808138, 1793668872, 22641473, 4001781, 75380482, 20663325, 4308133 }) do admins[id] = true end
	local others = { [78390760] = "filmer", [1776734677] = "filmer", [172603477] = "artist", [2237298638] = "artist", [437492645] = "artist", [34466481] = "artist", [205430552] = "artist" }
	local modes = { "Uninject", "Profile", "AutoConfig", "Notify" }
	local safeMods = { AutoClicker = true, Reach = true, Sprint = true, HitFix = true, StaffDetector = true }
	local seen = {}

	local function staff(m, plr, why)
		V.notify("Staff Detected (" .. why .. "): " .. plr.Name .. " (" .. plr.UserId .. ")", "StaffDetector", 30)
		local mode = modes[m.opt("mode", 0) + 1]
		if mode == "Uninject" then
			V.spawn(function() if _G.VapeStop then _G.VapeStop() end end)
		elseif mode == "AutoConfig" then
			for _, x in ipairs(V.mods) do
				if not (safeMods[x.name] or x.cat == "Render") then V.set(x.id("on"), false) end
			end
		end -- Profile: no profile system on Matcha, behaves like Notify
	end

	V.module{
		name = "StaffDetector", cat = "Utility", tip = "Detects people with a staff rank ingame (userid / clan / permissions; spectator-join check not available)",
		ui = function(m, sec)
			sec:Combo(m.id("mode"), "Mode", modes, 0)
			sec:Toggle(m.id("clans"), "Blacklist clans", true)
			sec:InputText(m.id("users"), "Users (userids, comma list)", "")
		end,
		disable = function() seen = {} end,
		step = function(m)
			local custom = lowerSet(splitList(m.opt("users", "")))
			for _, plr in ipairs(V.Players:GetPlayers()) do
				if plr ~= V.lp then
					local id = plr.UserId
					local rec = seen[id]
					if not rec then rec = {}; seen[id] = rec end
					if not rec.done then
						if blacklisteduserids[id] or custom[tostring(id)] then
							rec.done = true; staff(m, plr, "blacklisted_user")
						elseif admins[id] then
							rec.done = true; staff(m, plr, "permissions_detected")
						else
							if not rec.role then
								rec.role = true
								local ok, r = pcall(function() return plr:GetRankInGroup(5774246) end)
								if ok and type(r) == "number" and r >= 100 then rec.done = true; staff(m, plr, "staff_role") end
								if others[id] then V.notify(plr.Name .. " is " .. others[id] .. "!", "StaffDetector", 3) end
							end
							local clan = plr:GetAttribute("ClanTag")
							if not rec.done and clan and m.opt("clans", true) and blacklistedclans[tostring(clan):lower()] then
								rec.done = true; staff(m, plr, "blacklisted_clan_" .. tostring(clan):lower())
							end
						end
					end
				end
			end
		end,
	}
end

-- ===== TrapDisabler =====
do
end

-- ===== Anti-AFK =====
do
	local last = 0
	V.module{
		name = "Anti-AFK", cat = "World", tip = "Lets you stay ingame without getting kicked (sends AfkInfo afk=false; Idled connections can't be disconnected)",
		enable = function() last = 0 end,
		step = function()
			if tick() - last > 20 then
				last = tick()
				V.call("AfkInfo", { afk = false })
			end
		end,
	}
end

-- ===== AutoTool =====
do
	-- tool per block: wool/bed -> shears, wood -> axe, everything else -> pickaxe
	local function toolFor(name)
		name = name:lower()
		if name:find("wool") or name == "bed" then return V.getItem("shears") end
		if name:find("plank") or name:find("log") or name:find("wood") then return V.getAxe() end
		return V.getPickaxe()
	end
	-- ponytail: no mouse raycast; picks the grid block nearest the camera ray (<= 6 studs out). O(blocks) per call.
	local function lookedBlock()
		local cam, root = V.cam(), V.root()
		if not root then return nil end
		local o, dir = cam.CFrame.Position, cam.CFrame.LookVector
		local best, bestD = nil, 2.2
		for _, b in pairs(V.grid()) do
			if type(b) ~= "boolean" then
				local p = b.Position
				if p and (p - root.Position).Magnitude < 14 then
					local t = (p - o):Dot(dir)
					if t > 0 and t < 14 then
						local d = (p - (o + dir * t)).Magnitude
						if d < bestD then best, bestD = b, d end
					end
				end
			end
		end
		return best
	end
	V.module{
		name = "AutoTool", cat = "World", tip = "Automatically selects the correct tool (approximation: guesses the block you look at while holding left click)",
		step = function()
			if not (isrbxactive() and ismouse1pressed() and V.alive()) then return end
			local b = lookedBlock()
			if not b or b:GetAttribute("NoBreak") then return end
			local tool = toolFor(b.Name)
			if tool then V.equip(tool) end
		end,
	}
end

-- ===== BedProtector =====
do
	local HP = { obsidian = 5, ceramic = 4, stone_brick = 3, plank = 2, wool = 1 }
	local modes = { "Toggle", "On Key" }
	local function hp(n) for k, v in pairs(HP) do if n:find(k) then return v end end return 0 end

	local function getBlocks(m)
		local typeCheck = m.opt("blocktypecheck", true)
		local allowed = { "wool", "stone_brick", "wood_plank_oak", "ceramic", "obsidian" }
		local blocks = {}
		for _, it in ipairs(V.items()) do
			if V.isBlockName(it.itemType) then
				local ok = not typeCheck
				for _, a in ipairs(allowed) do if it.itemType:find(a, 1, true) then ok = true end end
				if ok then blocks[#blocks + 1] = { itemType = it.itemType, health = hp(it.itemType), tool = it.tool } end
			end
		end
		local prio = {}
		for _, e in ipairs(splitList(m.opt("priority", ""))) do
			local b, l = e:match("^(.-)/(%d+)$")
			if b then prio[b:lower()] = tonumber(l) end
		end
		local pri, fall = {}, {}
		for _, b in ipairs(blocks) do
			local layer
			for k, l in pairs(prio) do if b.itemType:lower():find(k, 1, true) then layer = l break end end
			if layer then b.layer = layer; pri[#pri + 1] = b else fall[#fall + 1] = b end
		end
		table.sort(pri, function(a, b) return a.layer < b.layer end)
		table.sort(fall, function(a, b) return a.health > b.health end)
		for _, b in ipairs(fall) do pri[#pri + 1] = b end
		return pri
	end

	local function pyramid(size, grid)
		local out = {}
		for h = size, 0, -1 do
			for w = h, 0, -1 do
				out[#out + 1] = Vector3.new(w, size - h, (h + 1) - w) * grid
				out[#out + 1] = Vector3.new(-w, size - h, (h + 1) - w) * grid
				out[#out + 1] = Vector3.new(w, size - h, (h - w) * -1) * grid
				out[#out + 1] = Vector3.new(-w, size - h, (h - w) * -1) * grid
			end
		end
		return out
	end

	local function place(m, bedPos, b)
		if m.opt("autoswitch", true) then V.equip(b.tool) end
		return V.placeBlock(bedPos, b.itemType)
	end

	V.module{
		name = "BedProtector", cat = "World", tip = "Automatically places strong blocks around the bed with customizable speed.",
		ui = function(m, sec)
			sec:SliderInt(m.id("layers"), "Layers", 1, 10, 2)
			sec:SliderInt(m.id("cps"), "CPS", 5, 50, 50)
			sec:Toggle(m.id("autoswitch"), "Auto Switch", true)
			sec:Combo(m.id("mode"), "Mode", modes, 1)
			sec:Toggle(m.id("handcheck"), "Hand Check", false)
			sec:Toggle(m.id("blocktypecheck"), "Block Type Check", true)
			sec:InputText(m.id("priority"), "Block/Layer (comma list)", "")
		end,
		enable = function(m)
			if modes[m.opt("mode", 1) + 1] == "Toggle" then return end
			local _, bedPos = V.nearBed(20)
			if not bedPos then
				V.notify("Please get closer to your bed!", "BedProtector", 3)
				V.set(m.id("on"), false)
				return
			end
			if m.opt("handcheck", false) and not m.opt("autoswitch", true) then
				local h = V.hand()
				if not (h and V.isBlockName(h.Name)) then
					V.notify("You aren't holding a block!", "BedProtector", 2)
					V.set(m.id("on"), false)
					return
				end
			end
			local blocks = getBlocks(m)
			if #blocks == 0 then
				V.notify("No blocks for bed defense found!", "BedProtector", 3)
				V.set(m.id("on"), false)
				return
			end
			local layers, delay = m.opt("layers", 2), 1 / m.opt("cps", 50)
			V.spawn(function()
				for layer = 1, layers do
					local b = blocks[(layer - 1) % #blocks + 1]
					for _, off in ipairs(pyramid(layer - 1, 3)) do
						if not m.enabled then return end
						if not V.blockAt(bedPos + off) then place(m, bedPos + off, b) end
						task.wait(delay)
					end
				end
				V.set(m.id("on"), false)
			end)
		end,
		step = function(m)
			if modes[m.opt("mode", 1) + 1] ~= "Toggle" then return end
			local now = tick()
			if now - (m.last or 0) < 1.5 then return end
			m.last = now
			local _, bedPos = V.nearBed(12)
			if not bedPos then return end
			local blocks = getBlocks(m)
			if #blocks == 0 then return end
			for _, off in ipairs(pyramid(m.opt("layers", 2) - 1, 3)) do
				if not m.enabled then return end
				if not V.blockAt(bedPos + off) then
					place(m, bedPos + off, blocks[1])
					task.wait(1 / m.opt("cps", 50))
				end
			end
		end,
	}
end

-- ===== ChestSteal =====
do
	local delays = {}
	local function setObserved(chest)
		local r = V.remote("Inventory/SetObservedChest")
		if r then pcall(function() r:FireServer(chest) end) end
	end
	local function loot(folder)
		if not folder then return end
		local items = folder:GetChildren()
		local key = folder.Address
		if #items > 1 and (delays[key] or 0) < tick() then
			delays[key] = tick() + 0.3
			setObserved(folder)
			for _, v in ipairs(items) do
				if v.ClassName == "Accessory" then V.callAsync("Inventory/ChestGetItem", folder, v) end
			end
			setObserved(nil)
		end
	end
	V.module{
		name = "ChestSteal", cat = "World", tip = "Grabs items from near chests. GUI Check loots the chest you have open.",
		ui = function(m, sec)
			sec:SliderInt(m.id("range"), "Range", 0, 18, 18)
			sec:Toggle(m.id("guicheck"), "GUI Check", false)
			sec:Toggle(m.id("skywars"), "Only Skywars", true)
		end,
		step = function(m)
			if not (V.inMatch() and V.alive()) then return end
			local q = tostring(workspace:GetAttribute("QueueType") or "")
			if m.opt("skywars", true) and not q:find("skywars") then return end
			if tick() - (m.last or 0) < 0.9 then return end
			m.last = tick()
			if m.opt("guicheck", false) then
				local ov = V.char():FindFirstChild("ObservedChestFolder")
				loot(ov and ov.Value)
				return
			end
			local pos, range = V.root().Position, m.opt("range", 18)
			for _, c in ipairs(V.chests()) do
				local p = V.posOf(c)
				if p and (pos - p).Magnitude <= range then
					local cv = c:FindFirstChild("ChestFolderValue")
					loot(cv and cv.Value)
				end
			end
		end,
	}
end

-- ===== Schematica =====
do
	local modes = { "Load", "Save" }
	local parts, p1, p2 = {}, nil, nil
	local pool = {}
	local snapYaw = function()
		local lv = V.cam().CFrame.LookVector
		return math.rad(math.round(math.deg(math.atan2(-lv.X, -lv.Z)) / 45) * 45)
	end
	local function rot(x, z, a) return x * math.cos(a) + z * math.sin(a), -x * math.sin(a) + z * math.cos(a) end
	local function key(p) return math.round(p.X / 3) .. "," .. math.round(p.Y / 3) .. "," .. math.round(p.Z / 3) end
	local function below() local r = V.root(); return V.roundPos(Vector3.new(r.Position.X, r.Position.Y - 3.5, r.Position.Z)) end

	local function save(m, file)
		if p1 and p2 then
			local a = snapYaw()
			local lo = Vector3.new(math.min(p1.X, p2.X), math.min(p1.Y, p2.Y), math.min(p1.Z, p2.Z))
			local hi = Vector3.new(math.max(p1.X, p2.X), math.max(p1.Y, p2.Y), math.max(p1.Z, p2.Z))
			local out, n = {}, 0
			for _, b in pairs(V.grid()) do
				if type(b) ~= "boolean" then
					local bp = b.Position
					if bp and bp.X >= lo.X - 1 and bp.X <= hi.X + 1 and bp.Y >= lo.Y - 1 and bp.Y <= hi.Y + 1 and bp.Z >= lo.Z - 1 and bp.Z <= hi.Z + 1 and b:GetAttribute("PlacedByUserId") == V.lp.UserId then
						local rx, rz = rot(bp.X - p1.X, bp.Z - p1.Z, -a)
						n = n + 1
						out[n] = { { x = math.round(rx / 3) * 3, y = math.round((bp.Y - p1.Y) / 3) * 3, z = math.round(rz / 3) * 3 }, b.Name }
					end
				end
			end
			p1, p2 = nil, nil
			writefile(file, V.HttpService:JSONEncode(out))
			V.notify("Saved " .. n .. " blocks", "Schematica", 5)
		elseif V.alive() then
			if p1 then
				p2 = below()
				V.notify("Selected position 2 (block under you), toggle again to save", "Schematica", 3)
			else
				p1 = below()
				V.notify("Selected position 1 (block under you)", "Schematica", 3)
			end
		end
	end

	local function load(m, read)
		local root = V.root()
		local a = snapYaw()
		local fwd = Vector3.new(-math.sin(a), 0, -math.cos(a))
		local base = V.roundPos(Vector3.new(root.Position.X, root.Position.Y - 3.5, root.Position.Z) + fwd * 6)
		parts = {}
		for _, v in ipairs(read) do
			local rx, rz = rot(v[1].x, v[1].z, a)
			local pos = V.roundPos(base + Vector3.new(rx, v[1].y, rz))
			local name = v[2]
			if name:find("wool") then name = (V.getWool() or {}).itemType or name end
			parts[key(pos)] = { pos = pos, name = name }
		end
	end

	V.module{
		name = "Schematica", cat = "World", tip = "Save and load placements of buildings. Save: toggle at pos 1, pos 2, then again (uses the block under you). Load builds in front of you.",
		ui = function(m, sec)
			sec:InputText(m.id("file"), "File (.json)", "schematic.json")
			sec:Combo(m.id("mode"), "Mode", modes, 0)
			sec:SliderFloat(m.id("transparency"), "Transparency", 0, 1, 0.7, "%.1f")
		end,
		enable = function(m)
			local file = m.opt("file", "schematic.json")
			if not file:find(".json", 1, true) then
				V.notify("Invalid file", "Schematica", 3)
				V.set(m.id("on"), false)
				return
			end
			if modes[m.opt("mode", 0) + 1] == "Save" then
				save(m, file)
				V.set(m.id("on"), false)
			else
				local ok, read = pcall(function() return isfile(file) and V.HttpService:JSONDecode(readfile(file)) end)
				if ok and read then
					load(m, read)
					m.total = 0
					for _ in pairs(parts) do m.total = m.total + 1 end
				else
					V.notify("Missing / corrupted file", "Schematica", 3)
					V.set(m.id("on"), false)
				end
			end
		end,
		disable = function(m)
			parts = {}
			for _, d in ipairs(pool) do V.undraw(d) end
			pool = {}
		end,
		render = function(m)
			local root = V.root()
			if not root then return end
			local me, n, alpha = root.Position, 0, math.max(0.05, 1 - m.opt("transparency", 0.7))
			for _, p in pairs(parts) do
				if (p.pos - me).Magnitude < 90 and n < 120 then
					local sp, on = WorldToScreen(p.pos)
					n = n + 1
					local d = pool[n]
					if not d then d = V.draw("Square", { Filled = true }); pool[n] = d end
					if on then
						local s = math.clamp(260 / math.max((p.pos - me).Magnitude, 1), 4, 40)
						d.Size = Vector2.new(s, s)
						d.Position = Vector2.new(sp.X - s / 2, sp.Y - s / 2)
						d.Color = p.name:find("wool") and Color3.new(1, 1, 1) or Color3.new(0.6, 0.8, 1)
						d.Transparency = alpha
						d.Visible = true
					else
						d.Visible = false
					end
				end
			end
			for i = n + 1, #pool do pool[i].Visible = false end
		end,
		step = function(m)
			if not V.alive() then return end
			local me, left = V.root().Position, 0
			local snap = {} -- placeBlock yields; never yield inside pairs over a table others can edit
			for k, p in pairs(parts) do snap[k] = p end
			for k, p in pairs(snap) do
				if V.blockAt(p.pos) then
					parts[k] = nil
				else
					left = left + 1
					if (p.pos - me).Magnitude < 60 and V.checkAdjacent(p.pos) and V.getItem(p.name, true) then
						V.placeBlock(p.pos, p.name)
					end
				end
			end
			if left == 0 and (m.total or 0) > 0 then
				V.notify("Finished building", "Schematica", 5)
				V.set(m.id("on"), false)
			end
		end,
	}
end

-- ===== AutoWhisper =====
do
	local conns = {}
	V.module{
		name = "AutoWhisper", cat = "World", tip = "Automatically uses Whisper Kit's abilities (needs the OwlSummoned remote event to be readable)",
		ui = function(m, sec)
			sec:Toggle(m.id("fly"), "Auto Fly", true)
			sec:Toggle(m.id("heal"), "Auto Heal", true)
		end,
		enable = function(m)
			local r1, r2 = V.remote("OwlSummoned"), V.remote("OwlDeattached")
			if not (r1 and r1.OnClientEvent) then V.notify("OwlSummoned not available", "AutoWhisper", 3) return end
			m.whisper = false
			local ok = pcall(function()
				conns[#conns + 1] = V.connect(r1.OnClientEvent, function(a, b)
					local user, target = a, b
					if type(a) == "table" then user, target = a.user, a.target end
					if user ~= V.lp or not target then return end
					m.whisper = true
					V.spawn(function()
						local lastFly, lastHeal = 0, 0
						while m.whisper and m.enabled do
							local c = target.Character
							local root = c and c:FindFirstChild("HumanoidRootPart")
							if root then
								local vel = root.AssemblyLinearVelocity
								-- Raycast is flaky (nil = treated as clear), so the 100-stud ground check is best-effort
								if m.opt("fly", true) and vel and vel.Y <= -85 and tick() - lastFly > 1 and not workspace:Raycast(root.Position, Vector3.new(0, -100, 0)) then
									lastFly = tick()
									V.call("OwlActionAbilities", { target = target, ability = "OWL_LIFT" })
								end
								local hp, mx = c:GetAttribute("Health"), c:GetAttribute("MaxHealth")
								if m.opt("heal", true) and hp and mx and (mx - hp) >= 20 and tick() - lastHeal > 1 then
									lastHeal = tick()
									V.call("OwlActionAbilities", { target = target, ability = "OWL_HEAL" })
								end
							end
							task.wait(0.05)
						end
					end)
				end)
				if r2 then
					conns[#conns + 1] = V.connect(r2.OnClientEvent, function(a)
						if a == V.lp or (type(a) == "table" and a.user == V.lp) then m.whisper = false end
					end)
				end
			end)
			if not ok then V.notify("Could not listen to owl events on Matcha", "AutoWhisper", 4) end
		end,
		disable = function(m)
			m.whisper = false
			for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
			conns = {}
		end,
	}
end

-- ===== ArmorSwitch =====
do
	local modes = { "Toggle", "On Key" }
	local TIER = { leather = 1, iron = 2, diamond = 3, emerald = 4 }
	local SLOT = { helmet = 0, chestplate = 1, boots = 2 }
	local function bestArmor(slot)
		local best, rank = nil, 0
		for _, it in ipairs(V.items()) do
			for suffix, s in pairs(SLOT) do
				if s == slot and it.itemType:find("_" .. suffix) then
					for t, r in pairs(TIER) do
						if it.itemType:find(t, 1, true) and r > rank then best, rank = it, r end
					end
				end
			end
		end
		return best
	end
	local function worn(slot)
		local v = V.char() and V.char():FindFirstChild("ArmorInvItem_" .. slot)
		return v and v.Value ~= nil
	end
	-- payload {item, armorSlot} mirrors Vape's InventorySetArmorItem action; unverified
	local function setArmor(slot, item)
		V.call("SetArmorInvItem", { item = item and item.tool or nil, armorSlot = slot })
	end
	V.module{
		name = "ArmorSwitch", cat = "Inventory", tip = "Puts on / takes off armor when toggled for baiting.",
		ui = function(m, sec)
			sec:Combo(m.id("mode"), "Mode", modes, 0)
			sec:Toggle(m.id("players"), "Players", true)
			sec:Toggle(m.id("npcs"), "NPCs", true)
			sec:Toggle(m.id("walls"), "Walls", false)
			sec:SliderInt(m.id("range"), "Range", 1, 30, 30)
		end,
		enable = function(m)
			if modes[m.opt("mode", 0) + 1] ~= "On Key" then return end
			V.spawn(function()
				for slot = 0, 2 do
					setArmor(slot, (not worn(slot)) and bestArmor(slot) or nil)
					task.wait(0.1)
				end
			end)
			V.set(m.id("on"), false)
		end,
		step = function(m)
			if modes[m.opt("mode", 0) + 1] ~= "Toggle" or not V.alive() then return end
			local state = V.targets({ range = m.opt("range", 30), players = m.opt("players", true), npcs = m.opt("npcs", true), wallcheck = m.opt("walls", false) }) ~= nil
			for slot = 0, 2 do
				if worn(slot) ~= state and m.enabled then
					setArmor(slot, state and bestArmor(slot) or nil)
					task.wait(0.1)
				end
			end
		end,
	}
end

-- ===== AutoBuy =====
do
	-- {currency, price, amount}. Prices are approximate (only used as an affordability gate; the server prices the purchase).
	local SHOP = {
		wool_white = { "iron", 16, 16 }, stone_sword = { "iron", 70, 1 }, iron_sword = { "gold", 10, 1 }, diamond_sword = { "emerald", 4, 1 }, emerald_sword = { "emerald", 20, 1 },
		wood_dao = { "iron", 20, 1 }, stone_dao = { "iron", 70, 1 }, iron_dao = { "gold", 10, 1 }, diamond_dao = { "emerald", 4, 1 }, emerald_dao = { "emerald", 20, 1 },
		wood_scythe = { "iron", 20, 1 }, stone_scythe = { "iron", 70, 1 }, iron_scythe = { "gold", 10, 1 }, diamond_scythe = { "emerald", 4, 1 }, mythic_scythe = { "emerald", 20, 1 },
		leather_chestplate = { "iron", 20, 1 }, iron_chestplate = { "gold", 12, 1 }, diamond_chestplate = { "emerald", 6, 1 }, emerald_chestplate = { "emerald", 40, 1 },
		wood_axe = { "iron", 10, 1 }, stone_axe = { "iron", 20, 1 }, iron_axe = { "gold", 6, 1 }, diamond_axe = { "emerald", 3, 1 },
		wood_pickaxe = { "iron", 10, 1 }, stone_pickaxe = { "iron", 20, 1 }, iron_pickaxe = { "gold", 6, 1 }, diamond_pickaxe = { "emerald", 3, 1 },
		shield_axolotl = { "emerald", 2, 1 }, damage_axolotl = { "emerald", 2, 1 }, break_speed_axolotl = { "emerald", 2, 1 }, health_regen_axolotl = { "emerald", 2, 1 },
	}
	local ARMORS = { "leather_chestplate", "iron_chestplate", "diamond_chestplate", "emerald_chestplate" }
	local SWORDS = { "wood_sword", "stone_sword", "iron_sword", "diamond_sword", "emerald_sword" }
	local SCYTHES = { "wood_scythe", "stone_scythe", "iron_scythe", "diamond_scythe", "mythic_scythe" }
	local AXES = { "wood_axe", "stone_axe", "iron_axe", "diamond_axe" }
	local PICKS = { "wood_pickaxe", "stone_pickaxe", "iron_pickaxe", "diamond_pickaxe" }
	local AXOLOTLS = { "shield_axolotl", "damage_axolotl", "break_speed_axolotl", "health_regen_axolotl" }
	local AXO_META = { ShieldAxolotl = "shield_axolotl", DamageAxolotl = "damage_axolotl", BreakSpeedAxolotl = "break_speed_axolotl", HealthRegenAxolotl = "health_regen_axolotl" }
	local tried = {}

	local function kit() return tostring(V.lp:GetAttribute("PlayingAsKits") or ""):lower() end
	local function indexOf(list, v) for i, x in ipairs(list) do if x == v then return i end end end
	local function count(cur) local it = V.getItem(cur, true); return it and it.amount or 0 end

	local function shopItem(itemType)
		if itemType == "axe" then
			local a = V.getAxe(); itemType = a and AXES[(indexOf(AXES, a.itemType) or 0) + 1] or "wood_axe"
		elseif itemType == "pickaxe" then
			local p = V.getPickaxe(); itemType = p and PICKS[(indexOf(PICKS, p.itemType) or 0) + 1] or "wood_pickaxe"
		end
		local d = SHOP[itemType]
		if d then return { itemType = itemType, currency = d[1], price = d[2], amount = d[3] } end
		return { itemType = itemType }
	end
	local function afford(s)
		if not s.price then return true end
		return count(s.currency) >= s.price
	end
	local function buy(shopId, s)
		local t = tried[s.itemType]
		if t and tick() - t < 1.5 then return end
		tried[s.itemType] = tick()
		V.call("BedwarsPurchaseItem", { shopItem = s, shopId = shopId })
	end

	local function nearShop(range)
		local root = V.root()
		if not root then return nil end
		for _, s in ipairs(V.scan("shops", function(i)
			local n = i.Name:lower()
			return (n:find("shop") or n:find("upgrade")) and not n:find("enchant") and i.ClassName ~= "Folder"
		end, 5)) do
			local p = V.posOf(s)
			if p and (root.Position - p).Magnitude <= range then return s:GetAttribute("Id") or s.Name end
		end
	end

	local function myAxolotls()
		local out, f = {}, workspace:FindFirstChild("AxolotlModel")
		if not f then return nil end
		for _, v in ipairs(f:GetChildren()) do
			local owner = v:FindFirstChild("AxolotlData")
			if owner and owner.ClassName == "ObjectValue" and owner.Value and tostring(owner.Value) == V.lp.Name .. "_Axolotl" then out[AXO_META[v.Name] or ""] = true end
		end
		return out
	end

	local function buyArmor(id)
		local cp = V.char():FindFirstChild("ArmorInvItem_1")
		local cur = cp and cp.Value and cp.Value.Name or ""
		local want
		if cur == "" then want = ARMORS[1]
		elseif cur:find("leather") then want = ARMORS[2]
		elseif cur:find("iron") then want = ARMORS[3]
		elseif cur:find("diamond") then want = ARMORS[4] end
		if want then local s = shopItem(want); if afford(s) then buy(id, s) end end
	end
	local function buySword(id)
		local list = (kit() == "dasher") and { "wood_dao", "stone_dao", "iron_dao", "diamond_dao", "emerald_dao" } or SWORDS
		local sc = V.getItem("scythe")
		if sc then list = SCYTHES end
		local k = kit()
		if k == "ice_queen" then list = { SWORDS[1], SWORDS[2], SWORDS[3], SWORDS[4], "ice_sword" }
		elseif k == "ember" then list = { SWORDS[1], SWORDS[2], SWORDS[3], SWORDS[4], "infernal_saber" }
		elseif k == "lumen" then list = { SWORDS[1], SWORDS[2], SWORDS[3], SWORDS[4], "light_sword" } end
		local cur
		for _, it in ipairs(V.items()) do
			local i = indexOf(list, it.itemType)
			if i and (not cur or i > cur) then cur = i end
		end
		if not cur then -- holding some other weapon type (kit sword etc): only buy if no sword at all
			local sw = V.getSword()
			if sw then return end
		end
		local want = list[(cur or 0) + 1]
		if want then local s = shopItem(want); if afford(s) then buy(id, s) end end
	end
	local function buyAxolotl(id)
		if kit() ~= "axolotl" then return end
		local have = myAxolotls()
		if not have then return end
		local idx = 0
		for i, n in ipairs(AXOLOTLS) do if have[n] then idx = i end end
		local want = AXOLOTLS[idx + 1]
		if want then local s = shopItem(want); if afford(s) then buy(id, s) end end
	end

	local function runList(m, id, after)
		local entries = splitList(m.opt("buylist", ""))
		local parsed = {}
		for _, e in ipairs(entries) do
			local item, amt, pri, aft = e:match("^([^/]+)/([^/]*)/?([^/]*)/?([^/]*)$")
			if item then parsed[#parsed + 1] = { item = item, amt = tonumber(amt) or 1, pri = tonumber(pri) or 1, after = aft == "true" } end
		end
		table.sort(parsed, function(a, b) return a.pri < b.pri end)
		for _, p in ipairs(parsed) do
			if p.after == after then
				local s = shopItem(p.item)
				local actual = V.getItem(s.itemType == "wool_white" and (V.getWool() or {}).itemType or s.itemType, true)
				if afford(s) and (not actual or actual.amount < p.amt) then buy(id, s) end
			end
		end
	end

	V.module{
		name = "AutoBuy", cat = "Inventory", tip = "Automatically buys swords, armor and your buy list when near a shop NPC.",
		ui = function(m, sec)
			sec:SliderInt(m.id("range"), "Range", 1, 20, 20)
			sec:Toggle(m.id("armor"), "Buy Armor", true)
			sec:Toggle(m.id("sword"), "Buy Sword", true)
			sec:Toggle(m.id("axolotl"), "Buy Axolotl", true)
			sec:InputText(m.id("buylist"), "BuyList item/amount/priority/after (comma list)", "")
		end,
		step = function(m)
			if not (V.inMatch() and V.alive()) then return end
			local id = nearShop(m.opt("range", 20))
			if not id then return end
			runList(m, id, false)
			if m.opt("armor", true) then buyArmor(id) end
			if m.opt("sword", true) then buySword(id) end
			if m.opt("axolotl", true) then buyAxolotl(id) end
			runList(m, id, true)
		end,
	}
end

-- ===== AutoConsume =====
do
	V.module{
		name = "AutoConsume", cat = "Inventory", tip = "Automatically heals for you when health or shield is under threshold.",
		ui = function(m, sec)
			sec:SliderInt(m.id("health"), "Health Percent", 1, 99, 70)
			sec:Toggle(m.id("speed"), "Speed Potions", true)
			sec:Toggle(m.id("apple"), "Apple", true)
			sec:Toggle(m.id("shield"), "Shield Potions", true)
		end,
		step = function(m)
			if not V.alive() then return end
			if tick() - (m.last or 0) < 0.4 then return end
			m.last = tick()
			local c = V.char()
			if m.opt("speed", true) then
				local p = V.getItem("speed_potion")
				if p and not c:GetAttribute("StatusEffect_speed") then V.callAsync("ConsumeItem", { item = p.tool }) end
			end
			if m.opt("apple", true) then
				local hp, mx = c:GetAttribute("Health"), c:GetAttribute("MaxHealth")
				if hp and mx and mx > 0 and hp / mx <= m.opt("health", 70) / 100 then
					local a = V.getItem("orange") or (not c:GetAttribute("StatusEffect_golden_apple") and V.getItem("golden_apple")) or V.getItem("apple")
					if a then V.callAsync("ConsumeItem", { item = a.tool }) end
				end
			end
			if m.opt("shield", true) and (c:GetAttribute("Shield_POTION") or 0) == 0 then
				local s = V.getItem("big_shield") or V.getItem("mini_shield")
				if s then V.callAsync("ConsumeItem", { item = s.tool }) end
			end
		end,
	}
end
-- mods_e: AutoHotbar, FastConsume, FastDrop, BedPlates, Nuker, and the Legit modules (main.lua 9458-12260)
-- Shared helpers (on V to spare chunk locals): V.combo, V.getColor, V.track, V.drops

function V.combo(m, id, items, default)
	local i = m.opt(id, default or 0)
	return items[(i or 0) + 1] or items[1], i
end

-- ColorPicker value -> Color3, alpha (defaults used until the tab has drawn once)
function V.getColor(id, r, g, b, a)
	local c, al = UI.GetValue(id)
	if typeof(c) == "Color3" then return c, al or a end
	return Color3.new(r, g, b), a
end

-- Drawing owned by module m; core removes it when m is disabled
function V.track(m, class, props)
	local d = V.draw(class, props)
	m.cleanup = m.cleanup or {}
	m.cleanup[#m.cleanup + 1] = d
	return d
end


-- Health drops of tracked entities since the consumer last asked: { {e=, pos=, amount=, t=} }
-- ponytail: sampled from V.entities (4 Hz), so rapid hits merge into one drop.
function V.drops(consumer)
	local st = V._drops
	if not st then st = { last = {}, log = {}, seq = 0, cur = {}, t = 0 }; V._drops = st end
	local now = tick()
	if now - st.t > 0.05 then
		st.t = now
		for _, e in ipairs(V.entities) do
			local prev = st.last[e.Id]
			if prev and e.Health < prev - 0.4 then
				local p = e.RootPart.Position
				if p then
					st.seq = st.seq + 1
					st.log[#st.log + 1] = { seq = st.seq, e = e, pos = p, amount = prev - e.Health, t = now }
				end
			end
			st.last[e.Id] = e.Health
		end
		while st.log[1] and now - st.log[1].t > 3 do table.remove(st.log, 1) end
	end
	local from, out = st.cur[consumer] or st.seq, {}
	for _, d in ipairs(st.log) do if d.seq > from then out[#out + 1] = d end end
	st.cur[consumer] = st.seq
	return out
end

-- ===== AutoHotbar =====
-- The real hotbar order is client-only Store state (no remote), so it can't be rearranged. Instead each digit key
-- is remapped: after the game's own slot select, the item for that slot's category is equipped via SetInvItem.
do
	local CATS = { "None", "Sword", "Pickaxe", "Axe", "Blocks", "Bow", "Shears", "Fireball", "Apple", "Iron", "Gold", "Diamond", "Emerald", "TNT", "Pearl" }
	local function resolve(cat)
		if cat == "Sword" then return V.getSword()
		elseif cat == "Pickaxe" then return V.getPickaxe()
		elseif cat == "Axe" then return V.getAxe()
		elseif cat == "Blocks" then return V.getWool()
		elseif cat == "Bow" then return V.getBow()
		elseif cat == "Shears" then return V.getItem("shears")
		elseif cat == "Fireball" then return V.getItem("fireball")
		elseif cat == "Apple" then return V.getItem("apple")
		elseif cat == "TNT" then return V.getItem("tnt", true)
		elseif cat == "Pearl" then return V.getItem("telepearl")
		elseif cat ~= "None" then return V.getItem(cat:lower(), true) end
	end
	V.module{
		name = "AutoHotbar", cat = "Inventory",
		tip = "Digit keys equip the chosen category (hotbar itself can't be reordered on Matcha)",
		ui = function(m, sec)
			for i = 1, 9 do sec:Combo(m.id("slot" .. i), "Slot " .. i, CATS, 0) end
		end,
		enable = function(m) m.prev, m.pend = {}, nil end,
		render = function(m)
			if not isrbxactive() then return end
			for i = 1, 9 do
				local dn = iskeypressed(0x30 + i)
				if dn and not m.prev[i] then m.pend, m.pendT = i, tick() + 0.06 end
				m.prev[i] = dn
			end
		end,
		step = function(m)
			if not (m.pend and tick() >= m.pendT) then return end
			local i = m.pend
			m.pend = nil
			local cat = V.combo(m, "slot" .. i, CATS, 0)
			local it = resolve(cat)
			if it then V.equip(it) end
		end,
	}
end

-- ===== FastConsume =====
-- ConsumeItem {item=tool} is sent once the use button has been held for 1.6s * Multiplier/40 (1.6s = assumed base hold time).
do
	local EDIBLE = { "apple", "potion", "pie", "juice", "cookie", "soup", "cake", "steak", "carrot", "bread", "heal", "drink" }
	V.module{
		name = "FastConsume", cat = "Inventory", tip = "Use/Consume items quicker",
		ui = function(m, sec) sec:SliderInt(m.id("mult"), "Multiplier", 0, 100, 20) end,
		step = function(m)
			local held = V.hand()
			if not (held and (ismouse1pressed() or ismouse2pressed()) and isrbxactive()) then m.t0, m.fired = nil, false; return end
			local n, ok = held.Name:lower(), false
			for _, p in ipairs(EDIBLE) do if n:find(p) then ok = true break end end
			if not ok then m.t0 = nil; return end
			m.t0 = m.t0 or tick()
			if not m.fired and tick() - m.t0 >= 1.6 * m.opt("mult", 20) / 40 then
				m.fired = true
				V.call("ConsumeItem", { item = held })
			end
		end,
	}
end

-- ===== FastDrop =====
do
	V.module{
		name = "FastDrop", cat = "Inventory", tip = "Hold H or Backspace to drop the held item fast (also triggers while typing in chat!)",
		step = function(m)
			if not (V.alive() and isrbxactive() and (iskeypressed(0x48) or iskeypressed(0x08))) then return end
			local h = V.hand()
			if h then V.call("DropItem", { item = h, amount = 1 }) end
		end,
	}
end

-- ===== BedPlates =====
-- Beds come from the block grid (V.grid()), not CollectionService. Layers are drawn as a text line over each bed.
do
	local DIRS = { Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 1, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) }
	local beds, lastGrid, lastScan = {}, nil, 0
	local function scanSide(bedAddr, start, list)
		for _, d in ipairs(DIRS) do
			for i = 1, 15 do
				local b = V.blockAt(start + d * (3 * i))
				if not b then break end
				if b ~= true then
					if b.Address == bedAddr then break end
					if not b:GetAttribute("NoBreak") then
						local n = b.Name:gsub("_block", "")
						if not list[n] then list[n] = true; list[#list + 1] = n end
					end
				end
			end
		end
	end
	local function scan(m)
		local seen = {}
		for _, b in pairs(V.grid()) do
			if b ~= true and b.Name == "bed" then
				local id = b.Address
				local list = {}
				scanSide(id, b.Position, list)
				scanSide(id, b.Position + Vector3.new(0, 0, 3), list)
				local e = beds[id]
				if not e then
					e = { bg = V.track(m, "Square", { Filled = true }), tx = V.track(m, "Text", { Center = true, Outline = true, Size = 13, Color = Color3.new(1, 1, 1) }) }
					beds[id] = e
				end
				e.part, e.text = b, table.concat(list, "  ")
				seen[id] = true
			end
		end
		for id, e in pairs(beds) do
			if not seen[id] then V.undraw(e.bg); V.undraw(e.tx); beds[id] = nil end
		end
	end
	V.module{
		name = "BedPlates", cat = "Minigames", tip = "Displays blocks over the bed",
		ui = function(m, sec)
			sec:Toggle(m.id("bg"), "Background", true)
			sec:ColorPicker(m.id("bgcol"), 1, 0, 0, 0.5)
		end,
		enable = function(m) beds, lastGrid, lastScan = {}, nil, 0 end,
		disable = function(m) beds = {} end,
		step = function(m)
			if lastGrid ~= V.grid() or tick() - lastScan > 3 then
				lastGrid, lastScan = V.grid(), tick()
				scan(m)
			end
		end,
		render = function(m)
			local bgOn = m.opt("bg", true)
			local col, alpha = V.getColor(m.id("bgcol"), 1, 0, 0, 0.5)
			for _, e in pairs(beds) do
				local p = e.part.Position
				local sp, on = nil, false
				if p and e.text ~= "" then sp, on = WorldToScreen(p + Vector3.new(0, 3, 0)) end
				if on then
					local w = #e.text * 6.5 + 10
					e.tx.Text, e.tx.Position = e.text, Vector2.new(sp.X, sp.Y - 8)
					e.bg.Size, e.bg.Position = Vector2.new(w, 22), Vector2.new(sp.X - w / 2, sp.Y - 11)
					e.bg.Color, e.bg.Transparency = col, alpha or 0.5
					e.bg.Visible, e.tx.Visible = bgOn, true
				else
					e.bg.Visible, e.tx.Visible = false, false
				end
			end
		end,
	}
end

-- ===== Nuker =====
-- Ported from the second (commented-out in main.lua) definition: break range / rate / custom list / bed, lucky, iron toggles,
-- self break, limit to tools. Path search follows calculatePath (cheapest exposed block, cost = block Health attr).
-- Healthbar/animation/instant-break dropped (client Roact/animation only).
do
	local DIRS = { Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 1, 0), Vector3.new(0, -1, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) }
	local PRIO = { bed = 1, custom = 2, lucky = 3, iron = 4 }
	local lastGrid, targets, cd = nil, {}, 0
	local function gk(c) return c.X .. "," .. c.Y .. "," .. c.Z end
	local function blk(c) return V.blockAt(c * 3) end
	local function hits(b)
		if b == true then return 3 end
		local h = b:GetAttribute("Health")
		return type(h) == "number" and h or 3
	end
	local function nobreak(b) return b ~= true and b:GetAttribute("NoBreak") end
	local function names(str)
		local s = {}
		for n in tostring(str or ""):gmatch("[^,%s]+") do s[n:lower()] = true end
		return s
	end
	local function findBreak(tpos)
		local start = V.blockPos(tpos)
		local dist, seen, open, best, bestCost = { [gk(start)] = 0 }, {}, { { 0, start } }, nil, math.huge
		local n = 0
		while #open > 0 and n < 400 do
			n = n + 1
			local bi = 1
			for i = 2, #open do if open[i][1] < open[bi][1] then bi = i end end
			local cost, c = open[bi][1], open[bi][2]
			table.remove(open, bi)
			local k = gk(c)
			if not seen[k] then
				seen[k] = true
				if cost >= bestCost then break end
				for _, d in ipairs(DIRS) do
					local nc = c + d
					local b = blk(nc)
					if not b then
						best, bestCost = c, cost
					elseif not nobreak(b) then
						local nk = gk(nc)
						local nd = cost + hits(b)
						if nd < (dist[nk] or math.huge) then dist[nk] = nd; open[#open + 1] = { nd, nc } end
					end
				end
			end
		end
		return best
	end
	local function toolFor(name)
		if name:find("wool") or name == "bed" then return V.getItem("shears") or V.getPickaxe() end
		if name:find("wood") or name:find("plank") or name:find("log") then return V.getAxe() or V.getPickaxe() end
		return V.getPickaxe() or V.getAxe()
	end
	local function serverNow()
		local ok, t = pcall(function() return workspace:GetServerTimeNow() end)
		return ok and type(t) == "number" and t or 0
	end
	V.module{
		name = "Nuker", cat = "Minigames", tip = "Break blocks around you automatically",
		ui = function(m, sec)
			sec:SliderInt(m.id("range"), "Break range", 1, 30, 30)
			sec:SliderInt(m.id("rate"), "Update rate (hz)", 1, 20, 4)
			sec:InputText(m.id("custom"), "Custom blocks (comma list)", "")
			sec:Toggle(m.id("bed"), "Break Bed", true)
			sec:Toggle(m.id("lucky"), "Break Lucky Block", true)
			sec:Toggle(m.id("iron"), "Break Iron Ore", true)
			sec:Toggle(m.id("self"), "Self Break", false)
			sec:Toggle(m.id("limit"), "Limit to items", false)
			sec:Tip("Limit: only breaks while holding a tool")
		end,
		enable = function(m) lastGrid, targets, cd = nil, {}, 0 end,
		step = function(m)
			if tick() < cd or not V.alive() then return end
			if lastGrid ~= V.grid() then
				lastGrid, targets = V.grid(), {}
				local custom = names(m.opt("custom", ""))
				for _, b in pairs(lastGrid) do
					if b ~= true then
						local n = b.Name
						local kind = (n == "bed" and "bed") or (custom[n:lower()] and "custom") or (n:find("lucky") and "lucky") or (n == "iron_ore" and "iron")
						if kind then targets[#targets + 1] = { part = b, kind = kind } end
					end
				end
			end
			if m.opt("limit", false) then
				local h = V.handName()
				if not (h:find("pickaxe") or h:find("axe") or h:find("shears")) then return end
			end
			local on = { bed = m.opt("bed", true), lucky = m.opt("lucky", true), iron = m.opt("iron", true), custom = true }
			local selfBreak, range, me = m.opt("self", false), m.opt("range", 30), V.root().Position
			local myTeam, now = tostring(V.lp:GetAttribute("Team")), serverNow()
			local best, bp, bd
			for _, t in ipairs(targets) do
				local p = on[t.kind] and t.part.Position
				if p then
					local d = (p - me).Magnitude
					local ok = d <= range
					if ok and t.kind == "bed" then
						local team = t.part:GetAttribute("TeamId")
						if team ~= nil and tostring(team) == myTeam then ok = false end
						local sh = t.part:GetAttribute("BedShieldEndTime")
						if type(sh) == "number" and sh > now then ok = false end
					end
					if ok and not selfBreak and t.part:GetAttribute("PlacedByUserId") == V.lp.UserId then ok = false end
					if ok and (not best or PRIO[t.kind] < PRIO[best.kind] or (PRIO[t.kind] == PRIO[best.kind] and d < bd)) then
						best, bp, bd = t, p, d
					end
				end
			end
			if not best then return end
			local cell = findBreak(bp)
			if not cell then return end
			local b = blk(cell)
			local tool = toolFor(b ~= true and b.Name or best.part.Name)
			if tool then V.equip(tool) end
			cd = tick() + 1 / m.opt("rate", 4)
			local ok = V.hitBlock(cell * 3)
			if not ok then cd = tick() + 0.6 end
		end,
	}
end

-- ===== Legit =====

-- Crosshair: Drawing cross instead of a custom viewmodel image
do
	V.module{
		name = "Crosshair", cat = "Legit", tip = "Drawn crosshair (image ids need raw image bytes, not supported)",
		ui = function(m, sec)
			sec:SliderInt(m.id("len"), "Length", 1, 30, 8)
			sec:SliderInt(m.id("gap"), "Gap", 0, 20, 4)
			sec:SliderInt(m.id("thick"), "Thickness", 1, 5, 2)
			sec:Toggle(m.id("dot"), "Center dot", false)
			sec:ColorPicker(m.id("col"), 1, 1, 1, 1)
		end,
		disable = function(m) m.d = nil end,
		render = function(m)
			if not m.d then
				m.d = {}
				for i = 1, 4 do m.d[i] = V.track(m, "Line", {}) end
				m.d.dot = V.track(m, "Square", { Filled = true })
			end
			local vp = V.cam().ViewportSize
			local cx, cy = vp.X / 2, vp.Y / 2
			local len, gap, th = m.opt("len", 8), m.opt("gap", 4), m.opt("thick", 2)
			local col, a = V.getColor(m.id("col"), 1, 1, 1, 1)
			local segs = {
				{ cx - gap - len, cy, cx - gap, cy }, { cx + gap, cy, cx + gap + len, cy },
				{ cx, cy - gap - len, cx, cy - gap }, { cx, cy + gap, cx, cy + gap + len },
			}
			for i, s in ipairs(segs) do
				local l = m.d[i]
				l.From, l.To, l.Thickness, l.Color, l.Transparency, l.Visible = Vector2.new(s[1], s[2]), Vector2.new(s[3], s[4]), th, col, a or 1, true
			end
			local dot = m.d.dot
			dot.Size, dot.Position, dot.Color, dot.Transparency = Vector2.new(th, th), Vector2.new(cx - th / 2, cy - th / 2), col, a or 1
			dot.Visible = m.opt("dot", false)
		end,
	}
end

-- Damage Indicator: floating Drawing text where enemy health dropped
do
	local FONTS = { "System", "SystemBold", "UI", "Monospace", "Minecraft", "Pixel", "Fortnite", "ProximaSoftBold" }
	local items = {}
	V.module{
		name = "Damage Indicator", cat = "Legit", tip = "Floating damage numbers (Drawing)",
		ui = function(m, sec)
			sec:Combo(m.id("font"), "Font", FONTS, 0)
			sec:SliderInt(m.id("size"), "Size", 8, 32, 18)
			sec:SliderFloat(m.id("anchor"), "Anchor (extra seconds)", 0, 1, 0, "%.1f")
			sec:Toggle(m.id("stroke"), "Stroke", true)
			sec:Toggle(m.id("tint"), "Custom color", true)
			sec:ColorPicker(m.id("col"), 1, 0.2, 0.2, 1)
		end,
		enable = function(m) items = {} end,
		disable = function(m) items = {} end,
		render = function(m)
			local now = tick()
			local fontName = V.combo(m, "font", FONTS, 0)
			local size, stroke = m.opt("size", 18), m.opt("stroke", true)
			local col = m.opt("tint", true) and V.getColor(m.id("col"), 1, 0.2, 0.2, 1) or Color3.new(1, 1, 1)
			local life = 0.8 + m.opt("anchor", 0)
			for _, d in ipairs(V.drops("damageindicator")) do
				local t = V.track(m, "Text", { Center = true })
				items[#items + 1] = { t = t, pos = d.pos + Vector3.new(0, 3, 0), born = now, text = tostring(math.floor(d.amount + 0.5)) }
			end
			for i = #items, 1, -1 do
				local it = items[i]
				local age = now - it.born
				if age > life then
					V.undraw(it.t)
					table.remove(items, i)
				else
					local sp, on = WorldToScreen(it.pos + Vector3.new(0, age * 2, 0))
					local t = it.t
					if on then
						t.Text, t.Size, t.Color, t.Outline = it.text, size, col, stroke
						pcall(function() t.Font = Drawing.Fonts[fontName] end)
						t.Position, t.Transparency, t.Visible = Vector2.new(sp.X, sp.Y), 1 - age / life, true
					else
						t.Visible = false
					end
				end
			end
		end,
	}
end

-- FOV
do
	V.module{
		name = "FOV", cat = "Legit", tip = "Adjusts camera vision",
		ui = function(m, sec) sec:SliderInt(m.id("fov"), "FOV", 30, 120, 90) end,
		enable = function(m) m.old = V.cam().FieldOfView end,
		disable = function(m) if m.old then V.cam().FieldOfView = m.old end m.old = nil end,
		render = function(m)
			local cam, v = V.cam(), m.opt("fov", 90)
			if math.abs(cam.FieldOfView - v) > 0.01 then cam.FieldOfView = v end
		end,
	}
end

-- Hit Color: Drawing flash over an enemy that just lost health (the game's _DamageHighlight_ Highlight isn't reachable)
do
	local flashes = {}
	V.module{
		name = "Hit Color", cat = "Legit", tip = "Colored flash over damaged enemies (Drawing)",
		ui = function(m, sec)
			sec:Toggle(m.id("tint"), "Color", true)
			sec:ColorPicker(m.id("col"), 1, 0, 0, 0.4)
		end,
		enable = function(m) flashes = {} end,
		disable = function(m) flashes = {} end,
		render = function(m)
			local now = tick()
			local col, alpha = V.getColor(m.id("col"), 1, 0, 0, 0.4)
			for _, d in ipairs(V.drops("hitcolor")) do
				flashes[#flashes + 1] = { sq = V.track(m, "Square", { Filled = true }), pos = d.pos, born = now }
			end
			for i = #flashes, 1, -1 do
				local f = flashes[i]
				local age = now - f.born
				if age > 0.3 then
					V.undraw(f.sq)
					table.remove(flashes, i)
				else
					local top, on1 = WorldToScreen(f.pos + Vector3.new(0, 3, 0))
					local bot, on2 = WorldToScreen(f.pos - Vector3.new(0, 3, 0))
					if on1 and on2 then
						local h = math.abs(bot.Y - top.Y)
						f.sq.Size, f.sq.Position = Vector2.new(h * 0.5, h), Vector2.new(top.X - h * 0.25, top.Y)
						f.sq.Color, f.sq.Transparency, f.sq.Visible = col, (alpha or 0.4) * (1 - age / 0.3), true
					else
						f.sq.Visible = false
					end
				end
			end
		end,
	}
end

-- Kill Effect: only sets the lp KillEffectType attribute (Bedwars effect ids; KillEffectMeta is unreachable, so type the id).
-- The custom Gravity/Lightning/Delete effects need Instance.new / BreakJoints and are dropped.
do
	V.module{
		name = "Kill Effect", cat = "Legit", tip = "Sets KillEffectType to a Bedwars effect id (custom Gravity/Lightning/Delete not supported)",
		ui = function(m, sec) sec:InputText(m.id("effect"), "Effect id", "") end,
		enable = function(m)
			m.oldKE = V.lp:GetAttribute("KillEffectType")
			local id = m.opt("effect", "")
			if id ~= "" then V.lp:SetAttribute("KillEffectType", id) end
			m.applied = id
		end,
		step = function(m)
			local id = m.opt("effect", "")
			if id ~= m.applied then m.applied = id; if id ~= "" then V.lp:SetAttribute("KillEffectType", id) end end
		end,
		disable = function(m) V.lp:SetAttribute("KillEffectType", m.oldKE or "default") end,
	}
end

-- Reach Display: needs V.attackReach (studs) and V.attackReachUpdate (tick() until which it is fresh), set by Killaura
do
	V.module{
		name = "Reach Display", cat = "Legit", tip = "Shows last attack reach (needs Killaura to set V.attackReach)",
		ui = function(m, sec)
			sec:SliderInt(m.id("x"), "X (% of screen)", 0, 100, 50)
			sec:SliderInt(m.id("y"), "Y (% of screen)", 0, 100, 75)
			sec:Toggle(m.id("bg"), "Background", true)
			sec:ColorPicker(m.id("col"), 0, 0, 0, 0.5)
		end,
		disable = function(m) m.d = nil end,
		render = function(m)
			if not m.d then m.d = { bg = V.track(m, "Square", { Filled = true }), tx = V.track(m, "Text", { Center = true, Outline = true, Size = 15, Color = Color3.new(1, 1, 1) }) } end
			local vp = V.cam().ViewportSize
			local x, y = vp.X * m.opt("x", 50) / 100, vp.Y * m.opt("y", 75) / 100
			local col, a = V.getColor(m.id("col"), 0, 0, 0, 0.5)
			local fresh = (V.attackReachUpdate or 0) > tick()
			m.d.tx.Text = (fresh and string.format("%.2f", V.attackReach or 0) or "0.00") .. " studs"
			m.d.tx.Position = Vector2.new(x, y - 8)
			m.d.tx.Visible = true
			m.d.bg.Size, m.d.bg.Position = Vector2.new(100, 41), Vector2.new(x - 50, y - 20)
			m.d.bg.Color, m.d.bg.Transparency = col, a or 0.5
			m.d.bg.Visible = m.opt("bg", true)
		end,
	}
end

-- Viewmodel: depth/horizontal/vertical via the ConstantManager_* attributes on the viewmodel-controller script.
-- Rotation X/Y/Z (RightWrist.C1) and No Bobbing (animation hook) are not possible. May need a re-equip to refresh.
do
	local function ctl()
		local n = V.lp:FindFirstChild("PlayerScripts")
		for _, k in ipairs({ "TS", "controllers", "global", "viewmodel", "viewmodel-controller" }) do n = n and n:FindFirstChild(k) end
		return n
	end
	local function apply(m, d, h, v)
		local c = ctl()
		if not c then return end
		c:SetAttribute("ConstantManager_DEPTH_OFFSET", -d)
		c:SetAttribute("ConstantManager_HORIZONTAL_OFFSET", h)
		c:SetAttribute("ConstantManager_VERTICAL_OFFSET", v)
	end
	V.module{
		name = "Viewmodel", cat = "Legit", tip = "Changes the viewmodel position (rotation / no-bob not supported)",
		ui = function(m, sec)
			sec:SliderFloat(m.id("depth"), "Depth", 0, 2, 0.8, "%.1f")
			sec:SliderFloat(m.id("horiz"), "Horizontal", 0, 2, 0.8, "%.1f")
			sec:SliderFloat(m.id("vert"), "Vertical", -0.2, 2, -0.2, "%.1f")
		end,
		enable = function(m) m.last = nil end,
		step = function(m)
			local d, h, v = m.opt("depth", 0.8), m.opt("horiz", 0.8), m.opt("vert", -0.2)
			local k = d .. "|" .. h .. "|" .. v
			if k ~= m.last then m.last = k; apply(m, d, h, v) end
		end,
		disable = function(m) apply(m, 0, 0, 0) end,
	}
end

-- ===== AutoBank =====
-- Deposits resources into the personal chest (Inventory/ChestGiveItem(chest, tool)); withdraws when near a personal chest part.
-- Chest parts were found through the 'personal-chest' tag; here they are located by name ("personal") in workspace / Map children.
do
	local RES = { "iron", "gold", "diamond", "emerald", "void_crystal" }
	local chests, chestScan = {}, 0
	local function findChests()
		chests, chestScan = {}, tick()
		local function check(list)
			for _, o in ipairs(list) do
				if o.Name:lower():find("personal") and o.Position then chests[#chests + 1] = o end
			end
		end
		pcall(check, V.chests(true))
	end
	local function nearChest()
		local root = V.root()
		if not root then return false end
		for _, c in ipairs(chests) do
			local p = c.Position
			if p and (p - root.Position).Magnitude < 20 then return true end
		end
		return false
	end
	local function run(m)
		local inv = V.RS:FindFirstChild("Inventories")
		local chest = inv and inv:FindFirstChild(V.lp.Name .. "_personal")
		if not chest then return end
		if tick() - chestScan > 10 then findChests() end
		local mapCF = workspace:FindFirstChild("MapCFrames")
		mapCF = mapCF and mapCF:FindFirstChild((V.lp:GetAttribute("Team") or 1) .. "_spawn")
		local wanted = {}
		for _, n in ipairs(RES) do wanted[n] = true end
		if mapCF and nearChest() then
			for _, it in ipairs(chest:GetChildren()) do
				if wanted[it.Name] then V.callAsync("Inventory/ChestGetItem", chest, it) end
			end
		else
			for _, it in ipairs(V.items()) do
				if wanted[it.itemType] then V.callAsync("Inventory/ChestGiveItem", chest, it.tool) end
			end
		end
	end
	V.module{
		name = "AutoBank", cat = "Inventory", tip = "Automatically puts resources in ender chest",
		ui = function(m, sec)
			sec:Combo(m.id("mode"), "Activation", { "On Key", "Toggle" }, 0)
			sec:Toggle(m.id("ui"), "UI", true)
		end,
		enable = function(m)
			chestScan = 0
			m.oneShot = V.combo(m, "mode", { "On Key", "Toggle" }, 0) == "On Key"
		end,
		step = function(m)
			if V.inMatch() then run(m) end
			if m.oneShot then
				m.oneShot = false
				V.notify(nearChest() and "Withdrew from personal chest" or "Stored loot in personal chest", "AutoBank", 3)
				V.set(m.id("on"), false)
				return
			end
			wait(0.1)
		end,
		render = function(m)
			if not m.tx then m.tx = V.track(m, "Text", { Center = true, Outline = true, Size = 14, Color = Color3.new(1, 1, 1) }) end
			if not m.opt("ui", true) then m.tx.Visible = false; return end
			local inv = V.RS:FindFirstChild("Inventories")
			local chest = inv and inv:FindFirstChild(V.lp.Name .. "_personal")
			local parts = {}
			if chest then
				for _, n in ipairs(RES) do
					local it = chest:FindFirstChild(n)
					if it then parts[#parts + 1] = n .. " " .. tostring(it:GetAttribute("Amount") or 0) end
				end
			end
			local vp = V.cam().ViewportSize
			m.tx.Text, m.tx.Position, m.tx.Visible = table.concat(parts, "   "), Vector2.new(vp.X / 2, vp.Y - 120), #parts > 0
		end,
		disable = function(m) m.tx = nil end,
	}
end
-- boot: build the UI tabs and start the loops
V.boot()
