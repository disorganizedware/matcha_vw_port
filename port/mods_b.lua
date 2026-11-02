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

	-- ===== AutoCharge =====
	-- Commented out in the Vape source too; it patched SwordController.sendServerRequest.
	V.module{
		name = "AutoCharge", cat = "Combat",
		tip = "Not supported on Matcha: patches SwordController internals (no hooking). Killaura already sends chargeRatio 0 hits.",
	}

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
				task.spawn(function() local ok, e = pcall(run, m); if not ok then warn("[Vape] LongJump: " .. tostring(e)) end end)
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
				task.spawn(function()
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
