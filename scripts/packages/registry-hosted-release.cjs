// The publisher's four release steps on the packaged site [PACKAGE-HOSTED-PUBLISH-FLOW]: the Osprey
// guest (ReleaseSteps) builds every POST and words every reply; the bridge sends the cookie and CSRF token.
const assert = require('node:assert/strict');
const { withHostedPage } = require('./registry-browser-fixture.cjs');

const csrfToken = 'sha256:' + 'd'.repeat(64);
const org = '22222222-2222-4222-8222-222222222222';
const pkg = '33333333-3333-4333-8333-333333333333';
const submission = '44444444-4444-4444-8444-444444444444';
const commit = 'c'.repeat(40);
const unavailable = 'The registry is unavailable. Try again shortly.';

const stepOf = (page, title) => page.locator('[data-release-step]').filter({has: page.getByRole('heading', {name: title})});

async function fill(step, values) {
  for (const [label, value] of Object.entries(values)) await step.getByLabel(label, {exact: true}).fill(value);
}

// Submit one step with `reply` waiting at the API; answer the status text and the requests it made.
async function submit(page, current, step, button, reply, expected) {
  current.reply = reply;
  current.requested = [];
  const status = step.getByRole('status');
  await status.evaluate(node => { node.textContent = ''; });
  await step.getByRole('button', {name: button}).click();
  await page.waitForFunction(node => node.textContent !== '', await status.elementHandle());
  assert.equal((await status.textContent()).trim(), expected);
  return current.requested;
}

function routeApi(page, api, website, current) {
  return page.route(url => url.origin === api && url.pathname !== '/v1/auth/session', route => {
    const request = route.request();
    current.requested.push({method: request.method(), path: new URL(request.url()).pathname, csrf: request.headers()['x-csrf-token'],
      type: request.headers()['content-type'], body: request.postData()});
    if (current.reply === 'abort') return route.abort('connectionrefused');
    return route.fulfill({status: current.reply.status, headers: {'access-control-allow-origin': website, 'access-control-allow-credentials': 'true'},
      contentType: 'application/json', body: current.reply.body ?? '{"code":"x"}'});
  });
}

const one = (requested, path, body) => {
  assert.equal(requested.length, 1, `${path} once`);
  assert.deepEqual(requested[0], {method: 'POST', path, csrf: csrfToken, type: 'application/json', body});
};

async function refusals(page, current, steps) {
  const {organization, release} = steps;
  await fill(organization, {Handle: 'acme', Name: 'Acme'});
  assert.equal((await submit(page, current, organization, 'Create organization', {status: 409}, 'That handle is taken. Choose another.')).length, 1);
  await submit(page, current, organization, 'Create organization', {status: 400}, 'Use a lowercase handle (letters, digits, hyphens) and a name of at most 128 characters.');
  await submit(page, current, organization, 'Create organization', {status: 401}, 'Your session has ended. Sign in again.');
  await submit(page, current, organization, 'Create organization', {status: 403}, 'The registry refused this page. Reload it and try again.');
  await submit(page, current, organization, 'Create organization', {status: 503}, unavailable);
  await submit(page, current, organization, 'Create organization', 'abort', unavailable);
  await submit(page, current, organization, 'Create organization', {status: 201, body: '{"id":"not-a-uuid"}'}, unavailable);
  await submit(page, current, organization, 'Create organization', {status: 201, body: 'not json'}, unavailable);
  await fill(release, {'Git commit': commit, Version: 'e1.r1'});
  assert.deepEqual(await submit(page, current, release, 'Request release', {status: 201}, 'Create the package first.'), [], 'no POST before a package exists');
}

