# CFF Ball Pit

CFF Ball Pit is a synchronized multiplayer 3D physics world for continuous AI
harnesses. Each participant inhabits a simple differential-drive robot with a
forward camera. Participants choose one action from the same frozen world state;
an authoritative Godot server resolves the barrier, advances bounded physics,
and releases the resulting observations together.

The project targets Godot 4.6 and integrates with both:

- `watch` through native AI SDK tools
- `watch-for-business` through an MCP server

Both adapters use the same harness-neutral loopback HTTP/SSE contract.

## Architecture

```text
Watch native tools                 Codex / MCP tools
        \                              /
         \---- participant HTTP -------/
                        |
                 Godot participant
             camera + replicated scene
                        |
                 reliable ENet RPC
                        |
          authoritative headless Godot server
       barrier + validation + 60 Hz physics substeps
```

The server is the only physics authority. Participant scenes render replicated
robot and ball transforms; they never determine collision outcomes.

## Run locally

Install JavaScript dependencies once:

```bash
npm install
```

Start the authority:

```bash
npm run server -- --deadline 20
```

Start two graphical participants:

```bash
npm run play -- --profile aster --name Aster
npm run play -- --profile finn --name Finn
```

Use `--headless` for agents that only need semantic state. Camera capture returns
HTTP 503 in a headless renderer.

Inspect running profile descriptors:

```bash
npm run players
```

Descriptors live under `.cff/runtimes/`. A live profile cannot be launched a
second time. Each profile receives a stable derived loopback port unless
`--control-port` is supplied.

## Decision frames

For frame `N`:

1. The server freezes the world and snapshots the active roster.
2. Every roster member receives `frame_ready`.
3. Each submits one clamped `{ throttle, steering, brake }` action.
4. Duplicate actions are idempotent; future actions are rejected.
5. At the barrier deadline, missing actions become neutral braking actions.
6. The server quantizes real decision duration to 0.25-second increments,
   clamps it to 0.25–2 simulated seconds, and runs 60 Hz physics substeps.
7. One authoritative robot-and-ball snapshot is released to all participants.
8. Each graphical participant renders its personalized forward camera.

Roster changes take effect only at frame boundaries. A disconnected participant
is removed from the barrier; the same profile may rejoin later.

## Participant interface

Every participant binds only to `127.0.0.1`.

- `GET /state` — connection, frame phase, roster, body pose, and latest result
- `POST /action` — submit a frame action
- `GET /stream` — semantic SSE events
- `GET /camera` — current camera PNG
- `GET /help` — discover the contract

Example:

```bash
BASE=http://127.0.0.1:38473
FRAME=$(curl -sS "$BASE/state" | jq .frame_id)
curl -sS -X POST "$BASE/action" \
  -H 'content-type: application/json' \
  --data "{\"frame_id\":$FRAME,\"throttle\":0.8,\"steering\":-0.2,\"brake\":false}"
curl -sS "$BASE/camera" > camera.png
```

SSE events include `frame_ready`, `frame_committed`, `frame_observation`,
registration and connection events, and action acknowledgements. Each event has
a concise natural-language `summary` plus structured fields. Configure this URL
as a waking SSE stream in either Watch harness:

```json
{
  "name": "game:frame",
  "url": "http://127.0.0.1:38473/stream",
  "subscribed": true,
  "waking": true
}
```

## Tool adapters

### Watch for Buzz / Codex MCP

Launch the included stdio MCP server with the participant URL in its environment:

```bash
CFF_GAME_CONTROL_URL=http://127.0.0.1:38473 npm run mcp-server
```

The MCP surface is:

- `game_state`
- `frame_action`

`frame_action` waits for authoritative resolution and returns semantic
proprioception plus an `image/png` MCP content block when the participant is
graphical.

Watch-for-Buzz now accepts optional `codex.mcpServers` entries. Merge
[`integrations/watch-for-buzz.config.fragment.json`](integrations/watch-for-buzz.config.fragment.json)
into the profile's `config.json` and replace the absolute adapter path.

```json
{
  "command": "node",
  "args": ["/absolute/path/to/adapters/mcp-server.mjs"],
  "env": {
    "CFF_GAME_CONTROL_URL": "http://127.0.0.1:38473"
  }
}
```

### Watch / AI SDK

Watch now accepts an optional `game` config entry and exposes `game_state` and
`frame_action` as native tools. Merge
[`integrations/watch.config.fragment.json`](integrations/watch.config.fragment.json)
into the instance `config.json`. Its `frame_action` uses AI SDK
`toModelOutput` to turn the returned PNG into a multimodal tool result rather
than burying the image in JSON.

[`adapters/watch-tools.mjs`](adapters/watch-tools.mjs) remains available as a
standalone AI SDK adapter for other harnesses.

Both adapters delegate to [`adapters/game-client.mjs`](adapters/game-client.mjs);
neither contains game rules.

## Audit and replay evidence

The server appends JSONL records for:

- server and peer lifecycle
- participant join/departure
- frame roster and opening
- normalized submitted and timeout-fallback actions
- chosen simulation delta and substep count
- complete authoritative robot and ball snapshot after every frame

The initial world uses a fixed random seed. Godot rigid-body physics is not
claimed to be bit-deterministic across platforms, so complete frame snapshots
are the replay and forensic authority; actions and timing explain how each
snapshot was reached.

## Verification

Run the complete suite:

```bash
npm test
```

It includes:

- Godot project parse/compile validation
- decision-contract unit assertions
- a real three-process headless smoke test
- two independent participant identities
- simultaneous movement and authoritative ball replication
- SSE handshake
- duplicate and future action behavior
- timeout fallback
- disconnect and same-profile rejoin
- audit-log coverage

Graphical camera verification can be performed on macOS by launching a normal
participant and fetching `/camera`; the expected output is a 960×540 PNG.
