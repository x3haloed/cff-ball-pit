#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdir, readFile, readdir, unlink } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(new URL("..", import.meta.url).pathname);
const command = process.argv[2] ?? "help";
const values = process.argv.slice(3);
const value = (name, fallback) => {
  const index = values.indexOf(`--${name}`);
  return index >= 0 && values[index + 1] ? values[index + 1] : fallback;
};

if (command === "server") {
  launch([
    "--headless", "--path", root, "--",
    "--mode", "server",
    "--port", value("port", "39090"),
    "--deadline", value("deadline", "20"),
    "--audit", value("audit", resolve(root, ".cff/server-events.jsonl")),
  ]);
} else if (command === "play") {
  const profile = value("profile");
  if (!profile) throw new Error("play requires --profile NAME");
  const runtimeDir = resolve(root, ".cff/runtimes");
  await mkdir(runtimeDir, { recursive: true });
  const descriptor = resolve(runtimeDir, `${safeFilename(profile)}.json`);
  await removeStaleDescriptor(descriptor);
  const args = [
    "--path", root, "--",
    "--mode", "participant",
    "--profile", profile,
    "--name", value("name", profile),
    "--host", value("host", "127.0.0.1"),
    "--port", value("port", "39090"),
    "--control-port", value("control-port", String(profilePort(profile))),
    "--runtime-dir", runtimeDir,
  ];
  if (values.includes("--headless")) args.unshift("--headless");
  launch(args);
} else if (command === "players") {
  const runtimeDir = resolve(root, ".cff/runtimes");
  const entries = await readdir(runtimeDir).catch(() => []);
  const rows = [];
  for (const entry of entries.filter((name) => name.endsWith(".json"))) {
    try {
      rows.push(JSON.parse(await readFile(resolve(runtimeDir, entry), "utf8")));
    } catch {}
  }
  console.log(JSON.stringify(rows, null, 2));
} else {
  console.log(`Usage:
  node tools/launch.mjs server [--port 39090] [--deadline 20]
  node tools/launch.mjs play --profile aster [--name Aster] [--headless]
  node tools/launch.mjs players`);
}

function launch(args) {
  const child = spawn("godot", args, { cwd: root, stdio: "inherit" });
  for (const signal of ["SIGINT", "SIGTERM"]) {
    process.on(signal, () => child.kill(signal));
  }
  child.on("exit", (code) => process.exit(code ?? 0));
}

function profilePort(profile) {
  let hash = 2166136261;
  for (const char of profile) {
    hash ^= char.codePointAt(0);
    hash = Math.imul(hash, 16777619);
  }
  return 38473 + (Math.abs(hash) % 1000);
}

async function removeStaleDescriptor(path) {
  try {
    const descriptor = JSON.parse(await readFile(path, "utf8"));
    const pid = Number(descriptor.pid);
    if (pid > 0) {
      try {
        process.kill(pid, 0);
        throw new Error(`Profile ${descriptor.profile ?? ""} is already running with pid ${pid}.`);
      } catch (error) {
        if (error?.code !== "ESRCH") throw error;
      }
    }
    await unlink(path);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

function safeFilename(value) {
  return value.replace(/[^a-zA-Z0-9._-]+/g, "_");
}
