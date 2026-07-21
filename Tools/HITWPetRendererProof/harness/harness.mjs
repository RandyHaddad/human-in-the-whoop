import {
  PetPresentationStateMachine,
} from "/src/pet-presentation-state.mjs";

const machine = new PetPresentationStateMachine();
const pet = document.querySelector("#pet");
const lifecycleSelect = document.querySelector("#lifecycle-select");
const batterySpritesheets = {
  energetic: "/assets/energetic.webp",
  normal: "/assets/normal.webp",
  tired: "/assets/tired.webp",
  exhausted: "/assets/exhausted.webp",
};
const identitySpritesheets = {
  battery: batterySpritesheets,
  "whoop-sensor-b": batterySpritesheets,
};
const rowDefinitions = {
  idle: { row: 0, frames: 6, duration: 210 },
  jumping: { row: 4, frames: 5, duration: 140 },
  failed: { row: 5, frames: 8, duration: 140 },
  waiting: { row: 6, frames: 6, duration: 150 },
  running: { row: 7, frames: 6, duration: 120 },
  review: { row: 8, frames: 6, duration: 150 },
};

let lastSnapshot = null;
let stateStartedAt = performance.now();
let lastEffectiveState = "idle";

function updateReadout(view, effectiveState) {
  document.querySelector("#enabled").textContent = view.enabled ? "On" : "Off";
  document.querySelector("#charge").textContent = view.charge == null ? "—" : `${view.charge}/100`;
  document.querySelector("#tier").textContent = view.tier ?? "native";
  document.querySelector("#identity").textContent = view.identity ?? "stock";
  document.querySelector("#tier-revision").textContent = String(view.tierRevision);
  document.querySelector("#lifecycle").textContent = view.lifecycleState;
  document.querySelector("#effective-state").textContent = effectiveState;
  document.querySelector("#pending").textContent = view.pendingJump ? "yes" : "no";

  document.body.dataset.hitwEnabled = String(view.enabled);
  document.body.dataset.hitwTier = view.tier ?? "native";
  document.body.dataset.hitwIdentity = view.identity ?? "stock";
  document.body.dataset.hitwTierRevision = String(view.tierRevision);
  document.body.dataset.hitwLifecycle = view.lifecycleState;
  document.body.dataset.hitwEffectiveState = effectiveState;
  document.body.dataset.hitwPendingJump = String(view.pendingJump);
}

function renderFrame(now) {
  const view = machine.advance(Date.now());
  const effectiveState = view.transientState ?? view.lifecycleState;
  if (effectiveState !== lastEffectiveState) {
    lastEffectiveState = effectiveState;
    stateStartedAt = now;
  }
  const definition = rowDefinitions[effectiveState] ?? rowDefinitions.idle;
  const frame = Math.floor((now - stateStartedAt) / definition.duration) % definition.frames;
  const spritesheet = view.enabled
    ? identitySpritesheets[view.identity][view.tier]
    : batterySpritesheets.energetic;
  pet.style.backgroundImage = `url(${spritesheet})`;
  pet.style.backgroundPosition = `${frame / 7 * 100}% ${definition.row / 10 * 100}%`;
  pet.dataset.state = effectiveState;
  pet.dataset.tier = view.tier ?? "native";
  updateReadout(view, effectiveState);
  requestAnimationFrame(renderFrame);
}

async function poll() {
  try {
    const response = await fetch("/v1/pet", { cache: "no-store" });
    const next = await response.json();
    const serialized = JSON.stringify(next);
    if (serialized !== lastSnapshot) {
      lastSnapshot = serialized;
      machine.applySnapshot(next, Date.now());
    }
  } catch {
    machine.applySnapshot({ available: false, enabled: false }, Date.now());
  }
}

lifecycleSelect.addEventListener("change", () => {
  machine.setLifecycleState(lifecycleSelect.value, Date.now());
});

for (const button of document.querySelectorAll("[data-snapshot]")) {
  button.addEventListener("click", async () => {
    await fetch("/v1/test/snapshot", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: button.dataset.snapshot,
    });
    await poll();
  });
}

document.querySelector("#refill").addEventListener("click", async () => {
  const current = machine.view(Date.now()).charge ?? 20;
  await fetch("/v1/test/refill", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ charge: Math.min(100, current + 20), appliedCharge: 20 }),
  });
  await poll();
});

document.querySelector("#off").addEventListener("click", async () => {
  await fetch("/v1/test/off", { method: "POST" });
  await poll();
});

machine.setLifecycleState(lifecycleSelect.value, Date.now());
await poll();
window.setInterval(poll, 100);
requestAnimationFrame(renderFrame);
