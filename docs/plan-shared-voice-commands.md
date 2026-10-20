# Shared multiplayer voice commands — future improvement

Status: **Deferred idea and proposed approach; not an implementation commitment.**
Date: 2026-10-20

The user requested a separate plan because this capability should work across
multiple missions. Do not begin implementation, installations, configuration
changes, or mission deployment without a later explicit go-ahead.

## Goal and agreed direction

Let players respond to scripted/generated messages and request mission actions
using their real voices. This must work for friends on other computers, not just
the host. Recognize a bounded set of requests and phrasing variations; unrestricted
AI conversation is **not** the goal.

**Recognition preference (user-confirmed 2026-10-20):** Use the user's existing
local **Whisper Turbo** model. The user reports excellent transcription quality
in OpenWhispr and wants that recognizer for mission speech input. First evaluate
reusing its existing local inference server; if unsuitable, serve the same model
through the user's local WSL inference gateway. This records a preference and
integration options, **not permission to install or implement the service now**.

Example exchanges:

- Player: “Overlord One One, what's the HVT's location?”
  Mission: returns the party's actual current location, when available.
- Player: “Overlord One One, can you mark it with green smoke?”
  Mission: resolves the requested mark in context and executes an allowed action.
- Player: “Overlord One One, say again.”
  System: repeats the last relevant reply.

These are examples, not a finalized vocabulary. In Hidden Passage, smoke should
continue to mark the **landing area, not the personnel**, with an explicit reply
explaining that distinction. Do not undo the existing collision-safety behavior.

## Proposed architecture

```text
Player microphone + push-to-talk
  -> player's SRS client
  -> shared SRS server
  -> voice-command bot connected as an SRS radio client
  -> local Whisper Turbo HTTP inference -> bounded command parser
  -> host-side DCS bridge
  -> active mission's validated action handler
  -> result -> spoken response over SRS
```

SRS carries audio; it does not itself interpret speech or trigger mission logic.
The bot needs a receiving SRS client implementation, not only an audio-transmit
utility. Ordinary DCS mission Lua has no native speech-recognition input, and
built-in DCS voice chat is not the proposed external-bot transport.

| Where | Proposed components |
|---|---|
| Each participating player's PC | DCS, SRS client, microphone and push-to-talk binding |
| Host/server or trusted companion machine | SRS server, receiving bot, speech recognizer and command parser |
| DCS host | Bridge to the mission, with narrowly permitted operations |
| Each supported mission | Mission-specific command handlers and state validation |

Friends would not need VoiceAttack, VAICOM, speech models or cloud API keys.
The architecture should support both client-hosted multiplayer and a dedicated
server; neither configuration has been proven for this integration yet. SRS
needs separate network access from DCS; its usual TCP/UDP port is 5002, subject
to the actual configuration.

## Preferred recognition backend: existing Whisper Turbo

### Verified local installation (read-only inspection, 2026-10-20)

The app referred to as “OpenWhisper” is installed as **OpenWhispr 1.10.3** on this
Windows host. Its running CUDA `whisper-server-win32-x64-cuda.exe` process loads:

```text
C:\Users\g_for\.cache\openwhispr\whisper-models\ggml-large-v3-turbo.bin
```

The process currently binds **`127.0.0.1:8178`**. A read-only
`GET http://127.0.0.1:8178/health` returned HTTP 200 and `{"status":"ok"}`.
The root page identifies it as Whisper.cpp Server and documents `/inference`.
The installed app's `src/helpers/whisperServer.js`, read from `app.asar`, confirms
that the app itself submits multipart audio to **`POST /inference`** and parses a
JSON response. **No transcription request, recording, model load, service start,
or configuration change was performed for this investigation.**

This is an existing **local whisper.cpp HTTP API**, not the separately advertised
OpenWhispr public cloud API at `api.openwhispr.com`. The public API's cloud
transcription service is not required to reuse this local model.

### Integration order

