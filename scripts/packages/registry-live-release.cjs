// The release journey against the live Osprey API and PostgreSQL [PLAN-ROLLOUT-PUBLICATION-JOURNEY]:
// sign in through the fixture GitHub callback, then found the organization, create the package,
// bind repository 4242 and request commit 0123…4567 as e1.r1 on the packaged `/release/` page.
// Every API request goes to the live listener; only Supabase's authorize redirect is a fixture.
const assert = require('node:assert/strict');
const { withHostedPage } = require('./registry-browser-fixture.cjs');

const commit = '0123456789abcdef0123456789abcdef01234567';
const edge = {'x-edge-host': '127.0.0.1', 'x-edge-secret': 'fixture-edge-secret-at-least-32-bytes'};
const stepOf = (page, title) => page.locator('[data-release-step]').filter({has: page.getByRole('heading', {name: title})});

function proxyApi(page, api, port, seen) {
  return page.route(url => url.origin === api, async route => {
    const request = route.request();
    const url = new URL(request.url());
    const headers = {...await request.allHeaders(), ...edge};
    delete headers.host;
    const upstream = await page.request.fetch('http://127.0.0.1:' + port + url.pathname + url.search,
      {method: request.method(), headers, data: request.postDataBuffer() ?? undefined, maxRedirects: 0});
    seen.push(request.method() + ' ' + url.pathname + ' ' + upstream.status());
    const replied = upstream.headers();
    // Playwright routes the first navigation in a redirect chain. Let the caller
    // navigate each fixture hop explicitly while Chromium processes the real cookies.
    if (upstream.status() === 303) {
      const destination = new URL(replied.location);
      if (url.pathname.endsWith('/start')) {
        assert.equal(destination.origin + destination.pathname, 'https://project.supabase.co/auth/v1/authorize');
      } else {
        assert.equal(destination.href, 'https://packages.example.test/release/');
      }
      delete replied.location;
      return route.fulfill({status: 200, headers: replied, body: ''});
    }
    await route.fulfill({status: upstream.status(), headers: replied, body: await upstream.body()});
  });
}

async function submit(step, button, expected) {
  const status = step.getByRole('status');
  await status.evaluate(node => { node.textContent = ''; });
  await step.getByRole('button', {name: button}).click();
  await status.filter({hasText: /\S/}).waitFor();
  const text = (await status.textContent()).trim();
  assert.match(text, expected);
  return text;
}

async function fill(step, values) {
  for (const [label, value] of Object.entries(values)) await step.getByLabel(label, {exact: true}).fill(value);
}

const checkLiveRelease = (browser, port) => withHostedPage(browser, async ({page, website, api}) => {
  assert.match(port, /^[0-9]{4,5}$/);
  const seen = [];
  await proxyApi(page, api, port, seen);
  await page.goto(api + '/v1/auth/github/start');
  assert.ok(seen.includes('GET /v1/auth/github/start 303'), seen.join(', '));
  await page.goto(api + '/v1/auth/github/callback?code=fixture-callback-code');
  assert.ok(seen.includes('GET /v1/auth/github/callback 303'), seen.join(', '));
  const cookies = await page.context().cookies(api);
  assert.ok(cookies.some(cookie => cookie.name === '__Host-registry' && cookie.httpOnly && cookie.secure), 'signed in: ' + seen.join(', '));
  await page.goto(website + '/release/');
  await page.locator('[data-release-steps]').waitFor();
  const organization = stepOf(page, '1. Found an organization');
  const pkg = stepOf(page, '2. Create its package');
  const repository = stepOf(page, '3. Link its GitHub repository');
  const release = stepOf(page, '4. Release a commit');
  await fill(organization, {Handle: 'atlas', Name: 'Atlas Engineering'});
  await submit(organization, 'Create organization', /^Organization created\. Now create its package\.$/);
  await submit(organization, 'Create organization', /^That handle is taken\. Choose another\.$/);
  await fill(pkg, {'Package name': 'net'});
  await submit(pkg, 'Create package', /^Package created\. Now link its GitHub repository\.$/);
  await fill(repository, {'GitHub repository ID': '777', 'Subdirectory (blank for the repository root)': ''});
  await submit(repository, 'Link repository', /not an admin of that repository/);
  await fill(repository, {'GitHub repository ID': '4242'});
  await submit(repository, 'Link repository', /^Repository linked\. Now name the commit to release\.$/);
  await fill(release, {'Git commit': commit, Version: 'e1.r1'});
  const requested = await submit(release, 'Request release', /^Release requested\..*Submission ID: [0-9a-f-]{36}$/);
  await submit(release, 'Request release', /./);
  assert.ok(seen.filter(line => line.startsWith('POST /v1/packages/') && line.endsWith('/releases 201')).length === 1, seen.join(', '));
  console.error('live release: ' + requested);
});

module.exports = { checkLiveRelease };
