// Serve the real Pages archive with its shipped asset names and security headers.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync: exec } = require('node:child_process');
const { createHash } = require('node:crypto');

async function withHostedPage(browser, run) {
  const work = fs.mkdtempSync('target/registry-site-build/archive-check.');
  try {
    const pack = directory => exec('python3', ['scripts/packages/archive-registry-site.py', directory, work], {encoding:'utf8'}).trim();
    const archive = pack('target/registry-site-build/hosted-fixture');
    const digest = createHash('sha256').update(fs.readFileSync(archive)).digest('hex');
    assert.equal(path.basename(archive), 'registry-site-' + digest + '.zip');
    const extracted = path.join(work, 'site');
    exec('unzip', ['-q', archive, '-d', extracted]);
    assert.equal(pack(extracted), archive, 'Repacking yields the same bytes');
    await run(await packagedPage(browser, extracted));
  } finally {
    fs.rmSync(work, {recursive:true, force:true});
  }
}

function parsePagesHeaders(text) {
  const sections = [];
  let current = null;
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    if (!/^\s/u.test(raw)) {
      current = { pattern: line, headers: {} };
      sections.push(current);
    } else if (current) {
      const delimiter = line.indexOf(':');
      assert.ok(delimiter > 0, `invalid header line: ${line}`);
      current.headers[line.slice(0, delimiter).trim().toLowerCase()] = line.slice(delimiter + 1).trim();
    }
  }
  assert.equal(sections[0]?.pattern, '/*');
  return sections;
}

function headersForPath(sections, pathname) {
  const merged = {};
  for (const section of sections) {
    const regex = new RegExp('^' + section.pattern.replace(/[.+?^${}()|[\]\\]/gu, '\\$&').replace(/\*/gu, '.*') + '$');
    if (regex.test(pathname)) Object.assign(merged, section.headers);
  }
  return merged;
}

// Cloudflare Pages `_redirects`, as Pages applies a 200 rewrite: a target naming an `.html` file is
// itself redirected (308) to its extensionless path, dropping the visitor's path; an extensionless
// target serves `<target>.html` under the visitor's own URL.
function parsePagesRewrites(text) {
  return text.split('\n').filter(Boolean).map(line => {
    const [pattern, target, status] = line.trim().split(/\s+/u);
    assert.equal(status, '200', line);
    return {prefix: pattern.replace(/\*$/u, ''), target};
  });
}

function rewrite(rules, pathname) {
  const rule = rules.find(candidate => pathname.startsWith(candidate.prefix));
  if (!rule) return {file: pathname};
  if (rule.target.endsWith('.html')) return {redirect: rule.target.slice(0, -'.html'.length)};
  return {file: rule.target + '.html'};
}

async function packagedPage(browser, site) {
  const website = 'https://packages.example.test';
  const api = 'https://api.example.test';
  const page = await browser.newPage();
  const sections = parsePagesHeaders(fs.readFileSync(path.join(site, '_headers'), 'utf8'));
  const rules = parsePagesRewrites(fs.readFileSync(path.join(site, '_redirects'), 'utf8'));
  page.setDefaultTimeout(10000);
  const failures = [];
  page.on('pageerror', error => failures.push(error.message));
  page.on('requestfailed', request => failures.push({url:request.url(), error:request.failure()?.errorText}));
  await page.route(website + '/**', async route => {
    const pathname = new URL(route.request().url()).pathname;
    const routed = rewrite(rules, pathname);
    if (routed.redirect) return route.fulfill({status: 308, headers: {location: website + routed.redirect}});
    const file = path.join(site, routed.file, routed.file.endsWith('/') ? 'index.html' : '');
    const body = await fs.promises.readFile(file);
    const mime = {'.html':'text/html','.css':'text/css','.svg':'image/svg+xml','.mjs':'text/javascript','.wasm':'application/wasm'}[path.extname(file)];
    assert.ok(mime, pathname);
    const hash = /\.([0-9a-f]{12})\.(?:css|mjs|wasm)$/.exec(pathname);
    if (hash) assert.equal(createHash('sha256').update(body).digest('hex').slice(0,12), hash[1]);
    await route.fulfill({body, headers:headersForPath(sections, pathname), contentType:mime});
  });
  return {page, website, api, failures};
}

module.exports = { withHostedPage };
