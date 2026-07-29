const DEFAULT_TIMEOUT_MS = 45_000;

export class GameClient {
  constructor(baseUrl, options = {}) {
    this.baseUrl = String(baseUrl).replace(/\/+$/, "");
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.pollMs = options.pollMs ?? 100;
  }

  async state() {
    return this.#json("/state");
  }

  async act(input) {
    const before = input.frameId ?? input.frame_id ? await this.state() : await this.readyState();
    const frameId = Number(input.frameId ?? input.frame_id ?? before.frame_id);
    const response = await this.#json("/action", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        frame_id: frameId,
        throttle: input.throttle ?? 0,
        steering: input.steering ?? 0,
        brake: input.brake ?? false,
      }),
    });
    const observation = await this.waitForFrame(frameId);
    const camera = await this.camera();
    return { response, observation, camera };
  }

  async readyState() {
    const deadline = Date.now() + this.timeoutMs;
    while (Date.now() < deadline) {
      const state = await this.state();
      const resolvedFrame = Number(state.latest_result?.frame_id ?? 0);
      if (
        state.registered &&
        state.accepting_actions &&
        Number(state.frame_id) > resolvedFrame &&
        Number(state.submitted_frame_id ?? 0) !== Number(state.frame_id)
      ) {
        return state;
      }
      await new Promise((resolve) => setTimeout(resolve, this.pollMs));
    }
    throw new Error("Timed out waiting for an open decision frame");
  }

  async waitForFrame(frameId) {
    const deadline = Date.now() + this.timeoutMs;
    while (Date.now() < deadline) {
      const state = await this.state();
      if (Number(state.latest_result?.frame_id ?? 0) >= frameId) {
        return state;
      }
      await new Promise((resolve) => setTimeout(resolve, this.pollMs));
    }
    throw new Error(`Timed out waiting for authoritative frame ${frameId}`);
  }

  async camera() {
    const response = await fetch(`${this.baseUrl}/camera`);
    if (response.status === 503) return undefined;
    if (!response.ok) {
      throw new Error(`GET /camera failed (${response.status}): ${await response.text()}`);
    }
    return Buffer.from(await response.arrayBuffer()).toString("base64");
  }

  async #json(path, init) {
    const response = await fetch(`${this.baseUrl}${path}`, init);
    const text = await response.text();
    let value;
    try {
      value = JSON.parse(text);
    } catch {
      throw new Error(`${path} returned non-JSON (${response.status}): ${text}`);
    }
    if (!response.ok) {
      throw new Error(`${path} failed (${response.status}): ${value.message ?? text}`);
    }
    return value;
  }
}

export function observationText(result) {
  const state = result.observation;
  const resolved = state.latest_result ?? {};
  return JSON.stringify({
    frame_id: resolved.frame_id,
    next_frame_id: state.frame_id,
    simulation_delta: resolved.simulation_delta,
    participant_id: state.participant_id,
    personal_state: state.personal_state,
    roster: state.roster,
  });
}
