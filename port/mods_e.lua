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
-- Beds come from the block grid (V.blockGrid), not CollectionService. Layers are drawn as a text line over each bed.
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
		for _, b in pairs(V.blockGrid) do
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
			if lastGrid ~= V.blockGrid or tick() - lastScan > 3 then
				lastGrid, lastScan = V.blockGrid, tick()
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
			if lastGrid ~= V.blockGrid then
				lastGrid, targets = V.blockGrid, {}
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
