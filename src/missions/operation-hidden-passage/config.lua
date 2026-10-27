return {
  mission_name = "operation-hidden-passage",
  mission_version = "transport-cap-hind-handoff-1",
  title = "Operation Hidden Passage",
  awacs_group = "Overlord",
  overlord_confirmation_delay_s = 20, -- Reporting latency only; objective/spawn transitions are immediate.
  player_group = "Mule-1",
  player_unit = "Mule-1-1",
  support_unit = "Raven-1-1",
  support_group = "Raven-1",
  party_template = "OHP-TestParty",
  party_size = 3,
  pickup_zone = "OHP-Pickup",
  personnel_zone = "OHP-HVTs",
  return_zone = "OHP-Hatay-Return",
  -- Build/test snapshots of the editor layout. Runtime uses the named zones.
  -- DCS Vec2: x is north/south, y is east/west. Pickup is ~33 NM south of Hatay.
  pickup = { x = 86422.487668525006, y = 41545.335676019, radius = 35 },
  personnel = { x = 86380.719912450993, y = 41473.479388790998, radius = 25 },
  minimum_personnel_clearance_m = 35,
  extraction_distance_m = 125,
  automatic_pickup_settle_s = 2,
  receiving = { x = 147592.73464201999, y = 38819.890889082999, radius = 180 },
  -- The mission-table builder places the late-activated enemy template relative
  -- to the actual archive HVT zone. Long routes trigger at a fixed range from
  -- pickup; the short Testing route retains its midpoint trigger.
  firefight = {
    template = "OHP-TestOpposition",
    template_alias = "OHP-TestOpposition-1",
    pickup_template = "OHP-TestOpposition-2",
    maximum_duration_s = 10 * 60,
    fire_radius_m = 45,
    start_distance_from_pickup_nm = 3,
    staging_offset_m = 280,
    fire_position_offset_m = 180,
    fire_start_distance_m = 400,
    approach_speed_mps = 5,
    hvt_return_fire_duration_s = 5,
    enemy_unit_count = 6,
  },
  cas = {
    enable_pickup_test_menu = true, -- TEMPORARY: remove/disable after solo CAS acceptance.
    convoy_template = "CAS-Convoy",
    checkpoint_template = "CAS-Convoy-1",
    checkpoint_tasking_delay_s = 5, -- Timely CAS tasking after pickup; other Overlord confirmations stay at 20 s.
    slots = {
      ["CAS-Hornet"] = "FA-18C_hornet",
      ["CAS-Warthog"] = "A-10C_2",
    },
  },
  cap = {
    sam_template = "Ground-9",
    radar_type = "Kub 1S91 str",
    fighters_template = "Aerial-1",
    hind_template = "Rotary-1",
    radar_check_interval_s = 2,
    fighters_runway_start = true, -- Approved: bypass parking/taxi, keep the authored airfield and airborne route.
    spawn_ready_timeout_s = 10, -- DCS aircraft can appear after SPAWN returns.
    slots = {
      ["CAP-Hornet"] = "FA-18C_hornet",
      ["CAP-Viper"] = "F-16C_50",
    },
  },
}
