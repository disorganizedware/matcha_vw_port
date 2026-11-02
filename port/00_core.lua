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
function V.connect(signal, fn) local c = signal:Connect(fn); V.conns[#V.conns + 1] = c; return c end

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
	local args = { ... }
	task.spawn(function() V.call(name, unpack(args)) end)
end

-- ===== UI value access (UI.GetValue is nil until the tab drew once) =====
-- Values are cached and the cache is dropped every scheduler tick (~13/s), so render code can read options
-- every frame without a Matcha UI call each time.
local NIL = {}
local vals = {}
V._vals = vals
function V.get(id, default)
	local v = vals[id]
	if v == nil then
		v = UI.GetValue(id)
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
	V.blockGrid = g
end
function V.needBlocks() return tick() - V._blockUse < 10 or next(V.blockGrid) == nil end
-- block lookups mark the grid as in use; the scheduler only re-indexes the map while that's recent
V._blockUse = 0
function V.grid() V._blockUse = tick(); return V.blockGrid end
function V.blockAt(pos) V._blockUse = tick(); return V.blockGrid[key(pos)] end
function V.blockPos(pos) return Vector3.new(math.round(pos.X / 3), math.round(pos.Y / 3), math.round(pos.Z / 3)) end -- block-engine grid coords
function V.markPlaced(worldPos, part) V.blockGrid[key(worldPos)] = part or true end

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
	local b = V.blockGrid[k]
	if b and (b == true or not b.Parent) then V.blockGrid[k] = nil end
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

-- ===== boot (called at the end of the concatenated file) =====
function V.boot()
	for _, cat in ipairs(V.CATEGORIES) do
		local list = V.cats[cat]
		if list then
			UI.AddTab("Vape " .. cat, function(tab)
				for i, m in ipairs(list) do
					local sec = tab:Section(m.name, i % 2 == 1 and "Left" or "Right")
					sec:Toggle(m.id("on"), "Enabled", false)
					m.kbw = sec:Keybind(m.id("kb"), m.key or 0, "toggle")
					if m.tip then sec:Tip(m.tip) end
					if m.ui then safe(m, m.ui, sec) end
				end
			end)
		end
	end
	UI.AddTab("Vape", function(tab)
		local s = tab:Section("Friends & Targets", "Left")
		s:Toggle("vape_friends_on", "Use friends", true)
		s:InputText("vape_friends", "Friends (comma list)", "")
		s:InputText("vape_targets", "Priority targets", "")
		local s2 = tab:Section("Session", "Right")
		s2:Text("Vape for Matcha")
		s2:Button("Uninject", function() task.spawn(_G.VapeStop) end)
	end)

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

	task.spawn(function()
		local n = 0
		while V.running do
			for k in pairs(vals) do vals[k] = nil end
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
					task.spawn(function() safe(m, m.step); m._busy = false end)
				end
			end
			task.wait(0.05)
		end
	end)
	V.notify("Loaded " .. #V.mods .. " modules", "Vape", 4)
end

_G.VapeStop = function()
	V.running = false
	for _, m in ipairs(V.mods) do if m.enabled then m.enabled = false; safe(m, m.disable) end end
	for _, c in ipairs(V.conns) do pcall(function() c:Disconnect() end) end
	for d in pairs(V.drawings) do pcall(function() d:Remove() end) end
	V.drawings = {}
	for _, cat in ipairs(V.CATEGORIES) do pcall(UI.RemoveTab, "Vape " .. cat) end
	pcall(UI.RemoveTab, "Vape")
	_G.VapeStop, _G.Vape = nil, nil
end
