# Human in the Whoop native pets

This folder contains the production and verification assets for two selectable native Codex pet identities: **Battery** and **WHOOP Sensor B**.

Both identities read the same immutable Human in the Whoop presentation state. The renderer selects one identity and then derives its health atlas from Charge:

| Charge | Tier | Battery | WHOOP Sensor B |
|---:|---|---|---|
| 67–100 | energetic | Three green filled cells; upright and energetic | Green side light; upright and energetic |
| 34–66 | normal | Two yellow filled cells; one dark empty cell | Yellow side light; neutral body |
| 1–33 | tired | One red filled cell; two dark empty cells; visibly tired | Red side light; visibly tired body |
| 0 | exhausted | All cells dark/empty; exhausted body | Side light off; collapsed but readable body |

Feature Off is not a fifth health atlas. Off bypasses every Human in the Whoop pet asset and restores the stock Codex pet with unchanged lifecycle inputs.

## Locked visual contract

- Match the current native Codex pets: crisp chunky pixel art, compact silhouette, restrained palette, simple face, readable at `192x208`, and no text or logos.
- Each health variant is a complete V2 `1536x2288` atlas with all nine standard lifecycle rows and all sixteen look directions.
- Health posture may change the body, but it may never replace or obscure Codex lifecycle meaning.
- Battery segment fill and Sensor B's small side light are health indicators, not lifecycle indicators.
- The exhausted body may collapse, but Running, Needs input, Ready, and Blocked must remain readable.
- Identity, proportions, materials, face construction, and indicator location stay stable within each pet family.

`references/` holds the user-approved earlier concepts. `runs/` holds one independent hatch-pet run per identity and tier. Final overview sheets and consolidated evidence will be written under `qa/` after all eight atlases pass.
