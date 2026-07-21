const LOOPBACK_ORIGIN = "http://127.0.0.1:49797";
const CONNECT_SOURCE_ANCHOR = "connect-src &#39;self&#39;";

export function patchLoopbackConnectSource(html) {
  if (html.includes(`${CONNECT_SOURCE_ANCHOR} ${LOOPBACK_ORIGIN}`)) {
    throw new Error("CSP already allows the HITW loopback origin");
  }
  const first = html.indexOf(CONNECT_SOURCE_ANCHOR);
  const last = html.lastIndexOf(CONNECT_SOURCE_ANCHOR);
  if (first === -1) throw new Error("Missing connect-src CSP anchor");
  if (first !== last) throw new Error("Ambiguous connect-src CSP anchor");
  return html.replace(
    CONNECT_SOURCE_ANCHOR,
    `${CONNECT_SOURCE_ANCHOR} ${LOOPBACK_ORIGIN}`,
  );
}

export { LOOPBACK_ORIGIN };
