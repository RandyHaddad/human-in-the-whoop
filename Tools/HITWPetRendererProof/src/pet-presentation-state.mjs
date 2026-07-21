export const READY_LIFECYCLE_STATE = "review";
export const JUMPING_LIFECYCLE_STATE = "jumping";
export const DEFAULT_JUMP_DURATION_MS = 840;

export const HEALTH_TIERS = Object.freeze({
  energetic: "energetic",
  normal: "normal",
  tired: "tired",
  exhausted: "exhausted",
});

export const PET_IDENTITIES = Object.freeze({
  battery: "battery",
  whoopSensorB: "whoop-sensor-b",
});

const VALID_PET_IDENTITIES = new Set(Object.values(PET_IDENTITIES));

const VALID_LIFECYCLE_STATES = new Set([
  "idle",
  "running-right",
  "running-left",
  "waving",
  "jumping",
  "failed",
  "waiting",
  "running",
  "review",
]);

export function healthTierForCharge(charge) {
  if (!Number.isInteger(charge) || charge < 0 || charge > 100) return null;
  if (charge === 0) return HEALTH_TIERS.exhausted;
  if (charge <= 33) return HEALTH_TIERS.tired;
  if (charge <= 66) return HEALTH_TIERS.normal;
  return HEALTH_TIERS.energetic;
}

export function normalizeSnapshot(value) {
  const available = value?.available !== false;
  const featureEnabled = value?.enabled === true;
  const petEnabled = value?.petEnabled === true;
  const identity = VALID_PET_IDENTITIES.has(value?.petIdentity)
    ? value.petIdentity
    : null;
  const charge = Number.isInteger(value?.charge) ? value.charge : null;
  const tier = available && featureEnabled && petEnabled && identity !== null
    ? healthTierForCharge(charge)
    : null;

  return {
    available,
    featureEnabled,
    petEnabled,
    enabled: tier !== null,
    identity: tier === null ? null : identity,
    charge: tier === null ? null : charge,
    awardSequence:
      typeof value?.awardSequence === "string" ||
      Number.isSafeInteger(value?.awardSequence)
        ? value.awardSequence
        : null,
    appliedCharge:
      Number.isInteger(value?.appliedCharge) && value.appliedCharge >= 0
        ? value.appliedCharge
        : 0,
  };
}

export class PetPresentationStateMachine {
  constructor({ jumpDurationMs = DEFAULT_JUMP_DURATION_MS } = {}) {
    if (!Number.isFinite(jumpDurationMs) || jumpDurationMs <= 0) {
      throw new TypeError("jumpDurationMs must be a positive number");
    }

    this.jumpDurationMs = jumpDurationMs;
    this.lifecycleState = "idle";
    this.available = false;
    this.enabled = false;
    this.identity = null;
    this.charge = null;
    this.tier = null;
    this.tierRevision = 0;
    this.lastAwardSequence = null;
    this.pendingJump = false;
    this.activeJumpUntilMs = null;
  }

  applySnapshot(value, nowMs = Date.now()) {
    const snapshot = normalizeSnapshot(value);
    const wasEnabled = this.enabled;
    const previousTier = this.tier;
    const previousIdentity = this.identity;

    this.available = snapshot.available;
    this.enabled = snapshot.enabled;
    this.identity = snapshot.identity;
    this.charge = snapshot.charge;
    this.tier = snapshot.enabled
      ? healthTierForCharge(snapshot.charge)
      : null;

    if (this.tier !== previousTier || this.identity !== previousIdentity) {
      this.tierRevision += 1;
    }

    if (!snapshot.enabled) {
      this.pendingJump = false;
      this.activeJumpUntilMs = null;
      this.lastAwardSequence = snapshot.awardSequence;
      return this.view(nowMs);
    }

    if (!wasEnabled) {
      // Enabling establishes a baseline. A workout that happened while Off
      // must not replay as a pet event.
      this.lastAwardSequence = snapshot.awardSequence;
      this.pendingJump = false;
    } else if (
      snapshot.awardSequence !== null &&
      snapshot.awardSequence !== this.lastAwardSequence
    ) {
      this.lastAwardSequence = snapshot.awardSequence;
      if (snapshot.appliedCharge > 0) this.pendingJump = true;
    }

    this.#reconcile(nowMs);
    return this.view(nowMs);
  }

  setLifecycleState(value, nowMs = Date.now()) {
    if (!VALID_LIFECYCLE_STATES.has(value)) {
      throw new TypeError(`Unsupported lifecycle state: ${value}`);
    }
    this.lifecycleState = value;
    this.#reconcile(nowMs);
    return this.view(nowMs);
  }

  advance(nowMs = Date.now()) {
    this.#reconcile(nowMs);
    return this.view(nowMs);
  }

  view(nowMs = Date.now()) {
    const jumpActive =
      this.enabled &&
      this.lifecycleState === READY_LIFECYCLE_STATE &&
      this.activeJumpUntilMs !== null &&
      nowMs < this.activeJumpUntilMs;

    return Object.freeze({
      available: this.available,
      enabled: this.enabled,
      identity: this.identity,
      charge: this.charge,
      tier: this.tier,
      tierRevision: this.tierRevision,
      lifecycleState: this.lifecycleState,
      pendingJump: this.pendingJump,
      transientState: jumpActive ? JUMPING_LIFECYCLE_STATE : null,
      lastAwardSequence: this.lastAwardSequence,
    });
  }

  presentation(
    { originalSpritesheetUrl, originalSpriteVersion, nativeTransientState = null },
    identitySpritesheets,
    nowMs = Date.now(),
  ) {
    const view = this.view(nowMs);
    if (!view.enabled) {
      return Object.freeze({
        ...view,
        spritesheetUrl: originalSpritesheetUrl,
        spriteVersion: originalSpriteVersion,
        effectiveTransientState: nativeTransientState,
      });
    }

    return Object.freeze({
      ...view,
      spritesheetUrl:
        identitySpritesheets?.[view.identity]?.[view.tier] ?? originalSpritesheetUrl,
      spriteVersion:
        identitySpritesheets?.[view.identity]?.[view.tier] == null
          ? originalSpriteVersion
          : 2,
      effectiveTransientState:
        view.lifecycleState === READY_LIFECYCLE_STATE
          ? (nativeTransientState ?? view.transientState)
          : nativeTransientState,
    });
  }

  #reconcile(nowMs) {
    if (!Number.isFinite(nowMs)) throw new TypeError("nowMs must be finite");

    if (!this.enabled) {
      this.activeJumpUntilMs = null;
      return;
    }

    if (this.lifecycleState !== READY_LIFECYCLE_STATE) {
      // Health must never obscure Running, Needs input, or Blocked.
      this.activeJumpUntilMs = null;
      return;
    }

    if (
      this.activeJumpUntilMs !== null &&
      nowMs >= this.activeJumpUntilMs
    ) {
      this.activeJumpUntilMs = null;
    }

    if (this.activeJumpUntilMs === null && this.pendingJump) {
      this.pendingJump = false;
      this.activeJumpUntilMs = nowMs + this.jumpDurationMs;
    }
  }
}
