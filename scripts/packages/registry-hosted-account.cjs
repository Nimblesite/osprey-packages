// Browser acceptance for the packaged hosted account page [PACKAGE-HOSTED-ROUTES-CATALOG].
const assert = require('node:assert/strict');
const { withHostedPage } = require('./registry-browser-fixture.cjs');
const { checkHostedPasskey } = require('./registry-hosted-passkey.cjs');
const { checkHostedCatalog } = require('./registry-hosted-catalog.cjs');
const { checkHostedRelease } = require('./registry-hosted-release.cjs');
const checkHostedAccount = async (browser, livePort) => {
  await withHostedPage(browser, fixture => checkPackagedAccount(fixture, livePort));
  if (!livePort) await checkHostedPasskey(browser);
  if (!livePort) {
    await checkHostedCatalog(browser);
    await checkHostedRelease(browser);
  }
};
async function checkPackagedAccount({page, website, api, failures}, livePort) {
  await page.route('https://www.ospreylang.dev/**', route => route.abort('blockedbyclient'));
  const headers = {'access-control-allow-origin':website,'access-control-allow-credentials':'true'};
  async function waitForFirstRelease() {
    await page.getByRole('heading', {name:'e1.r1'}).waitFor();
    await page.locator('[id="e1.r1"] .prose-license').first().waitFor();
  }
  async function assertPublicCatalogUnavailable() {
    await page.goto(website);
    await page.getByText('The public catalog is unavailable.').waitFor();
    assert.equal(await page.locator('#results article').count(), 0);
  }
  if (livePort) {
    assert.match(livePort, /^[0-9]{4,5}$/);
    await page.route(url => url.origin === api && (url.pathname.startsWith('/v1/packages') || url.pathname.startsWith('/v1/publishers/')), async route => {
      const upstream = await page.request.get('http://127.0.0.1:' + livePort + new URL(route.request().url()).pathname, {
        headers:{'X-Edge-Host':'127.0.0.1','X-Edge-Secret':'fixture-edge-secret-at-least-32-bytes',Origin:website}, timeout:5000,
      });
      assert.equal(upstream.status(), 200);
      assert.equal(upstream.headers()['access-control-allow-origin'], website);
      await route.fulfill({response:upstream});
    });
    await page.goto(website);
    await page.getByRole('navigation', {name:'Browse packages'}).getByRole('link', {name:'By tag'}).click();
    await page.getByRole('heading', {name:'Tags', exact:true}).waitFor();
    await page.getByText('No tags have five packages yet.').waitFor();
    assert.equal(await page.getByRole('link', {name:'graphics', exact:true}).count(), 0);
    await page.goto(website + '/tags/graphics/');
    await page.getByRole('heading', {name:'Tag not found'}).waitFor();
    await page.goto(website);
    await page.getByRole('navigation', {name:'Browse packages'}).getByRole('link', {name:'By publisher'}).click();
    await page.getByRole('heading', {name:'Publishers'}).waitFor();
    assert.equal(await page.getByRole('link', {name:'Atlas Engineering', exact:true}).count(), 1);
    await page.goto(website + '/?q=http');
    await page.getByRole('link', {name:'@atlas/net'}).click();
    await waitForFirstRelease();
    await page.getByText("NOTICE.md", {exact:true}).first().click();
    await page.getByText("Adapted from Atlas upstream.", {exact:false}).waitFor();
    assert.equal(await page.locator('[id="e1.r2"] .prose-license').textContent(), "Apache-2.0");
    const content = 'https://content.example.test';
    async function atContent(path, credential) {
      return page.request.get('http://127.0.0.1:' + livePort + path, {
        headers:{'X-Edge-Host':'content.example.test','X-Edge-Secret':'fixture-edge-secret-at-least-32-bytes',...credential},
        timeout:5000,
      });
    }
    await page.route(content + '/**', async route => {
      await route.fulfill({response:await atContent(new URL(route.request().url()).pathname)});
    });
    const licenseBadge = page.locator('[id="e1.r1"] a.prose-license');
    assert.equal(await licenseBadge.count(), 1);
    const licenseUrl = new URL(await licenseBadge.getAttribute('href'));
    assert.equal(licenseUrl.origin, content);
    const license = await atContent(licenseUrl.pathname);
    assert.equal(license.status(), 200);
    assert.match(license.headers()['content-type'], /^text\/plain/);
    assert.equal(license.headers()['x-content-type-options'], 'nosniff');
    assert.match(await license.text(), /Atlas license <terms>/);
    assert.match(await license.text(), /Extra license terms/);
    assert.doesNotMatch(await license.text(), /Attribution only/);
    assert.equal((await atContent(licenseUrl.pathname, {Cookie:'__Host-registry=opaque'})).status(), 421);
    const downloadLink = page.getByRole('link', {name:'Download e1.r1', exact:true});
    const href = new URL(await downloadLink.getAttribute('href'));
    assert.equal(href.origin, content);
    const downloaded = page.waitForEvent('download');
    await downloadLink.click();
    const file = await downloaded;
    assert.equal(file.suggestedFilename(), 'osprey-source.json');
    const source = JSON.parse(await require('node:fs/promises').readFile(await file.path(), 'utf8'));
    assert.equal(source.key, '@atlas/net');
    assert.equal(source.digest, href.pathname.split('/')[3]);
    assert.equal(source.files.find(item => item.path === 'src/main.osp').text, 'fn main() = 0\n');
    assert.equal((await atContent(href.pathname, {Cookie:'__Host-registry=opaque'})).status(), 421);
    assert.equal((await atContent('/v1/packages')).status(), 421);
    const corrupted = new URL(await page.getByRole('link', {name:'Download e1.r2', exact:true}).getAttribute('href'));
    assert.equal((await atContent(corrupted.pathname)).status(), 503);
    await page.getByText('Network access', {exact:true}).waitFor();
    await page.getByRole('link', {name:'Atlas Labs'}).waitFor();
    assert.equal(await page.getByRole('link', {name:'networking', exact:true}).count(), 0);

    await page.getByRole('link', {name:'Atlas Engineering'}).click();
    await page.getByRole('heading', {name:'Atlas Engineering'}).waitFor();
    assert.equal(await page.getByRole('link', {name:'@atlas/net e1.r2'}).count(), 0);
    await page.getByText('Network access', {exact:true}).waitFor();
    await page.getByRole('link', {name:'@atlas/net e1.r1'}).click();
    assert.equal(new URL(page.url()).hash, '#e1.r1');
    await waitForFirstRelease();
    await page.getByText("NOTICE.md", {exact:true}).first().waitFor();
    assert.deepEqual(failures.filter(failure => !(failure.url === href.href && failure.error === "net::ERR_ABORTED")), []);
    await page.close();
    return;
  }
  await page.route(api + '/v1/packages', route => route.fulfill({headers,json:{packages:[]}}));
  const csrfToken = 'sha256:' + 'a'.repeat(64);
  let signOutRequests = 0;
  await page.route(api + '/v1/auth/logout', route => {
    if (route.request().method() === 'OPTIONS') return route.fulfill({status:204,headers:{...headers,
      'access-control-allow-methods':'POST','access-control-allow-headers':'X-CSRF-Token'}});
    assert.equal(route.request().method(), 'POST');
    assert.equal(route.request().headers()['x-csrf-token'], csrfToken);
    assert.equal(route.request().postData(), null);
    signOutRequests++;
    if (signOutRequests === 1) return route.fulfill({status:503,headers,json:{code:'registry.not-ready',status:503}});
    return route.fulfill({status:204,headers});
  });
  await page.route(api + '/v1/account', route => route.fulfill({status:200,headers,json:{organizations:[],packages:[]}}));
  for (const code of [401, 503, 200]) {
    await page.route(api + '/v1/auth/session', route => route.fulfill({status:code,headers,json:{authenticated:code === 200,csrfToken}}));
    await page.goto(website + '/release/');
    const osprey = page.locator('footer.prose-footer').getByRole('link', { name: 'A package registry for the Osprey language' });
    assert.equal(await osprey.getAttribute('href'), 'https://www.ospreylang.dev/');
    const mark = await osprey.locator('img').getAttribute('src');
    const markHash = require('node:crypto').createHash('sha256').update(require('node:fs').readFileSync('src/manager/web/assets/osprey-mark.svg')).digest('hex');
    assert.equal(new URL(mark, page.url()).searchParams.get('v'), markHash.slice(0, 12));
    assert.equal(await osprey.locator('img').evaluate(img => img.naturalWidth > 0 && getComputedStyle(img).opacity < 1), true);
    if (code === 401) await checkFooter(page);
    const panel = page.locator('[data-session-url]');
    const login = panel.getByRole('link', {includeHidden:true});
    if (code === 401) {
      await login.waitFor();
      assert.equal(await login.getAttribute('href'), api + '/v1/auth/github/start');
    } else {
      await panel.getByText(code === 503 ? /could not verify/ : /Signed in/).waitFor();
      assert.equal(await login.isVisible(), false);
    }
    if (code === 200) {
      const id = '11111111-1111-4111-8111-111111111111';
      const digest = 'sha256:' + 'b'.repeat(64);
      const receipt = {submissionId:id, packageId:"22222222-2222-4222-8222-222222222222", digest, epoch:1, ordinal:2, status:'rejected', messages:['Fix <img src=x>'], canApprove:false};
      await page.route(api + '/v1/publications/' + id, route => route.fulfill({headers,json:receipt}));
      await page.route(api + '/v1/reviews/' + id + '/' + digest + '/approve', route => {
        if (route.request().method() === 'OPTIONS') return route.fulfill({status:204,headers:{...headers,
          'access-control-allow-methods':'POST','access-control-allow-headers':'X-CSRF-Token'}});
        assert.equal(route.request().method(), 'POST');
        assert.equal(route.request().headers()['x-csrf-token'], csrfToken);
        receipt.status = 'approved';
        return route.fulfill({status:204,headers});
      });
      const lookup = page.locator('[data-receipt-panel]');
      await lookup.getByLabel('Submission ID').fill(id);
      const check = lookup.getByRole('button', {name:'Check status'});
      const approve = lookup.getByRole('button', {name:'Approve this version', includeHidden:true});
      await check.click();
      await lookup.getByText('Fix <img src=x>', {exact:true}).waitFor();
      assert.match(await lookup.getByRole('status').innerText(), new RegExp(receipt.packageId));
      assert.equal(await lookup.locator('img').count(), 0);
      assert.equal(await approve.isVisible(), false);
      Object.assign(receipt, {status:'awaiting-admin',messages:[],canApprove:true});
      await check.click();
      await approve.click();
      await lookup.getByText(/Administrator approval recorded/).waitFor();
      assert.equal(await approve.isVisible(), false);
      const logout = panel.getByRole('button', {name:'Sign out'});
      await logout.click();
      await panel.getByText('Could not sign out. Try again.').waitFor();
      assert.equal(await login.isVisible(), false);
      await logout.click();
      await panel.getByText('Signed out.', {exact:true}).waitFor();
      await login.waitFor();
      assert.equal(await logout.count(), 0);
      assert.equal(signOutRequests, 2);
      assert.equal(await lookup.isVisible(), false);
    }
    await page.unroute(api + '/v1/auth/session');
  }
  await page.unroute(api + '/v1/auth/logout');
  await page.unroute(api + '/v1/packages');
  const entry = {key:'@atlas/net',keywords:['networking','web'],releases:[{digest:'sha256:' + 'a'.repeat(64),epoch:1,ordinal:1,publisherId:"11111111-1111-4111-8111-111111111111",publisherName:"Atlas Engineering",licenseExpression:"MIT",notices:[{path:"NOTICE.md",text:"Upstream <img src=x>"}]}],summary:'HTTP tools <img src=x>',warnings:['Network access']};
  entry.releases.unshift({...entry.releases[0], digest:'sha256:' + 'b'.repeat(64), ordinal:2, licenseExpression:'Apache-2.0', notices:[]});
  entry.releases[1].epoch = 2;
  entry.releases[1].notices[0].path = 'NOTICES.md';
  let payload = {packages:[entry]};
  await page.route(api + '/v1/packages', route => route.fulfill({headers,json:payload}));
  await page.goto(website + '/?q=http');
  const homePanel = await page.locator('.prose-intro').boundingBox();
  assert.equal(await page.locator('#results .prose-license').textContent(), 'MIT');
  await page.getByRole('link', {name:entry.key}).click();
  assert.equal(new URL(page.url()).pathname, '/packages/@atlas/net/');
  await page.getByText('Network access', {exact:true}).waitFor();
  assert.deepEqual(await page.locator('#package-details .prose-cover').boundingBox(), homePanel);
  const metadata = page.locator('.prose-facts');
  assert.equal(await metadata.locator('.prose-license').textContent({timeout:2000}), 'MIT');
  const notices = metadata.getByRole('link', {name:'Notices and attribution'});
  await notices.click();
  assert.equal(new URL(page.url()).hash, '#e2.r1-notices');
  await page.getByText('NOTICES.md', {exact:true}).click();
  await page.getByText('Upstream <img src=x>', {exact:true}).waitFor();
  assert.equal(await page.locator('.prose-notice img').count(), 0);
  await page.goBack();
  await page.goBack();
  assert.equal(await page.locator('#q').inputValue(), 'http');
  await page.goto(website + '/?q=unknown');
  await page.getByText('No matching packages.').waitFor();
  payload = {packages:[]};
  for (const query of ['', '?q=http']) {
    await page.goto(website + '/' + query);
    await page.getByText('No packages published yet.', {exact:true}).waitFor();
    assert.equal(await page.getByText('No matching packages.').count(), 0);
    assert.equal(await page.getByText('The public catalog is unavailable.').count(), 0);
  }
  const tagged = Array.from({length:4}, (_, i) => ({
    ...entry, key: '@atlas/fixture-' + i, keywords: i === 3 ? ['networking'] : entry.keywords,
  }));
  payload = {packages:[entry, ...tagged, tagged[0]]};
  await page.goto(website + '/tags/');
  await page.getByRole('heading', {name:'Tags', exact:true}).waitFor();
  assert.deepEqual(await page.locator('#package-details .prose-cover').boundingBox(), homePanel);
  await page.getByRole('link', {name:'networking', exact:true}).click();
  await page.getByRole('heading', {name:'networking', exact:true}).waitFor();
  assert.equal(await page.locator('.prose-package').count(), 5);
  await page.getByRole('link', {name:entry.key, exact:true}).click();
  await page.getByRole('link', {name:'networking', exact:true}).waitFor();
  assert.equal(await page.getByRole('link', {name:'web', exact:true}).count(), 0);
  await page.goto(website + '/tags/web/');
  await page.getByRole('heading', {name:'Tag not found'}).waitFor();
  for (const keywords of [null, ['../escape'], ['web', 'networking'], ['web', 'web']]) {
    payload = {packages:[{...entry,keywords}]};
    await assertPublicCatalogUnavailable();
  }
  payload = {packages:[entry, {key:'@atlas/incomplete',summary:'Missing warnings'}]};
  await assertPublicCatalogUnavailable();
  assert.deepEqual(failures, []);
  await page.close();
}

