// Sign-in hierarchy on the packaged website [PACKAGE-HOSTED-AUTH]: passkey first and largest when
// WebAuthn exists, GitHub second, no third method; every passkey failure fails closed to GitHub.
// Chromium's virtual authenticator signs real WebAuthn assertions; the API is routed.
const assert = require('node:assert/strict');
const { generateKeyPairSync, randomBytes } = require('node:crypto');
const { withHostedPage } = require('./registry-browser-fixture.cjs');

const checkHostedPasskey = browser => withHostedPage(browser, checkPasskeySignIn);
const csrfToken = 'sha256:' + 'c'.repeat(64);
const base64url = bytes => Buffer.from(bytes).toString('base64url');

async function virtualAuthenticator(page, rpId) {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('WebAuthn.enable');
  const {authenticatorId} = await cdp.send('WebAuthn.addVirtualAuthenticator', {options:{
    protocol:'ctap2', transport:'internal', hasResidentKey:true, hasUserVerification:true,
    isUserVerified:true, automaticPresenceSimulation:true}});
  const privateKey = generateKeyPairSync('ec', {namedCurve:'P-256'}).privateKey.export({format:'der', type:'pkcs8'});
  const credentialId = randomBytes(16);
  await cdp.send('WebAuthn.addCredential', {authenticatorId, credential:{credentialId:credentialId.toString('base64'),
    isResidentCredential:true, rpId, privateKey:privateKey.toString('base64'),
    userHandle:Buffer.from('11111111-1111-4111-8111-111111111111').toString('base64'), signCount:0}});
  return {cdp, authenticatorId, credentialId:base64url(credentialId)};
}

// The routed API: options hand out a fresh challenge, verify records each assertion and answers
// the scenario's status; a session exists only after a verify the scenario accepts.
async function routeApi(page, website, api, state) {
  const headers = {'access-control-allow-origin':website, 'access-control-allow-credentials':'true'};
  const preflight = route => route.fulfill({status:204, headers:{...headers,
    'access-control-allow-methods':'POST', 'access-control-allow-headers':'Content-Type'}});
  await page.route(api + '/v1/packages', route => route.fulfill({headers, json:{packages:[]}}));
  await page.route(api + '/v1/auth/session', route => route.fulfill({status:state.signedIn ? 200 : 401, headers,
    json:{authenticated:state.signedIn, csrfToken}}));
  await page.route(api + '/v1/auth/passkey/options', route => {
    if (route.request().method() === 'OPTIONS') return preflight(route);
    assert.equal(route.request().method(), 'POST');
    state.options++;
    if (state.optionsStatus !== 200) return route.fulfill({status:state.optionsStatus, headers,
      contentType:'application/problem+json', body:JSON.stringify({code:'auth.passkey-unavailable', status:state.optionsStatus})});
    state.challenge = base64url(randomBytes(32));
    return route.fulfill({headers, json:{publicKey:{challenge:state.challenge, rpId:state.rpId,
      timeout:60000, userVerification:'required', allowCredentials:[]}}});
  });
  await page.route(api + '/v1/auth/passkey/verify', route => {
    if (route.request().method() === 'OPTIONS') return preflight(route);
    assert.equal(route.request().method(), 'POST');
    state.verified.push({challenge:state.challenge, credential:JSON.parse(route.request().postData())});
    if (state.verifyStatus === 204) { state.signedIn = true; return route.fulfill({status:204, headers}); }
    return route.fulfill({status:state.verifyStatus, headers, contentType:'application/problem+json',
      body:JSON.stringify({code:'auth.passkey-rejected', status:state.verifyStatus})});
  });
}

function actions(page) {
  const panel = page.locator('[data-session-url]');
  return {panel, status:panel.getByRole('status'),
    passkey:panel.getByRole('button', {name:'Sign in with a passkey', includeHidden:true}),
    github:panel.getByRole('link', {name:'Sign in with GitHub', includeHidden:true})};
}

async function assertHierarchy(page) {
  const {panel, passkey, github} = actions(page);
  await passkey.waitFor();
  await github.waitFor();
  const order = await panel.locator('button:visible, a:visible').evaluateAll(nodes => nodes.map(node => node.textContent.trim()));
  assert.deepEqual(order, ['Sign in with a passkey', 'Sign in with GitHub'], 'passkey first, GitHub second, nothing else');
  const area = box => box.width * box.height;
  assert.ok(area(await passkey.boundingBox()) > area(await github.boundingBox()), 'passkey is the largest action');
  assert.equal(await github.getAttribute('href'), page.api + '/v1/auth/github/start');
}

// A failed passkey path never signs in: the status says so and GitHub stays offered and focused.
async function assertFailsClosed(page, state, before) {
  const {status, passkey, github} = actions(page);
  await passkey.click();
  await status.getByText('Passkey sign-in did not complete. Sign in with GitHub instead.', {exact:true}).waitFor();
  assert.equal(await github.isVisible(), true);
  assert.equal(await github.evaluate(link => document.activeElement === link), true);
  assert.equal(state.signedIn, false);
  assert.equal(await page.getByText(/Signed in/).count(), 0);
  assert.equal(await passkey.isDisabled(), false, 'the passkey action can be retried');
  assert.ok(state.options > before.options, 'each attempt asks the API for a fresh challenge');
}

