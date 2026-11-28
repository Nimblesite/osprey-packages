// Live acceptance of a deployed registry environment [PACKAGE-HOSTED-TOPOLOGY] [PACKAGE-HOSTED-EDGE].
// Usage: node scripts/packages/check-registry-deployed.mjs <domain>   (production is the only environment)
// Read-only: every request is a GET, HEAD or OPTIONS a visitor could send; nothing is written.
import assert from 'node:assert/strict';
import tls from 'node:tls';
import { chromium } from 'playwright';

const [domain] = process.argv.slice(2);
assert.ok(domain, 'usage: check-registry-deployed.mjs <domain>');
const host = name => `${name}.${domain}`;
const website = `https://${host('packages')}`;
const api = `https://${host('packages-api')}`;
const content = `https://${host('packages-content')}`;
const failures = [];
const check = async (label, body) => {
  try { await body(); console.log(`ok - ${label}`); } catch (error) { failures.push(label); console.log(`not ok - ${label}\n  ${error.message}`); }
};
const get = (url, init = {}) => fetch(url, { redirect: 'manual', ...init });
const problemCode = async response => {
  assert.equal(response.headers.get('content-type'), 'application/problem+json');
  return (await response.json()).code;
};
const handshake = (hostname, maxVersion) => new Promise(resolve => {
  const socket = tls.connect({ host: hostname, port: 443, servername: hostname, maxVersion, minVersion: 'TLSv1' }, () => {
    resolve(socket.getProtocol()); socket.end();
  });
  socket.on('error', () => resolve('refused'));
});

for (const hostname of [host('packages'), host('packages-api'), host('packages-content')]) {
  await check(`${hostname}: TLS 1.3 handshake with a valid certificate`, async () =>
    assert.equal(await handshake(hostname, 'TLSv1.3'), 'TLSv1.3'));
  await check(`${hostname}: TLS 1.1 is refused`, async () => {
    assert.equal(await handshake(hostname, 'TLSv1.3'), 'TLSv1.3', 'host is not serving TLS at all, so a refusal proves nothing');
    const protocol = await handshake(hostname, 'TLSv1.1');
    if (protocol === 'refused') return;
    const response = await get(`https://${hostname}/`);
    assert.equal(response.status, 426, `TLS 1.1 negotiated ${protocol} and was served ${response.status}`);
  });
}

await check('singular website hostname redirects to the same canonical page', async () => {
  const response = await get(`https://${host('package')}/release/?from=registry`);
  assert.equal(response.status, 308);
  assert.equal(response.headers.get('location'), website + '/release/?from=registry');
});

await check('api: plain HTTP is redirected to HTTPS', async () => {
  const response = await get(`http://${host('packages-api')}/v1/packages`);
  assert.ok([301, 308].includes(response.status), `status ${response.status}`);
  assert.equal(response.headers.get('location'), `${api}/v1/packages`);
});

await check('api: the production catalog serves its JSON package list', async () => {
  const response = await get(`${api}/v1/packages`);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /^application\/json/);
  assert.ok(Array.isArray((await response.json()).packages), 'packages is a list');
});

await check('api: client-supplied edge headers are overwritten, never trusted', async () => {
  const honest = await get(`${api}/v1/packages`);
  const spoofed = await get(`${api}/v1/packages`, { headers: { 'X-Edge-Secret': 'spoofed', 'X-Edge-Host': 'evil.example' } });
  assert.equal(spoofed.status, honest.status);
});

await check('api: an unknown route is a problem document, not a 200', async () => {
  const response = await get(`${api}/v1/definitely-not-a-route`);
  assert.ok(response.status >= 400, `status ${response.status}`);
  assert.match(await problemCode(response), /\S/);
});

await check('api: the probe path is not reachable through the edge', async () =>
  assert.equal((await get(`${api}/v1/ready`)).status, 404));

await check('api: CORS preflight admits the website origin with credentials', async () => {
  const response = await get(`${api}/v1/auth/session`, { method: 'OPTIONS', headers: {
    Origin: website, 'Access-Control-Request-Method': 'GET', 'Access-Control-Request-Headers': 'x-csrf-token' } });
  assert.equal(response.status, 204);
  assert.equal(response.headers.get('access-control-allow-origin'), website);
  assert.equal(response.headers.get('access-control-allow-credentials'), 'true');
});