const footerColumns = {
  Packages: [['Browse packages', '/'], ['By publisher', '/publishers/'], ['By tag', '/tags/'], ['Release a package', '/release/']],
  Publish: [['Publishing guide', '/publishing/'], ['Package guide', '/guide/'], ['Package manager docs', 'https://www.ospreylang.dev/docs/package-manager/']],
  Osprey: [['Website', 'https://www.ospreylang.dev/'], ['Install', 'https://www.ospreylang.dev/docs/installation/'], ['Documentation', 'https://www.ospreylang.dev/docs/'], ['Specification', 'https://www.ospreylang.dev/spec/']],
  Community: [['Discord', 'https://discord.gg/EGk3XhcGyy'], ['GitHub', 'https://github.com/Nimblesite/osprey-packages'], ['Issues', 'https://github.com/Nimblesite/osprey-packages/issues']],
};

// The footer [PACKAGE-HOSTED-ROUTES]: four labelled link columns side by side on a desktop, stacked on a phone, then the copyright line.
async function checkFooter(page) {
  const footer = page.locator('footer.prose-footer');
  const headings = await footer.locator('nav h2').allTextContents();
  assert.deepEqual(headings, Object.keys(footerColumns));
  for (const [heading, links] of Object.entries(footerColumns)) {
    const column = footer.getByRole('navigation', { name: heading });
    const found = await column.getByRole('link').evaluateAll(as => as.map(a => [a.textContent, a.getAttribute('href')]));
    assert.deepEqual(found, links);
  }
  const tops = async () => footer.locator('nav').evaluateAll(navs => navs.map(n => Math.round(n.getBoundingClientRect().top)));
  assert.equal(new Set(await tops()).size, 1);
  assert.match(await footer.locator('p').last().textContent(), /^© 2026 Nimblesite$/);
  const size = page.viewportSize();
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(new Set(await tops()).size, 4);
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await page.setViewportSize(size);
}

module.exports = { checkHostedAccount };
