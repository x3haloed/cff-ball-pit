import assert from "node:assert/strict";
import { mkdtemp, readFile, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const root = new URL("..", import.meta.url).pathname.replace(/\/$/, "");
const scratch = await mkdtemp(join(tmpdir(), "cff-ball-pit-"));
const audit = join(scratch, "events.jsonl");
const gamePort = 39190 + Math.floor(Math.random() * 300);
const alphaPort = gamePort + 1000;
const betaPort = gamePort + 1001;
const children = [];

function launch(args) {
  const child = spawn("godot", ["--headless", "--path", root, "--", ...args], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  child.stdout.on("data", (chunk) => (output += chunk));
  child.stderr.on("data", (chunk) => (output += chunk));
  child.output = () => output;
  children.push(child);
  return child;
}

async function json(url, init) {
  const response = await fetch(url, init);
  const text = await response.text();
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    throw new Error(`${url} returned ${response.status}: ${text}`);
  }
  return { response, value };
}

async function waitFor(check, label, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const result = await check();
      if (result) return result;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 75));
  }
  throw new Error(`Timed out waiting for ${label}${lastError ? `: ${lastError.message}` : ""}`);
}

function waitForExit(child, timeoutMs = 5_000) {
  if (child.exitCode != null) return Promise.resolve(child.exitCode);
  return Promise.race([
    new Promise((resolve) => child.once("exit", resolve)),
    new Promise((_, reject) => setTimeout(() => reject(new Error("process did not exit")), timeoutMs)),
  ]);
}

async function state(port) {
  const { response, value } = await json(`http://127.0.0.1:${port}/state`);
  assert.equal(response.status, 200);
  return value;
}