1. **First prototype candidate: reuse the running local server.** The SRS receiving
   bot submits each player's completed transmission directly as audio, not by
   simulating OpenWhispr hotkeys, pasting text, or reading dictation history.
   Discover/validate the endpoint and loaded model; do not freeze today's port as
   a permanent contract. In this installed version, OpenWhispr chooses from ports
   **8178–8199** and owns server startup, restart and shutdown. Treat this as an
   internal backend integration, not a promised stable third-party app API.
   **Agreed initial operating approach:** the user reports that OpenWhispr starts
   with Windows and is happy to start it manually before a voice-enabled mission
   if needed. Reuse that running app first; do not add another startup service or
   migrate the model to WSL just for convenience. The future voice bridge should
   check the actual inference server/model readiness, not merely whether the GUI
   is open. If unavailable, report voice input unavailable and retain F10 play.
2. **Fallback / independently managed deployment: the user's WSL inference
   gateway serving Whisper Turbo.** Interpret the user's “VSL” reference as WSL;
   the gateway implementation, address and existing transcription support have
   not been inspected. Reuse its service conventions rather than assume it already
   supports audio. A gateway adapter could expose an OpenAI-compatible
   `POST /v1/audio/transcriptions`, or route to whisper.cpp `/inference`; neither
   interface is approved/configured yet. A dedicated Windows-hosted whisper.cpp
   process is another option if moving into WSL adds unnecessary complexity.

Choose a separately managed backend if app restarts, dictation contention or
endpoint discovery make direct sharing unreliable. Avoid loading a second copy
of a large GPU model by default; measure GPU/VRAM contention with DCS first.
Friends still need only SRS: the central bot submits their audio to the local
backend, so no recognition models or API credentials are installed on their PCs.

### Audio/API contract and quality checks for the future prototype

- Decode each SRS speaker/transmission separately and normalize to **16 kHz mono
  PCM16 WAV**, matching OpenWhispr's local submission path. Preserve sender/slot
  metadata outside the transcript; speech recognition is not authentication.
- Existing whisper.cpp request fields are multipart **`file`**, **`language`**
  (the app defaults to `auto`), optional **`prompt`**, and
  **`response_format=json`**. This is not automatically an OpenAI-shaped API.
- Reproduce the useful app settings, not just the model name. The installed
  dictation path also sends **`entropy_thold=2.8`** and
  **`logprob_thold=-1.25`** unless explicitly skipped, and can supply dictionary
  words as a prompt. These are observed settings, not proven optimal command
  settings. Identify any additional text cleanup before claiming equivalent
  output to the desktop dictation experience.
- Confirm the exact weights/model variant and any quantization before moving to
  another runtime. Whisper Turbo on a different backend or with different audio
  preprocessing/decoding settings may not produce identical transcriptions.
- Evaluate callsigns (Mule One, Raven One, Overlord), HVT terminology, accents,
  radio compression/noise, silence hallucinations and clipped push-to-talk audio.
  Good direct-microphone dictation quality is encouraging, not proof of SRS input
  quality. Prompt vocabulary is a hint, never an instruction to invent a command.
- Measure end-of-transmission-to-result latency, simultaneous speakers and
  interference with ordinary dictation. Use bounded queues/timeouts and reject
  stale results rather than execute a delayed request in a later mission phase.
- Keep today's endpoint loopback-only. Do not expose whisper.cpp (including its
  model-loading endpoint) to friends or the internet. If the bot/gateway runs in
  WSL or elsewhere, verify Windows/WSL reachability and use private authenticated
  routing as needed; `127.0.0.1` is not universally interchangeable across hosts.
- Retain local processing as the default; no cloud recognition fallback without
  separate user approval. Do not retain friends' raw audio/transcripts by default
  without agreeing consent and a retention policy.

## Shared versus mission-specific responsibilities

**Shared service:** audio reception, recognition, addressee detection, phrasing
normalization, sender lookup, request routing and spoken replies. Listening
frequency, coalition and controller callsign should be configurable rather than
hardwired to Hidden Passage or “Overlord One One.”

**Mission adapter:** advertises supported commands, resolves mission-specific
entities, checks permissions/current phase, performs actions and returns results.
The voice service must not contain extraction, wave or victory-condition logic.

Suggested command identifiers such as `request_objective_location`,
`mark_pickup_green` and `repeat_last_reply` are illustrative, not a frozen API.
Each mission exposes only meaningful commands; unsupported requests receive a
clear response. Voice and F10 commands should reach the same validated handlers.

Existing recorded/generated audio can remain. Dynamic replies such as coordinates
may require speech synthesis; recognition and speech synthesis are separate
components. A language model is not required to select these bounded actions.

## Reliability, permissions and safety