async function assertSignedIn(page, state, website, credentialId) {
  const {panel, passkey, github} = actions(page);
  const attempts = state.verified.length;
  await passkey.click();
  await panel.getByText('Signed in. Publication requires a package grant and signature.').waitFor();
  assert.equal(state.verified.length, attempts + 1);
  const {challenge, credential} = state.verified.at(-1);
  assert.equal(credential.type, 'public-key');
  assert.equal(credential.id, credentialId);
  assert.equal(credential.rawId, credentialId);
  for (const field of ['authenticatorData', 'clientDataJSON', 'signature', 'userHandle']) assert.match(credential.response[field], /^[A-Za-z0-9_-]+$/u, field);
  const client = JSON.parse(Buffer.from(credential.response.clientDataJSON, 'base64url').toString('utf8'));
  assert.deepEqual([client.type, client.challenge, client.origin], ['webauthn.get', challenge, website]);
  assert.equal(await passkey.isVisible(), false);
  assert.equal(await github.isVisible(), false);
  assert.equal(await panel.getByRole('button', {name:'Sign out'}).isVisible(), true);
}

async function checkPasskeySignIn({page, website, api, failures}) {
  const rpId = new URL(website).hostname;
  const state = {rpId, signedIn:false, options:0, optionsStatus:200, verifyStatus:204, verified:[], challenge:''};
  page.api = api;
  await routeApi(page, website, api, state);
  const {cdp, authenticatorId, credentialId} = await virtualAuthenticator(page, rpId);
  // The auth screens [PACKAGE-HOSTED-AUTH]: signed out, the header offers Sign in and no release action;
  // register and recover go through GitHub; signing in swaps the header to Release a package everywhere.
  const bar = page.locator('.prose-desktop-nav');
  const signInLink = bar.getByRole('link', {name:'Sign in'});
  const releaseLink = bar.getByRole('link', {name:'Release a package'});
  for (const [screen, heading, action] of [['register', 'Create your account', 'Continue with GitHub'], ['recover', 'Lost your passkey?', 'Sign in with GitHub']]) {
    await page.goto(website + '/' + screen + '/');
    await page.getByRole('heading', {name:heading, level:1}).waitFor();
    assert.equal(await page.getByRole('link', {name:action}).getAttribute('href'), api + '/v1/auth/github/start');
    assert.equal(await signInLink.isVisible(), true);
    assert.equal(await releaseLink.count(), 0, 'no release action while signed out');
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  }
  await page.goto(website + '/signin/');
  await page.getByRole('heading', {name:'Sign in', level:1}).waitFor();
  await assertHierarchy(page);
  const account = page.getByRole('navigation', {name:'Account'});
  assert.deepEqual(await account.getByRole('link').evaluateAll(links => links.map(link => [link.textContent, link.getAttribute('href')])),
    [['Create an account', '/register/'], ['Lost your passkey?', '/recover/']]);
  assert.equal(await signInLink.getAttribute('href'), '/signin/');
  assert.equal(await releaseLink.count(), 0, 'no release action while signed out');
  await assertSignedIn(page, state, website, credentialId);
  assert.equal(await releaseLink.isVisible(), true);
  assert.equal(await signInLink.count(), 0);
  await page.goto(website + '/register/');
  await releaseLink.waitFor();
  assert.equal(await signInLink.count(), 0, 'a signed-in browser keeps the release action on every page');
  state.signedIn = false;
  await page.goto(website + '/recover/');
  await signInLink.waitFor();
  assert.equal(await releaseLink.count(), 0, 'an expired session takes the release action away');
  await page.goto(website + '/release/');
  await assertHierarchy(page);
  for (const [optionsStatus, verifyStatus] of [[503, 204], [429, 204], [200, 400], [200, 401], [200, 503]]) {
    Object.assign(state, {optionsStatus, verifyStatus});
    await page.goto(website + '/release/');
    await assertHierarchy(page);
    await assertFailsClosed(page, state, {...state});
  }
  Object.assign(state, {optionsStatus:200, verifyStatus:204});
  await cdp.send('WebAuthn.setUserVerified', {authenticatorId, isUserVerified:false});
  const verifiedBefore = state.verified.length;
  await page.goto(website + '/release/');
  await assertFailsClosed(page, state, {...state});
  assert.equal(state.verified.length, verifiedBefore, 'a refused ceremony never reaches verify');
  await cdp.send('WebAuthn.setUserVerified', {authenticatorId, isUserVerified:true});
  await page.goto(website + '/release/');
  await assertSignedIn(page, state, website, credentialId);
  state.signedIn = false;
  await page.addInitScript(() => { delete window.PublicKeyCredential; });
  await page.goto(website + '/release/');
  const {passkey, github} = actions(page);
  await github.waitFor();
  assert.equal(await passkey.isVisible(), false, 'without WebAuthn the screen offers GitHub only');
  assert.deepEqual(failures, []);
  await page.close();
}

module.exports = { checkHostedPasskey };