async function act(port, body) {
  return json(`http://127.0.0.1:${port}/action`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

try {
  const server = launch(["--mode", "server", "--port", String(gamePort), "--deadline", "0.75", "--audit", audit]);
  const alpha = launch(["--mode", "participant", "--profile", "alpha", "--name", "Alpha", "--port", String(gamePort), "--control-port", String(alphaPort), "--runtime-dir", join(scratch, "runtimes")]);
  const beta = launch(["--mode", "participant", "--profile", "beta", "--name", "Beta", "--port", String(gamePort), "--control-port", String(betaPort), "--runtime-dir", join(scratch, "runtimes")]);

  await waitFor(async () => {
    const [a, b] = await Promise.all([state(alphaPort), state(betaPort)]);
    return a.registered && b.registered && a.roster.length === 2 && b.roster.length === 2 && a.frame_id === b.frame_id;
  }, "two registered participants");

  const duplicateProfile = launch([
    "--mode", "participant", "--profile", "beta", "--name", "Duplicate Beta",
    "--port", String(gamePort), "--control-port", String(betaPort + 20),
    "--runtime-dir", join(scratch, "runtimes"),
  ]);
  assert.equal(await waitForExit(duplicateProfile), 3);

  const streamController = new AbortController();
  const streamResponse = await fetch(`http://127.0.0.1:${alphaPort}/stream`, { signal: streamController.signal });
  assert.equal(streamResponse.status, 200);
  const reader = streamResponse.body.getReader();
  const hello = new TextDecoder().decode((await reader.read()).value);
  assert.match(hello, /"kind":"hello"/);
  streamController.abort();

  const before = await state(alphaPort);
  const frame = before.frame_id;
  const alphaStart = before.personal_state.position;
  const [alphaAction, betaAction] = await Promise.all([
    act(alphaPort, { frame_id: frame, throttle: 1, steering: 0, brake: false }),
    act(betaPort, { frame_id: frame, throttle: 0.5, steering: 1, brake: false }),
  ]);
  assert.equal(alphaAction.response.status, 202);
  assert.equal(betaAction.response.status, 202);

  const resolved = await waitFor(async () => {
    const value = await state(alphaPort);
    return value.latest_result?.frame_id >= frame ? value : undefined;
  }, "authoritative frame resolution");
  assert.ok(resolved.latest_result.simulation_delta >= 0.25);
  assert.ok(resolved.latest_result.simulation_delta <= 2);
  assert.equal(resolved.latest_result.balls.length, 180);
  assert.notDeepEqual(resolved.personal_state.position, alphaStart);
  const replay = await act(alphaPort, { frame_id: frame, throttle: -1, steering: -1, brake: false });
  assert.equal(replay.response.status, 202);
  assert.equal(replay.value.replay_pending, true);

  const current = resolved.frame_id;
  const first = await act(alphaPort, { frame_id: current, throttle: 0, steering: 0, brake: true });
  const duplicate = await act(alphaPort, { frame_id: current, throttle: 1, steering: 1, brake: false });
  assert.equal(first.response.status, 202);
  assert.equal(duplicate.response.status, 202);

  const future = await act(betaPort, { frame_id: current + 50, brake: true });
  assert.equal(future.response.status, 409);
  assert.match(future.value.message, /Expected frame/);

  const betaCurrent = (await state(betaPort)).frame_id;
  const betaHold = await act(betaPort, { frame_id: betaCurrent, brake: true });
  assert.equal(betaHold.response.status, 202);
  await waitFor(async () => (await state(alphaPort)).latest_result?.frame_id >= current, "duplicate-action frame");

  const timeoutFrame = (await state(alphaPort)).frame_id;
  await act(alphaPort, { frame_id: timeoutFrame, brake: true });
  const timeoutResult = await waitFor(async () => {
    const value = await state(betaPort);
    return value.latest_result?.frame_id >= timeoutFrame ? value : undefined;
  }, "timeout fallback frame");
  assert.equal(timeoutResult.latest_result.frame_id, timeoutFrame);
  assert.notDeepEqual(timeoutResult.latest_result.balls, resolved.latest_result.balls);

  const mcp = new Client({ name: "smoke", version: "1.0.0" });
  const mcpTransport = new StdioClientTransport({
    command: process.execPath,
    args: [join(root, "adapters", "mcp-server.mjs")],
    env: {
      ...Object.fromEntries(Object.entries(process.env).filter((entry) => entry[1] !== undefined)),
      CFF_GAME_CONTROL_URL: `http://127.0.0.1:${alphaPort}`,
    },
  });
  await mcp.connect(mcpTransport);
  const listed = await mcp.listTools();
  assert.deepEqual(listed.tools.map((tool) => tool.name).sort(), ["frame_action", "game_state"]);
  const mcpState = await mcp.callTool({ name: "game_state", arguments: {} });
  assert.match(mcpState.content[0].text, /"participant_id":"alpha"/);
  const mcpFrame = (await state(alphaPort)).frame_id;
  const mcpAction = mcp.callTool({
    name: "frame_action",
    arguments: { frameId: mcpFrame, throttle: 0.2, steering: -0.2, brake: false },
  });
  await new Promise((resolve) => setTimeout(resolve, 100));
  await act(betaPort, { frame_id: mcpFrame, brake: true });
  const mcpResult = await mcpAction;
  assert.match(mcpResult.content[0].text, new RegExp(`"frame_id":${mcpFrame}`));
  assert.equal(mcpResult.content.some((part) => part.type === "image"), false);
  await mcp.close();

  beta.kill("SIGTERM");
  await waitFor(async () => (await state(alphaPort)).roster.length === 1, "disconnect roster update");
  await unlink(join(scratch, "runtimes", "beta.json"));

  const betaRejoin = launch(["--mode", "participant", "--profile", "beta", "--name", "Beta", "--port", String(gamePort), "--control-port", String(betaPort), "--runtime-dir", join(scratch, "runtimes")]);
  await waitFor(async () => {
    const value = await state(betaPort);
    return value.registered && value.roster.length === 2;
  }, "profile rejoin");

  const camera = await fetch(`http://127.0.0.1:${alphaPort}/camera`);
  assert.equal(camera.status, 503);

  const events = (await readFile(audit, "utf8")).trim().split("\n").map(JSON.parse);
  const kinds = new Set(events.map((event) => event.kind));
  for (const required of ["server_started", "participant_joined", "action_submitted", "action_duplicate", "action_replayed", "action_timeout_fallback", "frame_committed", "frame_resolved", "participant_departed"]) {
    assert.ok(kinds.has(required), `audit contains ${required}`);
  }
  assert.ok(events.some((event) => event.kind === "frame_committed" && Object.values(event.details.actions).some((action) => action.brake === true)));

  assert.equal(server.exitCode, null);
  assert.equal(alpha.exitCode, null);
  assert.equal(betaRejoin.exitCode, null);
  console.log("smoke: two-client barriers, physics, SSE, MCP, timeout, disconnect/rejoin, and audit passed");
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
