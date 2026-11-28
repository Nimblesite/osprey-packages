// What the packaged website shows for every hosted catalog reply [PACKAGE-HOSTED-ROUTES-CATALOG]: the
// Osprey guest (CatalogReply) picks the API path and turns each status into the page's words.
const assert = require('node:assert/strict');
const { withHostedPage } = require('./registry-browser-fixture.cjs');

const busy = 'The package catalog is temporarily busy.';
const unavailable = 'The public catalog is unavailable.';
const pageFailed = 'The registry could not load this page.';

// [path the visitor opens, API path the page must read, reply, status text the page must show]
const cases = [
  ['/', '/v1/packages', {status:429, headers:{'retry-after':'7'}}, 'Too many requests. Please retry in 7 seconds.'],
  ['/', '/v1/packages', {status:429}, 'Too many requests. Please retry in a moment.'],
  ['/', '/v1/packages', {status:503, headers:{'retry-after':' 30 '}}, `${busy} Please retry in 30 seconds.`],
  ['/', '/v1/packages', {status:503, headers:{'retry-after':'Fri, 31 Dec 2027 23:59:59 GMT'}}, `${busy} Please retry in a moment.`],
  ['/', '/v1/packages', {status:503, headers:{'retry-after':'-5'}}, `${busy} Please retry in a moment.`],
  ['/', '/v1/packages', {status:500}, unavailable],
  ['/', '/v1/packages', {status:404}, unavailable],
  ['/', '/v1/packages', {status:200, body:'not json'}, unavailable],
  ['/', '/v1/packages', 'abort', unavailable],
  ['/packages/@demo/one/', '/v1/packages', {status:404}, 'Page not found.'],
  ['/packages/@demo/one/', '/v1/packages', {status:500}, pageFailed],
  ['/packages/@demo/one/', '/v1/packages', {status:429, headers:{'retry-after':'2'}}, 'Too many requests. Please retry in 2 seconds.'],
  ['/packages/@demo/one/', '/v1/packages', 'abort', pageFailed],
  ['/publishers/11111111-1111-4111-8111-111111111111/', '/v1/publishers/11111111-1111-4111-8111-111111111111/releases', {status:404}, 'Page not found.'],
  ['/publishers/11111111-1111-4111-8111-111111111111/', '/v1/publishers/11111111-1111-4111-8111-111111111111/releases', {status:503}, `${busy} Please retry in a moment.`],
];

// One API route serves every case; `current` holds the reply the case under test wants.
async function checkCase({page, website}, current, [visit, read, reply, expected]) {
  current.reply = reply;
  current.requested = [];
  await page.goto(website + visit);
  const status = page.locator('#catalog-status');
  await page.waitForFunction(() => document.getElementById('catalog-status').textContent !== 'Loading packages…');
  assert.equal((await status.textContent()).trim(), expected, `${visit} ${JSON.stringify(reply)}`);
  assert.deepEqual(current.requested, [read], `${visit} reads ${read}`);
  const results = page.locator('#package-details, #results').first();
  assert.equal(await results.evaluate(node => node.childElementCount), 0, `${visit} shows no stale results`);
}

const checkHostedCatalog = browser => withHostedPage(browser, async fixture => {
  const {page, website, api} = fixture;
  const current = {reply:null, requested:[]};
  await page.route(url => url.origin === api, route => {
    current.requested.push(new URL(route.request().url()).pathname);
    if (current.reply === 'abort') return route.abort('connectionrefused');
    const headers = {'access-control-allow-origin':website, 'access-control-expose-headers':'Retry-After', ...current.reply.headers};
    return route.fulfill({status:current.reply.status, headers, contentType:'application/json', body:current.reply.body ?? '{"code":"x"}'});
  });
  for (const testCase of cases) await checkCase(fixture, current, testCase);
});

module.exports = { checkHostedCatalog };
