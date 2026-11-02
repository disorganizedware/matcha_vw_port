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
						task.spawn(function()
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
					task.spawn(function()
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
		task.spawn(function()
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
		task.spawn(function()
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
