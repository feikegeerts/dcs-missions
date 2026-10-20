return {
  mission_name = "operation-hidden-passage",
  mission_version = "transport-firefight-1",
  title = "Operation Hidden Passage",
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
  extraction_distance_m = 105,
  automatic_pickup_settle_s = 2,
  receiving = { x = 147592.73464201999, y = 38819.890889082999, radius = 180 },
  -- The mission-table builder places the late-activated enemy template relative
  -- to the actual archive HVT zone. Long routes trigger at a fixed range from
  -- pickup; the short Testing route retains its midpoint trigger.
  firefight = {
    template = "OHP-TestOpposition",
    maximum_duration_s = 10 * 60,
    fire_radius_m = 45,
    start_distance_from_pickup_nm = 3,
    staging_offset_m = 280,
    fire_position_offset_m = 180,
    fire_start_distance_m = 300,
    approach_speed_mps = 5,
    hvt_return_fire_duration_s = 5,
    enemy_unit_count = 6,
  },
}
