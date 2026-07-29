# Completion verification

Verified on 2026-07-28 with Godot `4.6.3.stable.official.7d41c59c4`.

| Requirement | Authoritative implementation | Verification evidence |
| --- | --- | --- |
| Godot 4 3D physics | `WorldBuilder` creates a 3D arena, ramp, 180 `RigidBody3D` balls, and wheeled robot bodies. | Godot parse gate; smoke test asserts 180 changing authoritative ball transforms; graphical PNG shows the arena and balls. |
| Dedicated authoritative headless server | `server_runtime.gd` is the only process that advances robot and ball physics. | Smoke test launches the server with `--headless`, then verifies replicated results from two clients. |
| Native multiplayer | Reliable ENet RPC carries registration, framed actions, commits, snapshots, and replays. | Three-process smoke test proves two distinct identities share each frame and receive one authoritative result. |
| Wheeled AI bodies and cameras | Differential-drive controls operate a robot rendered with two wheels; each graphical client owns a forward `Camera3D`. | Movement assertions plus graphical camera test. |
| Synchronized decision barrier | `frame_participants` freezes the active roster; `_all_actions_present` or the default 45-second deadline closes the barrier. Physics remains paused outside committed substeps, and decision cadence remains capped at 2 simulated seconds. | Smoke test submits both actions, omits one action for timeout, and disconnects a barrier member; contract tests assert the 2-second simulation cap. |
| Time derived from decision cadence | Wall duration between resolved frames is quantized to 0.25 seconds and clamped to 0.25–2 simulated seconds; each interval runs at 60 substeps/second. | Seven contract assertions and smoke assertions on authoritative `simulation_delta`. |
| Simultaneous next-frame release | One complete authoritative snapshot is created after the final substep and sent to every frame participant before the next frame opens. | Both clients report the same resolved frame and replicated roster; audit contains one `frame_resolved` snapshot per commit. |
| Tool action returns camera | Shared client waits for the requested frame, then retrieves either a standard 960×180 contact strip with authoritative samples near 25%, 60%, and 100%, or one inspection-tier 960×540 final-frame WebP; MCP emits `image/webp`, and Watch converts it through `toModelOutput`. | Graphical MCP smoke receives and validates both WebP result shapes; Watch unit test validates multimodal media output. |
| Semantic/camera readiness separation | Participant state publishes `latest_result.frame_id` before rendering and advances `camera_frame_id` only after the strip and restored final view are ready. The client waits on both monotonic markers separately. | Headless smoke asserts authoritative and camera-ready progress; graphical smoke asserts the camera-ready frame matches the returned consequence. |
| Harness-neutral HTTP/SSE | Per-profile loopback exposes `/state`, `/action`, `/stream`, `/camera`, and `/help`. | Smoke test uses HTTP actions/state and parses an SSE `hello`. |
| Watch native tools | Optional `game` config adds `game_state` and `frame_action` to Watch's native AI SDK tool set. | Watch typecheck, build, 65-test suite, and focused multimodal game-tool test pass. |
| Watch-for-Buzz MCP | Optional protected `codex.mcpServers` config merges the game MCP next to `wfb-memory`; game MCP exposes `game_state` and `frame_action`. | WFB typecheck, build, 68-test suite, configuration test, and real stdio MCP smoke pass. |
| Profile isolation | Stable profile-derived ports, runtime descriptors, duplicate descriptor rejection, and authority-side identity rejection. | Smoke test proves duplicate-profile process exits and later same-profile rejoin succeeds after departure. |
| Timeout fallback | Missing actions become explicit neutral braking actions and receive an audit event. | Smoke requires `action_timeout_fallback` and observes the timed-out frame resolve. |
| Authored hold provenance | `kind: "hold"` mechanically brakes but remains distinct from the server-authored `timeout_brake` fallback in returned observations and audit records. | Contract unit test and multi-process smoke assert both provenance values through submission, resolution, and audit. |
| Stale/duplicate/future safety | Server stores 64 results, replays stale frames without applying them, treats repeat submissions as duplicates, and rejects future frames. | Smoke requires `action_replayed` and `action_duplicate`, and asserts future HTTP conflict. |
| Disconnect/rejoin | Disconnect removes the participant from the current barrier and body roster; profile may reconnect at a later frame boundary. | Multi-process smoke kills Beta, observes roster size one, then rejoins Beta. |
| Headless operation | Server and semantic participants run with Godot's headless renderer; camera reports HTTP 503 when unavailable. | Portable smoke is fully headless and asserts `/camera` returns 503. |
| Replay/audit evidence | Fixed initial RNG seed plus JSONL lifecycle, normalized actions, timing/substeps, timeout, and complete post-frame robot/ball snapshots. | Smoke parses the JSONL file and requires every consequence-bearing event kind. |
| Documentation | Root README covers architecture, commands, protocol, adapters, audit posture, and verification. Both harness READMEs and example configs document their optional integrations. | Files inspected after final suite. |

## Final commands

```bash
# Game, headless integration, real stdio MCP, and graphical camera MCP
npm run test:all

# watch
npm run typecheck
npm run build
npm test

# watch-for-business
npm run typecheck
npm run build
npm test
```

Final results:

- Game contract: 8 assertions passed.
- Game headless smoke: two-client barrier, physics, SSE, MCP, timeout,
  disconnect/rejoin, and audit passed.
- Graphical MCP smoke: valid 960×180 temporal contact-strip and 960×540 final-frame inspection WebPs were returned by `frame_action`.
- Watch: typecheck and build passed; 65 tests passed.
- Watch-for-Buzz: typecheck and build passed; 68 tests passed.
