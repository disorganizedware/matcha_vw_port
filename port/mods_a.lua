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
					task.spawn(function() V.placeBlock(place, name) end)
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
				task.spawn(function() V.hitBlock(hit) end)
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
