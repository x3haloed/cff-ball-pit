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

function webpDimensions(buffer) {
  assert.equal(buffer.toString("ascii", 0, 4), "RIFF");
  assert.equal(buffer.toString("ascii", 8, 12), "WEBP");
  const chunk = buffer.toString("ascii", 12, 16);
  if (chunk === "VP8 ") {
    assert.deepEqual([...buffer.subarray(23, 26)], [157, 1, 42]);
    return {
      width: buffer.readUInt16LE(26) & 0x3fff,
      height: buffer.readUInt16LE(28) & 0x3fff,
    };
  }
  if (chunk === "VP8L") {
    assert.equal(buffer[20], 0x2f);
    const bits = buffer.readUInt32LE(21);
    return {
      width: (bits & 0x3fff) + 1,
      height: ((bits >>> 14) & 0x3fff) + 1,
    };
  }
  if (chunk === "VP8X") {
    return {
      width: buffer.readUIntLE(24, 3) + 1,
      height: buffer.readUIntLE(27, 3) + 1,
    };
  }
  throw new Error(`Unsupported WebP chunk ${JSON.stringify(chunk)}`);
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
  assert.equal(image.mimeType, "image/webp");
  const standardWebp = Buffer.from(image.data, "base64");
  assert.deepEqual(webpDimensions(standardWebp), { width: 960, height: 180 });
  assert.match(result.content[0].text, /"personal_state"/);

  const inspectionResult = await mcp.callTool({
    name: "frame_action",
    arguments: {
      kind: "hold",
      cameraTier: "inspection",
    },
  });
  const inspectionImage = inspectionResult.content.find((part) => part.type === "image");
  assert.ok(inspectionImage && inspectionImage.type === "image");
  assert.equal(inspectionImage.mimeType, "image/webp");
  const inspectionWebp = Buffer.from(inspectionImage.data, "base64");
  assert.deepEqual(webpDimensions(inspectionWebp), { width: 960, height: 540 });
  assert.match(inspectionResult.content[0].text, /"action_kind":"hold"/);

  await mcp.close();
  const state = await client.state();
  assert.equal(state.latest_result.frame_id + 1, state.frame_id);
  assert.deepEqual(
    Object.keys(state.latest_result).sort(),
    ["action_kind", "frame_id", "replayed", "simulation_delta", "timed_out"].sort(),
  );
  assert.equal(state.latest_result.action_kind, "hold");
  assert.equal("balls" in state.latest_result, false);
  assert.equal("participants" in state.latest_result, false);
  console.log(
    `camera: MCP returned ${standardWebp.length}-byte 960x180 contact strip and ` +
      `${inspectionWebp.length}-byte 960x540 WebP frames`,
  );
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
