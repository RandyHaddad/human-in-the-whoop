const MARKER = "__HITW_PET_RENDERER_PROOF_V1__";

export function rendererRuntimeSource({
  endpoint,
  assets,
}) {
  const config = JSON.stringify({
    endpoint,
    assets,
  });

  return String.raw`
/* ${MARKER} */
const __hitwConfig=${config};
const __hitwIdentityAssets=Object.fromEntries(Object.entries(__hitwConfig.assets).map(([e,t])=>[e,Object.fromEntries(Object.entries(t).map(([e,t])=>[e,new URL(t,import.meta.url).href]))]));
let __hitwSnapshot={available:false,enabled:false,petEnabled:false,petIdentity:null,charge:null,awardSequence:null,appliedCharge:0};
let __hitwIdentity=null;
let __hitwTier=null;
let __hitwTierRevision=0;
let __hitwLastAwardSequence=null;
let __hitwWasEnabled=false;
let __hitwPendingJump=false;
let __hitwPollStarted=false;
let __hitwPollFailures=0;
const __hitwListeners=new Set;
function __hitwTierForCharge(e){return Number.isInteger(e)&&e>=0&&e<=100?e===0?"exhausted":e<=33?"tired":e<=66?"normal":"energetic":null}
function __hitwNotify(){for(const e of __hitwListeners)e()}
function __hitwNormalize(e){const t=e?.available!==false,n=e?.enabled===true,r=e?.petEnabled===true,i=e?.petIdentity==="battery"||e?.petIdentity==="whoop-sensor-b"?e.petIdentity:null,a=Number.isInteger(e?.charge)?e.charge:null,o=t&&n&&r&&i!==null?__hitwTierForCharge(a):null;return{available:t,featureEnabled:n,petEnabled:r,enabled:o!==null,identity:o===null?null:i,charge:o===null?null:a,awardSequence:typeof e?.awardSequence==="string"||Number.isSafeInteger(e?.awardSequence)?e.awardSequence:null,appliedCharge:Number.isInteger(e?.appliedCharge)&&e.appliedCharge>=0?e.appliedCharge:0}}
function __hitwApplySnapshot(e){const t=__hitwNormalize(e),n=__hitwWasEnabled,r=__hitwTier,i=__hitwIdentity;__hitwSnapshot=t,__hitwIdentity=t.identity,__hitwTier=t.enabled?__hitwTierForCharge(t.charge):null,(__hitwTier!==r||__hitwIdentity!==i)&&(__hitwTierRevision+=1);if(!t.enabled)__hitwPendingJump=false,__hitwLastAwardSequence=t.awardSequence;else if(!n)__hitwLastAwardSequence=t.awardSequence,__hitwPendingJump=false;else if(t.awardSequence!==null&&t.awardSequence!==__hitwLastAwardSequence){__hitwLastAwardSequence=t.awardSequence,t.appliedCharge>0&&(__hitwPendingJump=true)}__hitwWasEnabled=t.enabled,__hitwNotify()}
async function __hitwPoll(){try{const e=await fetch(__hitwConfig.endpoint,{cache:"no-store"});if(!e.ok)throw Error("HTTP "+e.status);__hitwPollFailures=0,__hitwApplySnapshot(await e.json())}catch{__hitwPollFailures+=1,__hitwPollFailures>=3&&__hitwApplySnapshot({available:false,enabled:false})}}
function __hitwStartPolling(){__hitwPollStarted||(__hitwPollStarted=true,__hitwPoll(),window.setInterval(__hitwPoll,250))}
function __hitwUsePresentation(e,t,n,r){const[i,a]=Q.useState(0),[o,s]=Q.useState(null);Q.useEffect(()=>{const e=()=>a(e=>e+1);return __hitwListeners.add(e),__hitwStartPolling(),()=>__hitwListeners.delete(e)},[]),Q.useEffect(()=>{if(!__hitwSnapshot.enabled||e!=="review"||t!=null){o!==null&&s(null);return}o==null&&__hitwPendingJump&&(__hitwPendingJump=false,__hitwNotify(),s("jumping"))},[i,e,t,o]),Q.useEffect(()=>{if(o!=="jumping")return;const e=window.setTimeout(()=>s(null),840);return()=>window.clearTimeout(e)},[o]);const c=__hitwSnapshot.enabled?__hitwIdentityAssets[__hitwIdentity]?.[__hitwTier]:null;return{available:__hitwSnapshot.available,enabled:__hitwSnapshot.enabled,identity:__hitwIdentity,charge:__hitwSnapshot.charge,tier:__hitwTier,tierRevision:__hitwTierRevision,pendingJump:__hitwPendingJump,transientState:e==="review"?o:null,spritesheetUrl:c??n,spriteVersionNumber:c==null?r:2}}
`;
}

export function hasRendererProofMarker(source) {
  return source.includes(MARKER);
}

export { MARKER };
