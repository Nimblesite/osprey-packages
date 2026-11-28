// Exercises src/manager/ops/cloudflare/edge.js cache safety, rate-limit order and header overwrite
// [PACKAGE-HOSTED-EDGE] [PLAN-ROLLOUT-EDGE].
import assert from 'node:assert/strict';
import worker from '../../src/manager/ops/cloudflare/edge.js';

const store = new Map();
globalThis.caches = {
  default: {
    async match(req) { return store.get(req.url)?.clone(); },
    async put(req, res) { store.set(req.url, res.clone()); },
  },
};

let originHits = 0;
let lastOriginHeaders = null;
let nextOriginResponse = () => new Response('{"packages":[]}', {
  status: 200, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=60, s-maxage=300' },
});
globalThis.fetch = async (_url, init) => {
  originHits += 1;
  lastOriginHeaders = init.headers;
  return nextOriginResponse();
};

let allowLimit = true;
const env = {
  WEBSITE_ALIAS: 'package.ospreylang.dev',
  RUN_HOST: 'api.run.app',
  WEBSITE_ORIGIN: 'https://packages.ospreylang.dev',
  EDGE_SECRET: 's'.repeat(64),
  LIMITER: { async limit() { return { success: allowLimit }; } },
};
const ctx = { waitUntil(p) { return p; } };
const req = (url, headers = {}, tls = 'TLSv1.3') => Object.assign(new Request(url, { headers }), { cf: { tlsVersion: tls } });

// 1. HTTP redirect and TLS floor
assert.equal((await worker.fetch(req('http://packages-api.ospreylang.dev/v1/packages'), env, ctx)).status, 308);
assert.equal((await worker.fetch(req('https://packages-api.ospreylang.dev/v1/packages', {}, 'TLSv1.1'), env, ctx)).status, 426);

for (const path of ['/', '/upload/?from=home', '//another.example/path']) {
  const res = await worker.fetch(req('https://' + env.WEBSITE_ALIAS + path), env, ctx);
  assert.equal(res.status, 308);
  assert.equal(res.headers.get('location'), env.WEBSITE_ORIGIN + path);
}
assert.equal(originHits, 0);

// 2. Anonymous GET caches on miss, hits before rate limiter, and overwrites spoofed edge headers
const first = await worker.fetch(req('https://packages-api.ospreylang.dev/v1/packages', {
  'X-Edge-Secret': 'spoof', 'X-Edge-Host': 'evil.example',
}), env, ctx);
assert.equal(first.status, 200);
assert.equal(originHits, 1);
assert.equal(lastOriginHeaders.get('X-Edge-Secret'), env.EDGE_SECRET);
assert.equal(lastOriginHeaders.get('X-Edge-Host'), 'packages-api.ospreylang.dev');

allowLimit = false;
const cached = await worker.fetch(req('https://packages-api.ospreylang.dev/v1/packages'), env, ctx);
assert.equal(cached.status, 200);
assert.equal(originHits, 1, 'cached anonymous GET must not hit origin or rate limiter');
allowLimit = true;

// 3. Website Origin uses a separate cache key from non-Origin
const corsHit = await worker.fetch(req('https://packages-api.ospreylang.dev/v1/packages', { Origin: env.WEBSITE_ORIGIN }), env, ctx);
assert.equal(corsHit.status, 200);
assert.equal(originHits, 2);

// 4. Requests with Cookie or Authorization never read from or write to cache
await worker.fetch(req('https://packages-api.ospreylang.dev/v1/packages', { Cookie: '__Host-registry=abc' }), env, ctx);
await worker.fetch(req('https://packages-api.ospreylang.dev/v1/packages', { Authorization: 'Bearer tok' }), env, ctx);
assert.equal(originHits, 4);

// 5. Responses with Set-Cookie or no-store are never stored in cache
nextOriginResponse = () => new Response('ok', {
  status: 200, headers: { 'Cache-Control': 'public, max-age=60', 'Set-Cookie': 'a=b' },
});
await worker.fetch(req('https://packages-api.ospreylang.dev/v1/set-cookie-test'), env, ctx);
assert.equal(store.size, 2, 'Set-Cookie response must never enter cache');

nextOriginResponse = () => new Response('err', {
  status: 503, headers: { 'Cache-Control': 'no-store' },
});
await worker.fetch(req('https://packages-api.ospreylang.dev/v1/unavailable-test'), env, ctx);
assert.equal(store.size, 2, '503/no-store response must never enter cache');

console.log('edge.js cache and security tests passed');
