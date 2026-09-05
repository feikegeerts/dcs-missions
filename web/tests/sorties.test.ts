import { describe, expect, it } from "vitest";

import {
  deriveSorties,
  eventRowToSortieInput,
  type ParticipantEventInput,
} from "../src/telemetry/sorties";

function event(
  event_sequence: number,
  event_type: ParticipantEventInput["event_type"],
  slot: string | null,
  participantId: string | null = "ucid-player-1",
  sim_time: number = event_sequence * 10,
): ParticipantEventInput {
  return {
    event_sequence,
    event_type,
    sim_time,
    participant: {
      participant_id: participantId,
      display_name: "Pilot",
      callsign: "Aerial 1-1",
    },
    asset: { dcs_name: slot, dcs_type: "FA-18C_hornet" },
  };
}

describe("deriveSorties", () => {
  it("pairs one enter and left event", () => {
    expect(
      deriveSorties([
        event(1, "participant.entered", "Aerial-1-1", "ucid-one", 12),
        event(2, "participant.left", "Aerial-1-1", "ucid-one", 30),
      ]),
    ).toEqual([
      {
        participant_id: "ucid-one",
        slot_dcs_name: "Aerial-1-1",
        entered_sequence: 1,
        left_sequence: 2,
        sim_started: 12,
        sim_ended: 30,
        status: "closed",
      },
    ]);
  });

  it("tracks two players in different slots concurrently", () => {
    const sorties = deriveSorties([
      event(1, "participant.entered", "Aerial-1-1", "ucid-one"),
      event(2, "participant.entered", "Aerial-2-1", "ucid-two"),
      event(3, "participant.left", "Aerial-1-1", "ucid-one"),
      event(4, "participant.left", "Aerial-2-1", "ucid-two"),
    ]);

    expect(sorties).toHaveLength(2);
    expect(sorties.map((sortie) => sortie.participant_id)).toEqual([
      "ucid-one",
      "ucid-two",
    ]);
    expect(sorties.map((sortie) => sortie.status)).toEqual([
      "closed",
      "closed",
    ]);
  });

  it("creates a distinct sortie for re-entry after leave", () => {
    const sorties = deriveSorties([
      event(1, "participant.entered", "Aerial-1-1"),
      event(2, "participant.left", "Aerial-1-1"),
      event(3, "participant.entered", "Aerial-1-1"),
      event(4, "participant.left", "Aerial-1-1"),
    ]);

    expect(sorties).toMatchObject([
      { entered_sequence: 1, left_sequence: 2, status: "closed" },
      { entered_sequence: 3, left_sequence: 4, status: "closed" },
    ]);
  });

  it("marks an open sortie replaced when another enter arrives", () => {
    const sorties = deriveSorties([
      event(1, "participant.entered", "Aerial-1-1", "ucid-one"),
      event(2, "participant.entered", "Aerial-1-1", "ucid-two"),
    ]);

    expect(sorties).toMatchObject([
      {
        participant_id: "ucid-one",
        left_sequence: null,
        sim_ended: null,
        status: "replaced",
      },
      { participant_id: "ucid-two", status: "open" },
    ]);
  });

  it("ignores a left event when no sortie is open", () => {
    expect(deriveSorties([event(1, "participant.left", "Aerial-1-1")])).toEqual(
      [],
    );
  });

  it("keeps an unknown participant unresolved", () => {
    expect(
      deriveSorties([event(1, "participant.entered", "Aerial-1-1", null)]),
    ).toMatchObject([{ participant_id: null, status: "open" }]);
  });

  it("skips null and empty slot names", () => {
    expect(
      deriveSorties([
        event(1, "participant.entered", null),
        event(2, "participant.entered", ""),
      ]),
    ).toEqual([]);
  });

  it("processes out-of-order input by event sequence", () => {
    const sorties = deriveSorties([
      event(4, "participant.left", "Aerial-2-1", "ucid-two"),
      event(2, "participant.entered", "Aerial-2-1", "ucid-two"),
      event(3, "participant.left", "Aerial-1-1", "ucid-one"),
      event(1, "participant.entered", "Aerial-1-1", "ucid-one"),
    ]);

    expect(sorties).toMatchObject([
      { entered_sequence: 1, left_sequence: 3, status: "closed" },
      { entered_sequence: 2, left_sequence: 4, status: "closed" },
    ]);
  });

  it("returns an empty result for empty input", () => {
    expect(deriveSorties([])).toEqual([]);
  });
});

describe("eventRowToSortieInput", () => {
  it("maps stored enter/leave rows through the full event JSON", () => {
    expect(
      eventRowToSortieInput({
        eventSequence: 7,
        eventType: "participant.entered",
        simTime: 70,
        eventJson: {
          participant: {
            participant_id: "ucid-one",
            display_name: "Pilot",
            callsign: "Aerial 1-1",
          },
          asset: { dcs_name: "Aerial-1-1", dcs_type: "FA-18C_hornet" },
        },
      }),
    ).toEqual({
      event_sequence: 7,
      event_type: "participant.entered",
      sim_time: 70,
      participant: {
        participant_id: "ucid-one",
        display_name: "Pilot",
        callsign: "Aerial 1-1",
      },
      asset: { dcs_name: "Aerial-1-1", dcs_type: "FA-18C_hornet" },
    });
  });

  it("returns null for non-participant rows and tolerates missing JSON", () => {
    expect(
      eventRowToSortieInput({
        eventSequence: 2,
        eventType: "ordnance.fired",
        simTime: 20,
        eventJson: { weapon: { dcs_type: "AIM_120C" } },
      }),
    ).toBeNull();
    expect(
      eventRowToSortieInput({
        eventSequence: 3,
        eventType: "participant.left",
        simTime: 30,
        eventJson: null,
      }),
    ).toEqual({
      event_sequence: 3,
      event_type: "participant.left",
      sim_time: 30,
      participant: null,
      asset: null,
    });
  });
});
