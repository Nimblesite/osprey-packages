// Implements [PACKAGE-HOSTED-EDGE]: transport only, no package policy.
// Cloud Run routes by Host, so the Worker fetches the run.app origin (the runtime sets
// Host to it) and carries the public hostname in X-Edge-Host. Both edge headers are
// overwritten, never appended, so a client cannot supply or duplicate them; the API
// checks X-Edge-Secret before it trusts X-Edge-Host. TLS floor and per-IP rate limit live
// here, not in zone rules, so the registry never touches anything else in a shared zone.
const TLS_FLOOR = new Set(["TLSv1.2", "TLSv1.3"]);

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.protocol !== "https:") {
      url.protocol = "https:";
      return Response.redirect(url.href, 308);
    }
    if (!TLS_FLOOR.has(request.cf?.tlsVersion)) return new Response("TLS 1.2 or later required\n", { status: 426 });
    const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
    if (!(await env.LIMITER.limit({ key: ip })).success) return new Response("rate limited\n", { status: 429, headers: { "Retry-After": "10" } });
    const headers = new Headers(request.headers);
    headers.set("X-Edge-Secret", env.EDGE_SECRET);
    headers.set("X-Edge-Host", url.hostname);
    url.hostname = env.RUN_HOST;
    return fetch(url, { method: request.method, headers, body: request.body, redirect: "manual" });
  },
};
