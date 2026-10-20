-- Exercise logic: what counts as done, and what it is worth.
--
-- Each exercise is evaluated from a 1 Hz sample of the aircraft
-- (see main.lua), so nothing here needs DCS events except kills.

local Exercises = {}
Exercises.__index = Exercises

-- Modules resolve through _G.HTG_PRELOADED when the shipping build has
-- pre-assembled them, and from disk otherwise. The dev-only branch is stripped
-- by build/pack-helicopter-training-miz.ps1.
local function load_relative(name)
  local preloaded = rawget(_G, "HTG_PRELOADED")
  if preloaded and preloaded[name] then
    return preloaded[name]
  end
  -- HTG:DEV-ONLY-BEGIN
  local root = rawget(_G, "MY_SCRIPTS_ROOT") or ""
  local chunk = loadfile(root .. "missions/helicopter-training/" .. name)
  assert(chunk, "cannot load " .. name)
  return chunk()
  -- HTG:DEV-ONLY-END
end

local Geo
local function geo()
  if not Geo then
    Geo = load_relative("geo.lua")
  end
  return Geo
end

--- Pads that count as landing drills: config key, exercise id, label.
local LANDING_SITES = {
  { site = "pad_alpha", exercise = "land_alpha", label = "Landing: Pad Alpha" },
  { site = "pad_bravo", exercise = "land_bravo", label = "Landing: Pad Bravo (confined)" },
  { site = "pad_charlie", exercise = "land_charlie", label = "Landing: Pad Charlie" },
  { site = "hill_north", exercise = "land_ridge", label = "Landing: Ridge pad" },
  { site = "hill_east", exercise = "land_hill", label = "Landing: Hill pad" },
  { site = "auto_pad", exercise = "land_auto_pad", label = "Landing: Autorotation pad" },
}

local EXERCISES = {
  { id = "sling", label = "External load", metric = "time" },
  { id = "troops", label = "Troop lift", metric = "time" },
  { id = "hover", label = "Precision hover", metric = "metres" },
  { id = "auto", label = "Autorotation", metric = "time" },
  { id = "gunnery", label = "Door gunner hits", metric = "count" },
}

function Exercises.new(ctx)
  local self = setmetatable({}, Exercises)
  self.cfg = ctx.cfg
  self.range = ctx.range
  self.troops = ctx.troops
  self.progress = ctx.progress
  self.notify = ctx.notify
  self.sites = ctx.sites
  self.states = {} -- [unit_name] = per-aircraft attempt state
  self.cargo = {} -- ordered list of spawned load records
  self.smoke_sites = {} -- map-marker sites; smoke is available only on demand
  self.targets = { group = nil, respawn_at = nil }
  return self
end

-- ------------------------------------------------------------------ set-up

function Exercises:register()
  for _, entry in ipairs(EXERCISES) do
    self.progress:register(entry.id, entry.label, entry.metric)
  end
  for _, spec in ipairs(LANDING_SITES) do
    if self.cfg.enable.landings and self.sites[spec.site] then
      self.progress:register(spec.exercise, spec.label, "count")
    end
  end
end

