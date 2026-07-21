import test from "node:test";
import assert from "node:assert/strict";
import {
  PET_IDENTITIES,
  PetPresentationStateMachine,
  healthTierForCharge,
} from "../src/pet-presentation-state.mjs";

const tierSpritesheets = {
  energetic: "energetic.webp",
  normal: "normal.webp",
  tired: "tired.webp",
  exhausted: "exhausted.webp",
};

const identitySpritesheets = {
  [PET_IDENTITIES.battery]: tierSpritesheets,
  [PET_IDENTITIES.whoopSensorB]: {
    energetic: "sensor-energetic.webp",
    normal: "sensor-normal.webp",
    tired: "sensor-tired.webp",
    exhausted: "sensor-exhausted.webp",
  },
};

function activeSnapshot(fields = {}) {
  return {
    available: true,
    enabled: true,
    petEnabled: true,
    petIdentity: PET_IDENTITIES.battery,
    ...fields,
  };
}

test("WHOOP Charge maps to the four locked health tiers", () => {
  assert.equal(healthTierForCharge(100), "energetic");
  assert.equal(healthTierForCharge(67), "energetic");
  assert.equal(healthTierForCharge(66), "normal");
  assert.equal(healthTierForCharge(34), "normal");
  assert.equal(healthTierForCharge(33), "tired");
  assert.equal(healthTierForCharge(1), "tired");
  assert.equal(healthTierForCharge(0), "exhausted");
  assert.equal(healthTierForCharge(-1), null);
  assert.equal(healthTierForCharge(101), null);
});

test("charge changes within a tier do not change its body revision", () => {
  const machine = new PetPresentationStateMachine();
  const initial = machine.applySnapshot(activeSnapshot({
    charge: 72,
    awardSequence: 10,
  }), 0);
  const revision = initial.tierRevision;

  assert.equal(machine.applySnapshot(activeSnapshot({
    charge: 68,
    awardSequence: 10,
  }), 10).tierRevision, revision);

  const crossed = machine.applySnapshot(activeSnapshot({
    charge: 66,
    awardSequence: 10,
  }), 20);
  assert.equal(crossed.tier, "normal");
  assert.equal(crossed.tierRevision, revision + 1);
});

test("a positive refill changes body immediately and queues one jump until Ready", () => {
  const machine = new PetPresentationStateMachine();
  machine.applySnapshot(activeSnapshot({
    charge: 20,
    awardSequence: 1,
  }), 0);
  machine.setLifecycleState("running", 1);

  const refilled = machine.applySnapshot(activeSnapshot({
    charge: 40,
    awardSequence: 2,
    appliedCharge: 20,
  }), 2);
  assert.equal(refilled.tier, "normal");
  assert.equal(refilled.lifecycleState, "running");
  assert.equal(refilled.transientState, null);
  assert.equal(refilled.pendingJump, true);

  const ready = machine.setLifecycleState("review", 100);
  assert.equal(ready.pendingJump, false);
  assert.equal(ready.transientState, "jumping");

  assert.equal(machine.advance(939).transientState, "jumping");
  assert.equal(machine.advance(940).transientState, null);
  assert.equal(machine.view(941).lifecycleState, "review");
});

test("multiple refills while busy coalesce into one bounded pending jump", () => {
  const machine = new PetPresentationStateMachine();
  machine.applySnapshot(activeSnapshot({ charge: 10, awardSequence: 1 }), 0);
  machine.setLifecycleState("waiting", 1);
  machine.applySnapshot(activeSnapshot({ charge: 15, awardSequence: 2, appliedCharge: 5 }), 2);
  machine.applySnapshot(activeSnapshot({ charge: 20, awardSequence: 3, appliedCharge: 5 }), 3);
  assert.equal(machine.view(3).pendingJump, true);

  assert.equal(machine.setLifecycleState("review", 4).transientState, "jumping");
  assert.equal(machine.advance(844).transientState, null);
  assert.equal(machine.advance(2000).transientState, null);
});

test("zero applied Charge never queues a workout jump", () => {
  const machine = new PetPresentationStateMachine();
  machine.applySnapshot(activeSnapshot({ charge: 100, awardSequence: 1 }), 0);
  machine.setLifecycleState("running", 1);
  const capped = machine.applySnapshot(activeSnapshot({
    charge: 100,
    awardSequence: 2,
    appliedCharge: 0,
  }), 2);
  assert.equal(capped.pendingJump, false);
});

test("important lifecycle changes preempt the workout transient", () => {
  const machine = new PetPresentationStateMachine();
  machine.applySnapshot(activeSnapshot({ charge: 50, awardSequence: 1 }), 0);
  machine.setLifecycleState("running", 1);
  machine.applySnapshot(activeSnapshot({ charge: 55, awardSequence: 2, appliedCharge: 5 }), 2);
  assert.equal(machine.setLifecycleState("review", 3).transientState, "jumping");
  assert.equal(machine.setLifecycleState("failed", 4).transientState, null);
  assert.equal(machine.view(4).lifecycleState, "failed");
});

