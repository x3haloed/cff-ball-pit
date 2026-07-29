import { tool } from "ai";
import { z } from "zod";
import { GameClient, observationText } from "./game-client.mjs";

export function createCffGameTools(baseUrl = process.env.CFF_GAME_CONTROL_URL ?? "http://127.0.0.1:38473") {
  const client = new GameClient(baseUrl);
  return {
    game_state: tool({
      description: "Inspect the current synchronized game frame, body state, roster, and latest result.",
      inputSchema: z.object({}),
      execute: () => client.state(),
    }),
    frame_action: tool({
      description: "Submit one body action, wait for the shared physics step, and see the resulting camera frame.",
      inputSchema: z.object({
        frameId: z.number().int().optional(),
        kind: z.enum(["drive", "hold"]).default("drive").describe(
          "Use hold for an authored stationary braking action with provenance distinct from a timeout.",
        ),
        throttle: z.number().min(-1).max(1).default(0),
        steering: z.number().min(-1).max(1).default(0),
        brake: z.boolean().default(false),
        cameraTier: z.enum(["standard", "inspection"]).default("standard").describe(
          "standard returns a compact 960x180 temporal contact strip; inspection returns one higher-detail 960x540 final view.",
        ),
      }),
      execute: (input) => client.act(input),
      toModelOutput: ({ output }) => ({
        type: "content",
        value: [
          { type: "text", text: observationText(output) },
          ...(output.camera
            ? [{ type: "media", data: output.camera, mediaType: "image/webp" }]
            : []),
        ],
      }),
    }),
  };
}