--- Spawn every object the exercises need and mark the sites on the map.
function Exercises:setup()
  local sites = self.sites
  local notify = self.notify

  if self.cfg.enable.sling then
    self:spawn_cargo()
    self:mark_site("cargo_yard", trigger.smokeColor.White, "CARGO YARD")
    self:mark_site("pad_alpha", trigger.smokeColor.Green, "PAD ALPHA (open)")
    self.range:spawn_obstacle_ring(sites.pad_bravo, self.cfg.obstacle_ring)
    self:mark_site("pad_bravo", trigger.smokeColor.Orange, "PAD BRAVO (confined)")
    self:mark_site("pad_charlie", trigger.smokeColor.Green, "PAD CHARLIE (field)")
  end

  if self.cfg.enable.hover then
    self:mark_site("hover_pad", trigger.smokeColor.Blue, "HOVER PAD")
  end

  if self.cfg.enable.troops then
    self.troops:spawn_squad(sites.troop_pickup)
    self:mark_site("troop_pickup", trigger.smokeColor.Red, "SQUAD STAGING")
    self:mark_site("troop_lz", trigger.smokeColor.Red, "SQUAD LZ")
  end

  if self.cfg.enable.autorotation then
    self:mark_site("auto_gate", trigger.smokeColor.White, "AUTOROTATION GATE")
    self:mark_site("auto_pad", trigger.smokeColor.Orange, "AUTOROTATION PAD")
  end

  if self.cfg.enable.gunnery then
    self:mark_site("gun_line", trigger.smokeColor.White, "GUN LINE")
    self:spawn_targets()
  end

  if self.cfg.enable.landings then
    for _, spec in ipairs(LANDING_SITES) do
      local site = sites[spec.site]
      if site then
        self:mark_site(spec.site, trigger.smokeColor.Green, site.label or spec.label)
      end
    end
  end

  notify:log(string.format("range ready: %d loads, %d targets", #self.cargo, self.targets.count or 0))
end

--- Keep the persistent map label, but defer its smoke until a pilot asks for it.
function Exercises:mark_site(site_key, color, text)
  local site = self.sites[site_key]
  if not site then
    return
  end
  local label = text or site.label or site_key
  self.range:mark_site(site, color, label, false)
  self.smoke_sites[#self.smoke_sites + 1] = {
    key = site_key,
    label = label,
    color = color,
  }
end

function Exercises:spawn_cargo()
  local site = self.sites.cargo_yard
  local spacing = 16
  local rows = 2
  local per_row = math.ceil(#self.cfg.cargo / rows)
  for index, entry in ipairs(self.cfg.cargo) do
    local row = math.floor((index - 1) / per_row)
    local column = (index - 1) % per_row
    local x = site.x - ((per_row - 1) * spacing) / 2 + column * spacing
    local y = site.y + (row - (rows - 1) / 2) * 22
    local name = self.range:spawn_cargo(entry, x, y, 0, index)
    if name then
      self.cargo[#self.cargo + 1] = {
        index = index,
        name = name,
        entry = entry,
        home_x = x,
        home_y = y,
        menu_label = string.format("%02d - %s (%s)", index, entry.label, string.upper(entry.class)),
      }
    end
  end
end

--- Smoke the live position of one selected load, if it still exists.
function Exercises:smoke_cargo(index)
  for _, load in ipairs(self.cargo) do
    if load.index == index then
      local x, y, altitude = self.range:static_position(load.name)
      if not x then
        return false
      end
      return self.range:smoke_at(x, y, altitude, trigger.smokeColor.White)
    end
  end
  return false
end

function Exercises:spawn_targets()
  local site = self.sites.gun_targets
  local count = 8
  self.targets.group = self.range:spawn_infantry({
    name = "HTG_TGT",
    unit_type = "Infantry AK",
    count = count,
    x = site.x,
    y = site.y,
    alt = site.height or 0,
    spread = 55,
    skill = "Average",
    kind = "targets",
    country_id = self.cfg.target_country_id or 0,
    passive = true,
  })
  self.targets.count = count
  self.targets.respawn_at = nil
  return self.targets.group
end

-- ------------------------------------------------------------------- tick

function Exercises:state(unit_name)
  local state = self.states[unit_name]
  if not state then
    state = { landings = {}, hover = {}, auto = {} }
    self.states[unit_name] = state
  end
  return state
end

--- Evaluate one sample. `sample` is built in main.lua; see there for fields.
function Exercises:tick(sample)
  local state = self:state(sample.unit_name)
  state.type_name = sample.type_name
  local now = timer.getAbsTime()

  self:tick_landings(sample, state, now)
  self:tick_hover(sample, state, now)
  self:tick_autorotation(sample, state, now)
  self:tick_troops(sample, state, now)
end

function Exercises:tick_landings(sample, state, now)
  if not self.cfg.enable.landings then
    return
  end
  local cfg = self.cfg.landing
  for _, spec in ipairs(LANDING_SITES) do
    local site = self.sites[spec.site]
    if site then
      local _, distance = geo().bearing_distance(sample.x, sample.y, site.x, site.y)
      local attempt = state.landings[spec.key or spec.exercise]
      if not attempt then
        attempt = {}
        state.landings[spec.key or spec.exercise] = attempt
      end
      local contact = distance <= site.radius and sample.agl <= cfg.agl_max_m and sample.speed_ms <= cfg.speed_max_ms
      if contact then
        attempt.since = attempt.since or now
        if not attempt.recorded and (now - attempt.since) >= cfg.hold_seconds then
          attempt.recorded = true
          local count = self.progress:record(sample.player, spec.exercise, nil, spec.label)
          self.notify:unit(sample.unit_name, string.format("%s CLEARED (%d)", spec.label, count), 8)
        end
      else
        attempt.since = nil
        attempt.recorded = false
      end
    end
  end
end

function Exercises:tick_hover(sample, state, now)
  if not self.cfg.enable.hover then
    return
  end
  local cfg = self.cfg.hover
  local site = self.sites.hover_pad
  if not site then
    return
  end
  local _, distance = geo().bearing_distance(sample.x, sample.y, site.x, site.y)
  local in_box = distance <= cfg.radius_m
    and sample.agl >= cfg.agl_min_m
    and sample.agl <= cfg.agl_max_m
    and sample.speed_ms <= self.cfg.landing.speed_max_ms
  if not in_box then
    state.hover.since = nil
    state.hover.drift = nil
    state.hover.heading = nil
    return
  end
  if not state.hover.since then
    state.hover.since = now
    state.hover.drift = distance
    state.hover.heading = sample.heading
    return
  end
  state.hover.drift = math.max(state.hover.drift or 0, distance)
  local drift_heading = geo().bearing_delta(state.hover.heading, sample.heading)
  if drift_heading > cfg.heading_drift_deg then
    self.notify:unit(sample.unit_name, string.format("Hover broken: heading drifted %.0f deg", drift_heading), 6)
    state.hover.since = nil
    return
  end
  if (now - state.hover.since) >= cfg.hold_seconds then
    local drift = state.hover.drift
    self.progress:record(sample.player, "hover", drift, string.format("%.1f m", drift))
    self.notify:unit(sample.unit_name, string.format("HOVER HOLD COMPLETE - max drift %.1f m", drift), 10)
    state.hover.since = nil
    state.hover.drift = nil
  end
end

function Exercises:tick_autorotation(sample, state, now)
  if not self.cfg.enable.autorotation then
    return
  end
  local cfg = self.cfg.autorotation
  local gate = self.sites.auto_gate
  local pad = self.sites.auto_pad
  if not gate or not pad then
    return
  end

  if not state.auto.armed then
    local _, gate_distance = geo().bearing_distance(sample.x, sample.y, gate.x, gate.y)
    local in_gate = gate_distance <= gate.radius
      and sample.agl >= cfg.entry_agl_min_m
      and sample.speed_kmh >= cfg.entry_speed_min_kmh
    if in_gate then
      state.auto.entry_since = state.auto.entry_since or now
      if (now - state.auto.entry_since) >= cfg.entry_hold_seconds then
        state.auto.armed = true
        state.auto.armed_at = now
        self.notify:unit(sample.unit_name, "GATE PASSED - simulate engine failure now, land on the orange pad", 14)
      end
    else
      state.auto.entry_since = nil
    end
    return
  end

  local _, pad_distance = geo().bearing_distance(sample.x, sample.y, pad.x, pad.y)
  local contact = pad_distance <= pad.radius
    and sample.agl <= self.cfg.landing.agl_max_m
    and sample.speed_ms <= self.cfg.landing.speed_max_ms
  if contact then
    local seconds = now - state.auto.armed_at
    self.progress:record(sample.player, "auto", seconds, geo().duration(seconds))
    self.notify:unit(sample.unit_name, string.format("AUTOROTATION COMPLETE - %s", geo().duration(seconds)), 12)
    state.auto.armed = false
    state.auto.entry_since = nil
  end
end

function Exercises:tick_troops(sample, state, now)
  if not self.cfg.enable.troops then
    return
  end
  local pickup = self.sites.troop_pickup
  local lz = self.sites.troop_lz
  if not pickup or not lz then
    return
  end

  local stationary = sample.agl <= self.cfg.landing.agl_max_m and sample.speed_ms <= self.cfg.landing.speed_max_ms
  if not stationary then
    state.troops_settle = nil
    return
  end
  state.troops_settle = state.troops_settle or now
  if (now - state.troops_settle) < 2 then
    return
  end

  local _, pickup_distance = geo().bearing_distance(sample.x, sample.y, pickup.x, pickup.y)
  local _, lz_distance = geo().bearing_distance(sample.x, sample.y, lz.x, lz.y)
  local aboard = self.troops:count(sample.unit_name)

  if pickup_distance <= pickup.radius and aboard < self.troops:capacity_for(sample.type_name) then
    local taken = self.troops:load(sample.unit_name, sample.type_name)
    if taken > 0 then
      local total = self.troops:count(sample.unit_name)
      self.notify:unit(
        sample.unit_name,
        string.format("TROOPS ABOARD: %d (capacity %d)", total, self.troops:capacity_for(sample.type_name)),
        10
      )
      state.troop_load_at = state.troop_load_at or now
      state.troops_settle = nil
    elseif aboard == 0 then
      self.notify:unit(sample.unit_name, "Staging area empty - use RANGE / Reset range", 8)
      state.troops_settle = nil
    end
    return
  end

  if lz_distance <= lz.radius and aboard > 0 then
    local dropped = self.troops:unload(sample.unit_name, sample.x, sample.y, sample.alt)
    if dropped > 0 then
      local seconds = state.troop_load_at and (now - state.troop_load_at) or nil
      self.progress:record(sample.player, "troops", seconds, string.format("%d pax", dropped))
      self.notify:unit(sample.unit_name, string.format("TROOPS DELIVERED: %d", dropped), 10)
      state.troop_load_at = nil
      state.troops_settle = nil
    end
  end
end

-- ------------------------------------------------------------- external load

--- Called once per tick after all samples, so load attribution can see every
--- aircraft. `positions` is a list of { unit_name, player, x, y }.
function Exercises:update_cargo(positions, now)
  if not self.cfg.enable.sling then
    return
  end
  for _, load in ipairs(self.cargo) do
    local x, y, altitude = self.range:static_position(load.name)
    if not x then
      -- Only report a loss for a load we have actually seen in the world; the
      -- first tick can otherwise race the spawn.
      if load.seen and not load.lost then
        load.lost = true
        self.notify:all(string.format("%s destroyed - reset the range to respawn it", load.entry.label), 10)
      end
    else
      load.seen = true
      if not load.home_altitude then
        load.home_altitude = altitude
      end
      if altitude > load.home_altitude + 2 and not load.lifted_at then
        load.lifted_at = now
        load.lifted_by = self:nearest_pilot(positions, x, y)
        self.notify:all(string.format("%s airborne - hook-up confirmed", load.entry.label), 8)
      end
      if load.lifted_at and not load.delivered then
        for _, pad_key in ipairs({ "pad_alpha", "pad_bravo", "pad_charlie" }) do
          local pad = self.sites[pad_key]
          if pad then
            local _, distance = geo().bearing_distance(x, y, pad.x, pad.y)
            if distance <= pad.radius then
              load.delivered = true
              load.delivered_at = now
              local seconds = now - load.lifted_at
              local points = self.cfg.cargo_points[load.entry.class] or 10
              self.progress:record(
                load.lifted_by or "range",
                "sling",
                seconds,
                string.format("%s -> %s (%d pts)", load.entry.label, pad.label or pad_key, points)
              )
              self.notify:all(
                string.format(
                  "%s DELIVERED to %s in %s (+%d)",
                  load.entry.label,
                  pad.label or pad_key,
                  geo().duration(seconds),
                  points
                ),
                12
              )
              break
            end
          end
        end
      end
    end
  end
end

function Exercises:nearest_pilot(positions, x, y)
  local best, best_distance
  for _, position in ipairs(positions) do
    local _, distance = geo().bearing_distance(x, y, position.x, position.y)
    if not best_distance or distance < best_distance then
      best, best_distance = position, distance
    end
  end
  if best and best_distance and best_distance <= 500 then
    return best.player
  end
  return nil
end

-- ------------------------------------------------------------------ gunnery

--- A target died. Credit the shooter if it was a player.
function Exercises:on_kill(pilot, unit_name, victim_name)
  if not self.cfg.enable.gunnery or not self.targets.group then
    return
  end
  if not victim_name or not victim_name:find("HTG_TGT", 1, true) then
    return
  end
  local count = self.progress:record(pilot or "range", "gunnery", nil, nil)
  self.notify:all(string.format("Target down (%d this session) - %s", count, pilot or "AI"), 8)
  if self.range:group_alive(self.targets.group) == false then
    self:schedule_target_respawn()
  end
end

function Exercises:schedule_target_respawn()
  if self.targets.respawn_at then
    return
  end
  self.targets.respawn_at = timer.getAbsTime() + 25
  self.notify:all("Target field clear - fresh targets in 25 seconds", 8)
end

function Exercises:check_target_respawn(now)
  if not self.cfg.enable.gunnery or not self.targets.respawn_at then
    return
  end
  if now < self.targets.respawn_at then
    return
  end
  self.targets.respawn_at = nil
  self.range:destroy_group(self.targets.group)
  self:spawn_targets()
end

-- -------------------------------------------------------------------- reset

--- Put the world back: cargo respawned, squad back, targets fresh.
function Exercises:reset_world()
  for _, load in ipairs(self.cargo) do
    self.range:destroy_static(load.name)
  end
  self.cargo = {}
  self:spawn_cargo()
  if self.cfg.enable.troops then
    self.troops:reset()
    self.troops:spawn_squad(self.sites.troop_pickup)
  end
  if self.cfg.enable.gunnery then
    self.range:destroy_group(self.targets.group)
    self:spawn_targets()
  end
  for _, state in pairs(self.states) do
    state.landings = {}
    state.hover = {}
    state.auto = {}
  end
  self.notify:all("Range reset: loads, squad and targets respawned.", 12)
end

--- Status text for the menu and the periodic report.
function Exercises:status_text()
  local lines = {}
  local live, delivered = 0, 0
  for _, load in ipairs(self.cargo) do
    if not load.lost then
      live = live + 1
    end
    if load.delivered then
      delivered = delivered + 1
    end
  end
  lines[#lines + 1] = string.format("Loads: %d in the yard, %d delivered", live, delivered)
  if self.cfg.enable.troops then
    lines[#lines + 1] =
      string.format("Squad: %d still at staging, %d delivered", #self.troops:squad_remaining(), self.troops.delivered)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = self.progress:report(geo().duration)
  return table.concat(lines, "\n")
end

--- The exercise brief, shown on demand and shortly after mission start.
function Exercises:brief_text()
  local sites = self.sites
  local base = self.cfg.base
  local lines = {
    "HELICOPTER TRAINING GROUNDS - " .. base.name,
    "",
    "1. EXTERNAL LOAD: hook a load in the cargo yard and set it down on a green or orange pad.",
    "   Yard " .. geo().describe(sites.cargo_yard.x, sites.cargo_yard.y, base),
    "   Pads " .. geo().describe(sites.pad_alpha.x, sites.pad_alpha.y, base) .. " / " .. geo().describe(
      sites.pad_bravo.x,
      sites.pad_bravo.y,
      base
    ) .. " / " .. geo().describe(sites.pad_charlie.x, sites.pad_charlie.y, base),
    "",
    "2. TROOP LIFT: land at the staging area, take the squad aboard, put them on the field LZ.",
    "   Staging " .. geo().describe(sites.troop_pickup.x, sites.troop_pickup.y, base),
    "   LZ      " .. geo().describe(sites.troop_lz.x, sites.troop_lz.y, base),
    "",
    "3. CONFINED LANDINGS: touch down and hold on each marked pad, then lift off.",
    "4. PRECISION HOVER: hold inside the blue hover pad, 4-9 m AGL, for 45 seconds.",
    "5. AUTOROTATION: cross the gate above 300 m AGL at 100+ km/h, then land on the orange pad.",
    "6. DOOR GUNNER: engage the target field from the gun line.",
    "",
    "F10 menu: RANGE -> status, smoke one location, reset, terrain scan.",
  }
  return table.concat(lines, "\n")
end

return Exercises
