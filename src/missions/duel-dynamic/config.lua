-- Scenario identity belongs to the mission, never to the telemetry library.
-- Preserve the legacy identity and version until a distinct mission is selected.
return {
  mission_name = "duel-dynamic",
  mission_version = "1",
  title = "Air Superiority Survival",
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
    "Bandit-10",
  },
}
