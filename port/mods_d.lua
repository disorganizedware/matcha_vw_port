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
		for _, b in pairs(V.blockGrid) do
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
						task.spawn(function() V.placeBlock(at, name) end)
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
			task.spawn(function() if _G.VapeStop then _G.VapeStop() end end)
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
		for _, b in pairs(V.blockGrid) do
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
			task.spawn(function()
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
			for _, b in pairs(V.blockGrid) do
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
			for k, p in pairs(parts) do
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
				conns[#conns + 1] = r1.OnClientEvent:Connect(function(a, b)
					local user, target = a, b
					if type(a) == "table" then user, target = a.user, a.target end
					if user ~= V.lp or not target then return end
					m.whisper = true
					task.spawn(function()
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
					conns[#conns + 1] = r2.OnClientEvent:Connect(function(a)
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
			task.spawn(function()
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