- Use push-to-talk and an addressed controller callsign to avoid treating casual
  crew conversation or the bot's own output as commands.
- Map the SRS sender to the current DCS player/aircraft/crew using connection
  metadata. **This mapping needs a prototype; a spoken callsign is not proof of
  identity.** Define who may act for an aircraft in multicrew.
- Mission logic remains authoritative. A voice request cannot bypass landed,
  clearance, cargo, objective ownership or phase checks.
- Resolve “it” only when there is an unambiguous current subject; otherwise ask
  for clarification instead of guessing a target.
- Correlate requests with the current mission session and, where applicable, the
  pending prompt. Reject stale replies after a restart, re-slot or phase change.
- Prevent duplicate actions and rate-limit repeat/smoke requests. Exact timings
  and limits remain undecided.
- Retain F10 alternatives, subtitles and clear accepted/rejected feedback. Voice
  recognition failure or a disconnected bot must not make the mission unplayable.
- Keep the bridge private/authenticated. Prefer explicit commands or mission
  flags over arbitrary Lua evaluation. Do not expose a general execution endpoint.
- Local Whisper Turbo is preferred. Any later cloud proposal introduces audio
  disclosure, recurring cost, connectivity and provider dependencies and requires
  separate approval; agree consent and recording/transcript retention with the group.

## Candidate components and unresolved choices

- **SRS:** proposed multiplayer audio transport. Validate radio settings, coalition
  isolation and sender metadata with the installed Chinook and multicrew.
- **Speech recognition:** local Whisper Turbo, preferably reusing the verified
  OpenWhispr whisper.cpp server; the user's WSL inference gateway is the fallback
  hosting route. Exact service ownership/endpoint remain open. Measure SRS-audio
  accuracy, latency and shared GPU load before choosing the deployment.
- **DCS bridge:** DCS-gRPC is a candidate, not a requirement. It exposes mission
  flag operations and mission/session information. Its host installation includes
  hooks/plugin files and a MissionScripting.lua bootstrap change; these require
  separate approval. Keep ordinary mission play functional without the bridge.
- **SRS bot implementation:** SkyEye demonstrates voice reception, recognition
  and radio replies, but is a GCI/AWACS application, not a drop-in custom mission
  command framework. Evaluate reusable components and their licenses before reuse.

Also decide the initial phrase set, radio frequency/callsign, reply audience,
pilot-versus-gunner authority, clarification behavior and handling of overlapping
transmissions. These remain open, not approved requirements.

## Future validation sequence — only after authorization

1. Prove that a remote friend's SRS transmission reaches the receiving bot, with
   correct sender metadata and coalition/frequency filtering.
2. Validate the preferred local Whisper Turbo API with representative SRS audio,
   without changing mission state; compare with the existing dictation experience.
   Test accents, callsigns, numbers, noise, silence and ambiguous requests. Check
   app-server lifecycle/contended use before choosing direct reuse versus gateway.
3. Connect one read-only mission query, then one guarded action. Use Hidden
   Passage as an example adapter, not as the shared service's owner.
4. Test pilot/gunner identity, simultaneous users, repeated commands, re-slot,
   mission restart, stale replies and recognition/service failures. Measure latency.
5. Demonstrate reuse with a second mission and verify F10-only play still works
   when the entire voice service is absent.

## Research references

- [SRS](https://github.com/ciribob/DCS-SimpleRadioStandalone)
- [SkyEye architecture and limitations](https://github.com/dharmab/skyeye)
- [DCS-gRPC installation and API](https://github.com/DCS-gRPC/rust-server)
- [DCS-gRPC mission flag API](https://github.com/DCS-gRPC/rust-server/blob/main/protos/dcs/trigger/v0/trigger.proto)
- [OpenWhispr](https://github.com/OpenWhispr/openwhispr) — local installation
  1.10.3 and its bundled `src/helpers/whisperServer.js` were inspected directly;
  upstream documentation may describe a newer version.
- [whisper.cpp server API](https://github.com/ggml-org/whisper.cpp/tree/master/examples/server)
- [OpenWhispr public API](https://docs.openwhispr.com/api/overview) — distinguish
  its cloud transcription endpoint from the installed local inference server.

The components establish feasibility, not live acceptance of this proposed system.
This document records future work only; it does not authorize starting it today.