test("native transients outrank a workout jump even while Ready", () => {
  const machine = new PetPresentationStateMachine();
  machine.applySnapshot(activeSnapshot({ charge: 50, awardSequence: 1 }), 0);
  machine.setLifecycleState("running", 1);
  machine.applySnapshot(activeSnapshot({
    charge: 55,
    awardSequence: 2,
    appliedCharge: 5,
  }), 2);
  machine.setLifecycleState("review", 3);

  const presentation = machine.presentation({
    originalSpritesheetUrl: "native.webp",
    originalSpriteVersion: 2,
    nativeTransientState: "running-left",
  }, identitySpritesheets, 4);
  assert.equal(presentation.transientState, "jumping");
  assert.equal(presentation.effectiveTransientState, "running-left");
});

test("Off and unavailable bridges pass through every native presentation input", () => {
  const machine = new PetPresentationStateMachine();
  machine.applySnapshot(activeSnapshot({ charge: 20, awardSequence: 1 }), 0);
  machine.setLifecycleState("waiting", 1);
  machine.applySnapshot(activeSnapshot({ charge: 30, awardSequence: 2, appliedCharge: 10 }), 2);

  machine.applySnapshot({ available: true, enabled: false, petEnabled: true, petIdentity: "battery", awardSequence: 2 }, 3);
  let presentation = machine.presentation({
    originalSpritesheetUrl: "native.webp",
    originalSpriteVersion: 1,
    nativeTransientState: "running-left",
  }, identitySpritesheets, 3);
  assert.equal(presentation.enabled, false);
  assert.equal(presentation.spritesheetUrl, "native.webp");
  assert.equal(presentation.spriteVersion, 1);
  assert.equal(presentation.effectiveTransientState, "running-left");
  assert.equal(presentation.pendingJump, false);

  machine.applySnapshot(activeSnapshot({ available: false, charge: 99 }), 4);
  presentation = machine.presentation({
    originalSpritesheetUrl: "native.webp",
    originalSpriteVersion: 2,
  }, identitySpritesheets, 4);
  assert.equal(presentation.enabled, false);
  assert.equal(presentation.spritesheetUrl, "native.webp");
});

test("enabling establishes an award baseline instead of replaying an old workout", () => {
  const machine = new PetPresentationStateMachine();
  machine.applySnapshot({ enabled: false, petEnabled: true, petIdentity: "battery", awardSequence: 20 }, 0);
  machine.setLifecycleState("review", 1);
  const enabled = machine.applySnapshot(activeSnapshot({
    charge: 70,
    awardSequence: 20,
    appliedCharge: 10,
  }), 2);
  assert.equal(enabled.transientState, null);
  assert.equal(enabled.pendingJump, false);
});

test("Pet submenu selection chooses one identity without changing Charge", () => {
  const machine = new PetPresentationStateMachine();
  const battery = machine.applySnapshot(activeSnapshot({ charge: 72, awardSequence: 1 }), 0);
  assert.equal(battery.identity, PET_IDENTITIES.battery);
  const batteryRevision = battery.tierRevision;

  const sensor = machine.applySnapshot(activeSnapshot({
    charge: 72,
    awardSequence: 1,
    petIdentity: PET_IDENTITIES.whoopSensorB,
  }), 1);
  assert.equal(sensor.charge, 72);
  assert.equal(sensor.tier, "energetic");
  assert.equal(sensor.identity, PET_IDENTITIES.whoopSensorB);
  assert.equal(sensor.tierRevision, batteryRevision + 1);

  const presentation = machine.presentation({
    originalSpritesheetUrl: "native.webp",
    originalSpriteVersion: 2,
  }, identitySpritesheets, 1);
  assert.equal(presentation.spritesheetUrl, "sensor-energetic.webp");
});

test("Pet Off, absent preference fields, and unknown identities restore stock", () => {
  const cases = [
    activeSnapshot({ charge: 50, petEnabled: false }),
    { available: true, enabled: true, charge: 50 },
    activeSnapshot({ charge: 50, petIdentity: "unknown" }),
  ];

  for (const snapshot of cases) {
    const machine = new PetPresentationStateMachine();
    const view = machine.applySnapshot(snapshot, 0);
    assert.equal(view.enabled, false);
    const presentation = machine.presentation({
      originalSpritesheetUrl: "native.webp",
      originalSpriteVersion: 1,
      nativeTransientState: "waiting",
    }, identitySpritesheets, 0);
    assert.equal(presentation.spritesheetUrl, "native.webp");
    assert.equal(presentation.spriteVersion, 1);
    assert.equal(presentation.effectiveTransientState, "waiting");
  }
});
