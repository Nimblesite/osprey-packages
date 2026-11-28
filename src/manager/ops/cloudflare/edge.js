// Implements [PACKAGE-HOSTED-EDGE] and [PLAN-ROLLOUT-EDGE]: transport only, no package policy.
// Cloud Run routes by Host, so the Worker fetches the run.app origin (the runtime sets
// Host to it) and carries the public hostname in X-Edge-Host. Both edge headers are
// overwritten, never appended, so a client cannot supply or duplicate them; the API
// checks X-Edge-Secret before it trusts X-Edge-Host. TLS floor, anonymous edge cache
// (caches.default) and per-IP rate limit live here, not in zone rules, so the registry
// never touches anything else in a shared zone.
const TLS_FLOOR = new Set(["TLSv1.2", "TLSv1.3"]);

function cacheKeyFor(request, env) {
  const url = new URL(request.url);
  const origin = request.headers.get("Origin");
  const webOrigin = env.WEBSITE_ORIGIN && origin === env.WEBSITE_ORIGIN ? "1" : "0";
  url.searchParams.set("__cf_web_origin", webOrigin);
  return new Request(url.toString(), { method: "GET" });
}

function isCacheableResponse(response) {
  if (response.status !== 200 || response.headers.has("Set-Cookie")) return false;
  const cc = (response.headers.get("Cache-Control") ?? "").toLowerCase();
  return cc.includes("public") && !cc.includes("no-store") && !cc.includes("private");
}

// The website must read a 429 to show its retry message, so only its own Origin gets CORS and Retry-After.
function rateLimited(request, env) {
  const headers = new Headers({ "Retry-After": "10", Vary: "Origin" });
  if (env.WEBSITE_ORIGIN && request.headers.get("Origin") === env.WEBSITE_ORIGIN) {
    headers.set("Access-Control-Allow-Origin", env.WEBSITE_ORIGIN);
    headers.set("Access-Control-Allow-Credentials", "true");
    headers.set("Access-Control-Expose-Headers", "Retry-After");
  }
  return new Response("rate limited\n", { status: 429, headers });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.protocol !== "https:") {
      url.protocol = "https:";
      return Response.redirect(url.href, 308);
    }
    if (!TLS_FLOOR.has(request.cf?.tlsVersion)) return new Response("TLS 1.2 or later required\n", { status: 426 });
    if (url.hostname === env.WEBSITE_ALIAS) {
      if (!["GET", "HEAD"].includes(request.method)) return new Response(null, { status: 405, headers: { Allow: "GET, HEAD" } });
      return Response.redirect(env.WEBSITE_ORIGIN + url.pathname + url.search, 308);
    }
    const hasCreds = request.headers.has("Cookie") || request.headers.has("Authorization");
    const foreignOrigin = request.headers.has("Origin") && request.headers.get("Origin") !== env.WEBSITE_ORIGIN;
    const cacheableReq = request.method === "GET" && !hasCreds && !foreignOrigin;
    const cache = typeof caches !== "undefined" ? caches.default : null;
    const cacheKey = cacheableReq && cache ? cacheKeyFor(request, env) : null;
    if (cacheKey) {
      const hit = await cache.match(cacheKey);
      if (hit) return hit;
    }
    const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
    if (!(await env.LIMITER.limit({ key: ip })).success) return rateLimited(request, env);
    const headers = new Headers(request.headers);
    headers.set("X-Edge-Secret", env.EDGE_SECRET);
    headers.set("X-Edge-Host", url.hostname);
    url.hostname = env.RUN_HOST;
    const response = await fetch(url, { method: request.method, headers, body: request.body, redirect: "manual" });
    if (cacheKey && isCacheableResponse(response)) {
      const put = cache.put(cacheKey, response.clone());
      if (ctx?.waitUntil) ctx.waitUntil(put); else await put;
    }
    return response;
  },
};
