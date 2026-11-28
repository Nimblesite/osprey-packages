// Implements [PACKAGE-HOSTED-EDGE]: transport only, no package policy.
// Cloud Run routes by Host, so the Worker fetches the run.app origin (the runtime sets
// Host to it) and carries the public hostname in X-Edge-Host. Both edge headers are
// overwritten, never appended, so a client cannot supply or duplicate them; the API
// checks X-Edge-Secret before it trusts X-Edge-Host.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.protocol !== "https:") {
      url.protocol = "https:";
      return Response.redirect(url.href, 308);
    }
    const headers = new Headers(request.headers);
    headers.set("X-Edge-Secret", env.EDGE_SECRET);
    headers.set("X-Edge-Host", url.hostname);
    url.hostname = env.RUN_HOST;
    return fetch(url, { method: request.method, headers, body: request.body, redirect: "manual" });
  },
};
