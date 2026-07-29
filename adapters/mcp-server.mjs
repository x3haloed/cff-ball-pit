import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { GameClient, observationText } from "./game-client.mjs";

const baseUrl = process.env.CFF_GAME_CONTROL_URL ?? "http://127.0.0.1:38473";
const client = new GameClient(baseUrl);
const server = new McpServer({ name: "cff-ball-pit", version: "0.1.0" });

server.tool("game_state", "Inspect the current decision frame, body state, roster, and latest authoritative result.", {}, async () => ({
  content: [{ type: "text", text: JSON.stringify(await client.state()) }],
}));

server.tool(
  "frame_action",
  "Submit one action for the current synchronized decision frame. Waits for the authoritative barrier and returns the resulting camera view and proprioception.",
  {
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
  },
  async (input) => {
    const result = await client.act(input);
    const content = [{ type: "text", text: observationText(result) }];
    if (result.camera) content.push({ type: "image", data: result.camera, mimeType: "image/webp" });
    return { content };
  },
);

await server.connect(new StdioServerTransport());