async function journey(page, current, steps) {
  const {organization, pkgStep, repository, release} = steps;
  await fill(organization, {Handle: 'acme', Name: 'Acme "Labs" \\ Ltd'});
  one(await submit(page, current, organization, 'Create organization', {status: 201, body: `{"id":"${org}"}`}, 'Organization created. Now create its package.'),
    '/v1/organizations', '{"handle":"acme","name":"Acme \\"Labs\\" \\\\ Ltd"}');
  await fill(pkgStep, {'Package name': 'net'});
  one(await submit(page, current, pkgStep, 'Create package', {status: 409}, 'That package name is taken, or the organization is not yours.'), `/v1/organizations/${org}/packages`, '{"name":"net"}');
  one(await submit(page, current, pkgStep, 'Create package', {status: 201, body: `{"id":"${pkg}"}`}, 'Package created. Now link its GitHub repository.'), `/v1/organizations/${org}/packages`, '{"name":"net"}');
  await fill(repository, {'GitHub repository ID': '123456', 'Subdirectory (blank for the repository root)': 'packages/net'});
  assert.equal(await repository.getByLabel('Branch').inputValue(), 'main');
  one(await submit(page, current, repository, 'Link repository', {status: 409}, 'This package already has a repository, or your GitHub account is not an admin of that repository.'),
    `/v1/packages/${pkg}/repository`, '{"branch":"main","repositoryId":"123456","subdirectory":"packages/net"}');
  one(await submit(page, current, repository, 'Link repository', {status: 201, body: `{"id":"${pkg}"}`}, 'Repository linked. Now name the commit to release.'),
    `/v1/packages/${pkg}/repository`, '{"branch":"main","repositoryId":"123456","subdirectory":"packages/net"}');
  for (const bad of ['1.1', 'e0.r1', 'e1.r0', 'e1', 'e1.rx', 'r1.e1']) {
    await fill(release, {'Git commit': commit, Version: bad});
    assert.deepEqual(await submit(page, current, release, 'Request release', {status: 201}, 'Write the version as e<epoch>.r<release>, for example e1.r1.'), [], bad);
  }
  await fill(release, {Version: 'e2.r13'});
  one(await submit(page, current, release, 'Request release', {status: 400}, 'Use the full 40-character commit hash in lowercase.'), `/v1/packages/${pkg}/releases`, `{"commit":"${commit}","epoch":2,"ordinal":13}`);
  one(await submit(page, current, release, 'Request release', {status: 201, body: `{"id":"${submission}"}`},
    `Release requested. The registry fetches that commit, scans it and publishes it once a reviewer approves. Submission ID: ${submission}`),
    `/v1/packages/${pkg}/releases`, `{"commit":"${commit}","epoch":2,"ordinal":13}`);
}

const checkHostedRelease = browser => withHostedPage(browser, async ({page, website, api}) => {
  let session = 401;
  await page.route(api + '/v1/auth/session', route => route.fulfill({status: session, headers: {'access-control-allow-origin': website, 'access-control-allow-credentials': 'true'},
    json: {authenticated: session === 200, csrfToken}}));
  const current = {reply: null, requested: []};
  await routeApi(page, api, website, current);
  await page.goto(website + '/release/');
  await page.locator('[data-session-url]').getByRole('link', {includeHidden: true}).waitFor();
  assert.equal(await page.locator('[data-release-steps]').isVisible(), false, 'signed out: no release steps');
  session = 200;
  await page.goto(website + '/release/');
  await page.locator('[data-release-steps]').waitFor();
  const steps = {organization: stepOf(page, '1. Found an organization'), pkgStep: stepOf(page, '2. Create its package'),
    repository: stepOf(page, '3. Link its GitHub repository'), release: stepOf(page, '4. Release a commit')};
  assert.deepEqual(await page.locator('[data-release-steps] h3').allTextContents(),
    ['1. Found an organization', '2. Create its package', '3. Link its GitHub repository', '4. Release a commit']);
  await fill(steps.pkgStep, {'Package name': 'net'});
  assert.deepEqual(await submit(page, current, steps.pkgStep, 'Create package', {status: 201}, 'Create the organization first.'), [], 'no POST before an organization exists');
  await refusals(page, current, steps);
  await journey(page, current, steps);
});

module.exports = { checkHostedRelease };
