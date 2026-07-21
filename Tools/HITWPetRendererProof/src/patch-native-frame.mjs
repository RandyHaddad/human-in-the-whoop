import { rendererRuntimeSource, hasRendererProofMarker } from "./renderer-runtime-source.mjs";

const COMPONENT_ANCHOR = "function rt({";
const HOOK_ANCHOR = "ve=ae(v[0]),[ye,be]";
const PROPS_ANCHOR =
  "spriteVersionNumber:i.spriteVersionNumber,spritesheetUrl:i.spritesheetUrl,state:ve.mascotState,style:p,transientState:f";
const MAIN_DATA_ANCHOR =
  '"data-avatar-overlay-debug-window-border":o||void 0,';

function replaceExactlyOnce(source, anchor, replacement, label) {
  const first = source.indexOf(anchor);
  const last = source.lastIndexOf(anchor);
  if (first === -1) throw new Error(`Missing ${label} anchor`);
  if (first !== last) throw new Error(`Ambiguous ${label} anchor`);
  return source.replace(anchor, replacement);
}

export function patchNativeFrameSource(source, configuration) {
  if (hasRendererProofMarker(source)) {
    throw new Error("Renderer is already patched with the HITW proof");
  }

  let result = replaceExactlyOnce(
    source,
    COMPONENT_ANCHOR,
    `${rendererRuntimeSource(configuration)}${COMPONENT_ANCHOR}`,
    "component",
  );

  result = replaceExactlyOnce(
    result,
    HOOK_ANCHOR,
    "ve=ae(v[0]),__hitwPresentation=__hitwUsePresentation(ve.mascotState,f,i?.spritesheetUrl,i?.spriteVersionNumber),[ye,be]",
    "hook",
  );

  result = replaceExactlyOnce(
    result,
    PROPS_ANCHOR,
    "spriteVersionNumber:__hitwPresentation.spriteVersionNumber,spritesheetUrl:__hitwPresentation.spritesheetUrl,state:ve.mascotState,style:p,transientState:f??(ve.mascotState===`review`?__hitwPresentation.transientState:null)",
    "mascot props",
  );

  result = replaceExactlyOnce(
    result,
    MAIN_DATA_ANCHOR,
    `${MAIN_DATA_ANCHOR}"data-hitw-enabled":__hitwPresentation.enabled||void 0,"data-hitw-identity":__hitwPresentation.enabled?__hitwPresentation.identity:void 0,"data-hitw-tier":__hitwPresentation.enabled?__hitwPresentation.tier:void 0,"data-hitw-tier-revision":__hitwPresentation.enabled?__hitwPresentation.tierRevision:void 0,"data-hitw-pending-jump":__hitwPresentation.enabled?__hitwPresentation.pendingJump:void 0,"data-hitw-transient-state":__hitwPresentation.transientState??void 0,`,
    "main data",
  );

  return result;
}
