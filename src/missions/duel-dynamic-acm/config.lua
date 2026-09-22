return {
  mission_name = "duel-dynamic-acm",
  mission_version = "2",
  title = "Duel Dynamic ACM",
  player_group_names = { "Aerial-1", "Aerial-2", "Aerial-3", "Aerial-4", "Aerial-5" },
  bandit_group_names = {
    "Bandit-1",
    "Bandit-2",
    "Bandit-3",
    "Bandit-4",
    "Bandit-5",
    "Bandit-6",
    "Bandit-8",
    "Bandit-9",
  },
  -- ACM uses the same package-wave lifecycle and Survival allowances, but
  -- starts the opposing package at a fixed close-range distance.
  gameplay = {
    spawn_distance_min_sm = 20,
    spawn_distance_max_sm = 20,
    respawn_delay_s = 20,
    lives_per_player = 2,
  },
}
