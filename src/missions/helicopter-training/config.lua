-- Helicopter Training Grounds - range configuration.
--
-- Coordinate frame: DCS Caucasus grid metres (x, y) exactly as the mission
-- editor writes them, so anything here can be pasted straight into a .miz or
-- compared with the F10 map. Bearings are grid bearings (0 = +y).
--
-- Sites are *intentions*, not final positions. At mission start the range
-- resolves every site against the real terrain (see range.lua / terrain.lua)
-- and relocates anything that lands in water or on unsuitable ground, logging
-- what it moved and why. Freeze the resolved coordinates back here once a run
-- has confirmed them.
--
-- Anchor evidence for the coordinates below (Batumi apron reference
-- x = -356069.6, y = 618234.9):
--   * a FARP and two Humvees placed by the UH-60L mod author ~700 m away on
--     bearing 214 deg - verified flat, usable land;
--   * an M-109 artillery battery placed by the "Black Guard" campaign at
--     6.15 km on bearing 247 deg - verified land;
--   * a moored dry-cargo ship at 6.08 km on bearing 118 deg - verified water.
-- The range corridor therefore runs roughly 200-250 deg (inland), and the
-- 90-180 deg sector beyond ~3 km is sea.

return {
  mission_name = "helicopter-training",
  mission_version = "1",
  title = "Helicopter Training Grounds",

  -- Blue coalition / USA, matching the mission's helicopter country entry.
  coalition = 2,
  country_id = 2,
  -- Red (Russia) is used for the gunnery targets only.
  target_country_id = 0,

  base = {
    name = "Batumi",
    airbase_id = 22,
    -- Player parking apron; every bearing/range in messages is quoted from here.
    x = -356069.6,
    y = 618234.9,
    elevation = 10,
  },

  -- Switch exercises off here rather than deleting them.
  enable = {
    sling = true,
    troops = true,
    landings = true,
    hover = true,
    autorotation = true,
    gunnery = true,
  },

  -- Troop capacity by airframe. Values taken from the "Long Lift" campaign's
  -- transport manager, which is the shipped reference for these airframes.
  troop_capacity = {
    ["CH-47Fbl1"] = 31,
    ["UH-60L"] = 11,
  },
  troop_capacity_default = 8,
  troop_mass_kg = 100, -- per pax, fed to trigger.action.setUnitInternalCargo

  sites = {
    -- Cargo hook-up yard: on the ramp, a short hover-taxi from parking.
    cargo_yard = { x = -356300, y = 618000, radius = 60, label = "CARGO YARD" },

    -- Drop pads for external load work, in increasing difficulty.
    pad_alpha = { x = -356900, y = 617500, radius = 45, label = "PAD ALPHA (open)" },
    pad_bravo = { x = -356463, y = 617644, radius = 32, label = "PAD BRAVO (confined)" },
    pad_charlie = { x = -361718, y = 615805, radius = 40, label = "PAD CHARLIE (field)" },

    -- Precision hover box.
    hover_pad = { x = -356600, y = 617900, radius = 10, label = "HOVER PAD" },

    -- Troop lift: staging area and field landing zone.
    troop_pickup = { x = -357200, y = 617900, radius = 90, label = "SQUAD STAGING" },
    troop_lz = { x = -361450, y = 616050, radius = 90, label = "SQUAD LZ" },

    -- Autorotation lane: gate over the approach, pad 1.8 km short of it.
    auto_gate = { x = -359534, y = 616235, radius = 300, label = "AUTOROTATION GATE" },
    auto_pad = { x = -358235, y = 616985, radius = 45, label = "AUTOROTATION PAD" },

    -- Door-gunner range: firing line, targets 800 m beyond on the same axis.
    gun_line = { x = -357109, y = 617635, radius = 60, label = "GUN LINE" },
    gun_targets = { x = -357801, y = 617235, radius = 90, label = "TARGET FIELD" },

    -- Off-field landings. Terrain here is unverified, so the range treats
    -- these as search centres: if the ground is unsuitable it looks outward
    -- for the nearest flat bench and logs the result.
    hill_north = { x = -360100, y = 621600, radius = 35, label = "RIDGE PAD (provisional)" },
    hill_east = { x = -352400, y = 619700, radius = 35, label = "HILL PAD (provisional)" },
  },

  -- External loads. type/shape_name pairs verified against 411 cargo statics
  -- in installed missions. Weights are what DCS reports in the CH-47F cargo
  -- menu; they are classed here rather than quoted exactly.
  cargo = {
    {
      key = "crate_a",
      type = "uh1h_cargo",
      shape_name = "ab-212_cargo",
      class = "light",
      label = "UH-1H cargo crate",
    },
    { key = "crate_b", type = "ammo_cargo", shape_name = "ammo_box_cargo", class = "light", label = "Ammo box" },
    { key = "pallet", type = "M92_MRE_Pallet", shape_name = "M92_Cargo01", class = "medium", label = "MRE pallet" },
    { key = "barrels", type = "barrels_cargo", shape_name = "barrels_cargo", class = "medium", label = "Barrels" },
    {
      key = "container",
      type = "iso_container_small",
      shape_name = "iso_container_small_cargo",
      class = "heavy",
      label = "ISO container",
    },
    { key = "fueltank", type = "fueltank_cargo", shape_name = "fueltank_cargo", class = "heavy", label = "Fuel tank" },
  },

  -- Scoring weight per load class.
  cargo_points = { light = 10, medium = 20, heavy = 35 },

  -- Obstacles that turn a flat pad into a confined one. Placed as a ring
  -- around the pad with a deliberate gap; radii are metres from the pad centre.
  obstacle_ring = { radius = 22, count = 8, gap_deg = 70 },

  -- Landing-quality thresholds. agl_max_m has to clear the height of the
  -- aircraft reference point above the ground when it is parked on its gear.
  landing = {
    speed_max_ms = 3.0,
    agl_max_m = 4.0,
    hold_seconds = 3,
  },

  hover = {
    radius_m = 10,
    agl_min_m = 4.0,
    agl_max_m = 9.0,
    hold_seconds = 45,
    heading_drift_deg = 20,
  },

  autorotation = {
    entry_agl_min_m = 300,
    entry_speed_min_kmh = 100,
    entry_hold_seconds = 2,
  },

  -- Terrain probe: automatic scan at mission start plus the F10 command.
  probe = {
    enabled = true,
    ring_min_m = 2500,
    ring_max_m = 9000,
    bearings = 24,
    steps = 8,
    flat_patch_radius_m = 40,
    bench_patch_radius_m = 120,
    max_flat_relief_m = 3.0,
    min_hill_elevation_m = 120,
    min_hill_relief_m = 25,
    report_count = 4,
  },

  messages = {
    boot_seconds = 20,
    event_seconds = 12,
  },
}
