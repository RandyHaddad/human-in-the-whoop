import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  DEFAULT_CODEX_APP,
  extractAssetBuffer,
  inspectCurrentRenderer,
} from "./lib/codex-bundle.mjs";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const proofRoot = path.dirname(scriptDirectory);
const inspection = inspectCurrentRenderer(
  process.env.HITW_CODEX_APP ?? DEFAULT_CODEX_APP,
);
const port = Number(process.env.HITW_PET_PROOF_PORT ?? 49797);

let snapshot = {
  available: true,
  enabled: false,
  petEnabled: false,
  petIdentity: null,
  charge: null,
  awardSequence: 0,
  appliedCharge: 0,
};

const assets = Object.fromEntries(
  Object.keys(inspection.assets).map((tier) => [
    tier,
    extractAssetBuffer(inspection, tier),
  ]),
);

function send(response, status, body, contentType = "application/json") {
  response.writeHead(status, {
    "Access-Control-Allow-Headers": "content-type",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Private-Network": "true",
    "Cache-Control": "no-store",
    "Content-Type": contentType,
  });
  response.end(body);
}

function sendJson(response, status, value) {
  send(response, status, `${JSON.stringify(value)}\n`);
}

async function jsonBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 64 * 1024) throw new Error("Request body is too large");
    chunks.push(chunk);
  }
  if (chunks.length === 0) return {};
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function staticFile(response, relativePath, contentType) {
  const filePath = path.resolve(proofRoot, relativePath);
  if (!filePath.startsWith(`${proofRoot}${path.sep}`)) {
    sendJson(response, 403, { error: "forbidden" });
    return;
  }
  send(response, 200, fs.readFileSync(filePath), contentType);
}

const server = http.createServer(async (request, response) => {
  try {
    if (request.method === "OPTIONS") {
      send(response, 204, "");
      return;
    }

    const url = new URL(request.url ?? "/", `http://${request.headers.host}`);
    if (request.method === "GET" && url.pathname === "/v1/pet") {
      sendJson(response, 200, snapshot);
      return;
    }
    if (request.method === "GET" && url.pathname === "/v1/test/state") {
      sendJson(response, 200, snapshot);
      return;
    }
    if (request.method === "POST" && url.pathname === "/v1/test/snapshot") {
      const body = await jsonBody(request);
      snapshot = {
        ...snapshot,
        ...body,
        available: body.available ?? true,
      };
      sendJson(response, 200, snapshot);
      return;
    }
    if (request.method === "POST" && url.pathname === "/v1/test/refill") {
      const body = await jsonBody(request);
      snapshot = {
        ...snapshot,
        available: true,
        enabled: true,
        petEnabled: true,
        petIdentity: snapshot.petIdentity ?? "battery",
        charge: body.charge,
        awardSequence: Number(snapshot.awardSequence ?? 0) + 1,
        appliedCharge: body.appliedCharge,
      };
      sendJson(response, 200, snapshot);
      return;
    }
    if (request.method === "POST" && url.pathname === "/v1/test/off") {
      snapshot = {
        ...snapshot,
        available: true,
        enabled: false,
        petEnabled: false,
        petIdentity: null,
        charge: null,
        appliedCharge: 0,
      };
      sendJson(response, 200, snapshot);
      return;
    }
    if (request.method === "POST" && url.pathname === "/v1/test/unavailable") {
      snapshot = {
        ...snapshot,
        available: false,
        enabled: false,
        petEnabled: false,
        petIdentity: null,
        charge: null,
        appliedCharge: 0,
      };
      sendJson(response, 200, snapshot);
      return;
    }

    if (request.method === "GET" && url.pathname === "/") {
      staticFile(response, "harness/index.html", "text/html; charset=utf-8");
      return;
    }
    if (request.method === "GET" && url.pathname === "/harness.css") {
      staticFile(response, "harness/harness.css", "text/css; charset=utf-8");
      return;
    }
    if (request.method === "GET" && url.pathname === "/harness.mjs") {
      staticFile(response, "harness/harness.mjs", "text/javascript; charset=utf-8");
      return;
    }
    if (
      request.method === "GET" &&
      url.pathname === "/src/pet-presentation-state.mjs"
    ) {
      staticFile(
        response,
        "src/pet-presentation-state.mjs",
        "text/javascript; charset=utf-8",
      );
      return;
    }
    const assetMatch = url.pathname.match(
      /^\/assets\/(energetic|normal|tired|exhausted)\.webp$/,
    );
    if (request.method === "GET" && assetMatch) {
      send(response, 200, assets[assetMatch[1]], "image/webp");
      return;
    }

    sendJson(response, 404, { error: "not_found" });
  } catch (error) {
    sendJson(response, 400, { error: error.message });
  }
});

server.listen(port, "127.0.0.1", () => {
  console.log(
    JSON.stringify({
      ok: true,
      url: `http://127.0.0.1:${port}/`,
      endpoint: `http://127.0.0.1:${port}/v1/pet`,
      sourceVersion: inspection.version,
      sourceBuild: inspection.build,
      assets: inspection.assets,
    }),
  );
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
