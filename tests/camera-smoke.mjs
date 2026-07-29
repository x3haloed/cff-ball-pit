import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { GameClient } from "../adapters/game-client.mjs";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const root = new URL("..", import.meta.url).pathname.replace(/\/$/, "");
const scratch = await mkdtemp(join(tmpdir(), "cff-camera-"));
const gamePort = 39700 + Math.floor(Math.random() * 200);
const controlPort = gamePort + 400;
const children = [];

function launch(args) {
  const child = spawn("godot", args, { stdio: ["ignore", "pipe", "pipe"] });
  let output = "";
  child.stdout.on("data", (chunk) => (output += chunk));
  child.stderr.on("data", (chunk) => (output += chunk));
  child.output = () => output;
  children.push(child);
  return child;
}

async function waitFor(check, label, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  let error;
  while (Date.now() < deadline) {
    try {
      const result = await check();
      if (result) return result;
    } catch (caught) {
      error = caught;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`Timed out waiting for ${label}${error ? `: ${error.message}` : ""}`);
}

try {
  launch([
    "--headless", "--path", root, "--", "--mode", "server",
    "--port", String(gamePort), "--deadline", "3",
    "--audit", join(scratch, "events.jsonl"),
  ]);
  launch([
    "--path", root, "--", "--mode", "participant",
    "--profile", "camera", "--name", "Camera",
    "--port", String(gamePort), "--control-port", String(controlPort),
    "--runtime-dir", join(scratch, "runtimes"),
  ]);
  const client = new GameClient(`http://127.0.0.1:${controlPort}`, { timeoutMs: 15_000 });
  await waitFor(async () => (await client.state()).registered, "graphical participant");
  const mcp = new Client({ name: "camera-smoke", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [join(root, "adapters", "mcp-server.mjs")],
    env: {
      ...Object.fromEntries(Object.entries(process.env).filter((entry) => entry[1] !== undefined)),
      CFF_GAME_CONTROL_URL: `http://127.0.0.1:${controlPort}`,
    },
  });
  await mcp.connect(transport);
  const result = await mcp.callTool({
    name: "frame_action",
    arguments: { throttle: 0.5, steering: 0.15, brake: false },
  });
  const image = result.content.find((part) => part.type === "image");
  assert.ok(image && image.type === "image", "graphical MCP frame_action returns an image content block");
  const png = Buffer.from(image.data, "base64");
  assert.deepEqual([...png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  assert.equal(png.readUInt32BE(16), 960);
  assert.equal(png.readUInt32BE(20), 540);
  assert.match(result.content[0].text, /"personal_state"/);
  await mcp.close();
  const state = await client.state();
  assert.equal(state.latest_result.frame_id + 1, state.frame_id);
  assert.equal(state.latest_result.balls.length, 180);
  console.log(`camera: graphical MCP frame_action returned a ${png.length}-byte 960x540 PNG`);
} catch (error) {
  for (const child of children) {
    const output = child.output();
    if (output.trim()) process.stderr.write(`\n--- child output ---\n${output}\n`);
  }
  throw error;
} finally {
  for (const child of children) {
    if (child.exitCode == null) child.kill("SIGTERM");
  }
}