await check('api: CORS never echoes a foreign origin', async () => {
  const response = await get(`${api}/v1/packages`, { headers: { Origin: 'https://evil.example' } });
  assert.notEqual(response.headers.get('access-control-allow-origin'), 'https://evil.example');
  assert.notEqual(response.headers.get('access-control-allow-origin'), '*');
});

await check('api: CORS preflight refuses an unlisted request header', async () => {
  const response = await get(`${api}/v1/packages`, { method: 'OPTIONS', headers: {
    Origin: website, 'Access-Control-Request-Method': 'GET', 'Access-Control-Request-Headers': 'x-evil' } });
  assert.equal(response.status, 403);
  assert.equal(await problemCode(response), 'req.preflight');
});

await check('api: a signed-out session read is 401 auth.session-required', async () => {
  const response = await get(`${api}/v1/auth/session`, { headers: { Origin: website } });
  assert.equal(response.status, 401);
  assert.equal(await problemCode(response), 'auth.session-required');
});

await check('api: logout without the website origin is refused', async () => {
  const response = await get(`${api}/v1/auth/logout`, { method: 'POST' });
  assert.equal(response.status, 403);
  assert.equal(await problemCode(response), 'req.origin-required');
});

await check('api: GitHub sign-in redirects to Supabase Auth PKCE with a Secure, HttpOnly flow cookie', async () => {
  const response = await get(`${api}/v1/auth/github/start`);
  assert.equal(response.status, 303, `status ${response.status}`);
  const location = new URL(response.headers.get('location'));
  assert.equal(location.protocol, 'https:');
  assert.match(location.hostname, /^[a-z]{20}\.supabase\.co$/);
  assert.equal(location.pathname, '/auth/v1/authorize');
  assert.equal(location.searchParams.get('provider'), 'github');
  assert.equal(location.searchParams.get('redirect_to'), `${api}/v1/auth/github/callback`);
  assert.equal(location.searchParams.get('code_challenge_method'), 's256');
  assert.ok(location.searchParams.get('code_challenge'), 'code_challenge');
  assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
  const cookie = response.headers.get('set-cookie') ?? '';
  assert.ok(cookie.startsWith('__Host-registry-flow='), 'missing __Host-registry-flow cookie');
  for (const flag of ['Secure', 'HttpOnly', 'SameSite=']) assert.ok(cookie.includes(flag), `cookie lacks ${flag}`);
});

await check('content: an unknown release is not served', async () => {
  assert.equal(await handshake(host('packages-content'), 'TLSv1.3'), 'TLSv1.3', 'content host is not serving');
  const response = await get(`${content}/v1/releases/sha256:${'0'.repeat(64)}`);
  assert.ok(response.status >= 400 && response.status !== 500, `status ${response.status}`);
});

await check('website: the home page is HTML over HTTPS', async () => {
  const response = await get(`${website}/`);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /^text\/html/);
});

await check('website: Chromium renders the catalog from this environment\'s API with no errors', async () => {
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    const errors = [];
    const apiCalls = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('request', request => { if (request.url().startsWith(api)) apiCalls.push(request.url()); });
    page.on('requestfailed', request => {
      const reason = request.failure()?.errorText;
      if (request.url().startsWith('https://static.cloudflareinsights.com/beacon.min.js') && reason === 'csp') return;
      errors.push(`${request.url()} ${reason}`);
    });
    await page.goto(`${website}/`, { waitUntil: 'networkidle' });
    await page.locator('.prose-package, :text("No packages published yet."), :text("No matching packages."), :text("unavailable")').first().waitFor({ timeout: 20000 });
    assert.equal(await page.getByText('unavailable').count(), 0, 'catalog rendered unavailable');
    assert.ok(apiCalls.some(url => url.startsWith(`${api}/v1/packages`)), `catalog never read from ${api}`);
    assert.deepEqual(errors, []);
  } finally {
    await browser.close();
  }
});

console.log(failures.length ? `\n${failures.length} check(s) failed` : '\nall checks passed');
process.exitCode = failures.length ? 1 : 0;
