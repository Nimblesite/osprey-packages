// The account panel, and on the release page a form populated from a JSON collection and reviewed before authorization.
function accountRequest(url, options) {
  return fetch(url, {
    ...options, credentials: 'include', cache: 'no-store', redirect: 'error', signal: AbortSignal.timeout(10000),
  });
}

// [PACKAGE-HOSTED-AUTH] sign-in hierarchy: passkey first when the browser has WebAuthn, GitHub second.
const passkeySupported = () => typeof PublicKeyCredential === 'function'
  && typeof PublicKeyCredential.parseRequestOptionsFromJSON === 'function';

// The header script shows Release a package only for a session this panel verified.
function report(parts, signedIn) {
  if (signedIn) localStorage.setItem('registry-session', parts.panel.dataset.sessionUrl);
  else localStorage.removeItem('registry-session');
  document.dispatchEvent(new CustomEvent('registry-session', {detail: signedIn}));
}

function signedOut(parts) {
  report(parts, false);
  parts.csrfToken = '';
  parts.receipts?.close();
  parts.steps?.close();
  parts.signOut.hidden = true;
  parts.passkey.hidden = !passkeySupported();
  parts.login.hidden = false;
}

function signedIn(parts, csrfToken) {
  report(parts, true);
  parts.status.textContent = parts.panel.dataset.active;
  parts.passkey.hidden = true;
  parts.login.hidden = true;
  parts.signOut.hidden = false;
  parts.csrfToken = csrfToken;
  parts.receipts?.open();
  parts.steps?.open();
}

async function postJson(url, body) {
  return accountRequest(url, {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)});
}

// Every failure (options, ceremony, verify) fails closed to GitHub: no session, GitHub focused.
async function passkeySignIn(parts) {
  const options = await postJson(parts.panel.dataset.passkeyOptions, {});
  if (options.status !== 200) throw Error(await options.text());
  const {publicKey} = await options.json();
  const credential = await navigator.credentials.get({publicKey: PublicKeyCredential.parseRequestOptionsFromJSON(publicKey)});
  const verified = await postJson(parts.panel.dataset.passkeyVerify, credential.toJSON());
  if (verified.status !== 204) throw Error(await verified.text());
  await showSession(parts);
}

function bindPasskey(parts) {
  parts.passkey.addEventListener('click', async () => {
    parts.passkey.disabled = true;
    try {
      await passkeySignIn(parts);
    } catch {
      parts.status.textContent = parts.panel.dataset.passkeyError;
      parts.login.focus();
    } finally {
      parts.passkey.disabled = false;
    }
  });
}

function bindLogout(parts) {
  parts.signOut.addEventListener('click', async () => {
    parts.signOut.disabled = true;
    try {
      const response = await accountRequest(parts.panel.dataset.logoutUrl, {
        method: 'POST', headers: {'X-CSRF-Token': parts.csrfToken},
      });
      if (response.status !== 204) {
        await response.text();
        throw Error('Logout unavailable');
      }
      parts.status.textContent = parts.panel.dataset.signedOut;
      signedOut(parts);
      parts.signOut.remove();
      (parts.passkey.hidden ? parts.login : parts.passkey).focus();
    } catch {
      parts.status.textContent = parts.panel.dataset.logoutError;
    } finally {
      parts.signOut.disabled = false;
    }
  });
}

async function showSession(parts) {
  try {
    const response = await accountRequest(parts.panel.dataset.sessionUrl);
    if (response.status === 401) {
      parts.status.textContent = '';
      signedOut(parts);
      return;
    }
    if (response.status !== 200) throw Error('Session unavailable');
    const session = await response.json();
    if (session.authenticated !== true || !/^sha256:[0-9a-f]{64}$/.test(session.csrfToken)) throw Error('Invalid session');
    signedIn(parts, session.csrfToken);
  } catch {
    parts.status.textContent = parts.panel.dataset.error;
  }
}

// [PACKAGE-SECURITY-SCAN-APPROVAL] Only a database-backed receipt can enable the decision.
function bindReceipts(parts) {
  const panel = document.querySelector('[data-receipt-panel]');
  if (!panel) return;
  const form = panel.querySelector('form');
  const input = form.elements.submission;
  const status = panel.querySelector('[role=status]');
  const findings = panel.querySelector('[data-findings]');
  const approve = panel.querySelector('[data-approve]');
  const base = new URL(parts.panel.dataset.sessionUrl).origin;
  const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
  let pending;
  let generation = 0;
  function clear() {
    generation++;
    pending = undefined;
    approve.hidden = true;
    status.textContent = '';
    findings.replaceChildren();
  }
  const labels = {'pending-scan':'Waiting for the security scan.', 'awaiting-admin':'Waiting for administrator approval.',
    rejected:'Submission rejected. Address each finding and submit the corrected commit.', approved:'Administrator approval recorded.'};
  async function load(id) {
    clear();
    const request = generation;
    if (!uuid.test(id)) { status.textContent = 'Enter a valid submission ID.'; return; }
    try {
      const response = await accountRequest(base + '/v1/publications/' + id);
      if (!response.ok) throw Error();
      const row = await response.json();
      if (row.submissionId !== id || !uuid.test(row.packageId) || !Object.hasOwn(labels, row.status) || !/^sha256:[0-9a-f]{64}$/.test(row.digest)
        || !Number.isSafeInteger(row.epoch) || row.epoch < 1 || !Number.isSafeInteger(row.ordinal) || row.ordinal < 1
        || !Array.isArray(row.messages) || row.messages.some(text => typeof text !== 'string' || !text.trim())) throw Error();
      if (generation !== request) return;
      status.textContent = `Package ${row.packageId} · Version ${row.epoch}.${row.ordinal} · ${row.digest}. ${labels[row.status]}`;
      for (const text of row.messages) {
        const item = document.createElement('li');
        item.textContent = text;
        findings.append(item);
      }
      if (row.canApprove === true && row.status === 'awaiting-admin') {
        pending = row;
        approve.hidden = false;
      }
    } catch { if (generation === request) status.textContent = 'The registry could not load this submission.'; }
  }
  approve.addEventListener('click', async () => {
    if (!pending) return;
    const row = pending;
    clear();
    const request = generation;
    try {
      const response = await accountRequest(`${base}/v1/reviews/${row.submissionId}/${row.digest}/approve`,
        {method:'POST', headers:{'X-CSRF-Token':parts.csrfToken}});
      if (response.status !== 204) throw Error();
      if (generation === request) await load(row.submissionId);
    } catch { if (generation === request) status.textContent = 'Check the submission status before retrying approval.'; }
  });
  form.addEventListener('submit', event => { event.preventDefault(); void load(input.value.trim()); });
  input.addEventListener('input', clear);
  return {open() { panel.hidden = false; }, close() { clear(); form.reset(); panel.hidden = true; }};
}

function accountParts(panel) {
  return {panel, status: panel.querySelector('[role=status]'), login: panel.querySelector('a'),
    passkey: panel.querySelector('[data-passkey]'), signOut: panel.querySelector('[data-sign-out]'), csrfToken: ''};
}
const account = document.querySelector('[data-session-url]');
if (account) {
  const parts = accountParts(account);
  parts.receipts = bindReceipts(parts);
  parts.steps = bindReleaseSteps(parts);
  bindPasskey(parts);
  bindLogout(parts);
  void showSession(parts);
}
// The release steps [PACKAGE-HOSTED-PUBLISH-FLOW]: the Osprey guest (ReleaseSteps) builds each request
// and words each reply; this bridge only collects the fields, POSTs and writes the answer.
function bindReleaseSteps(parts) {
  const section = document.querySelector('[data-release-steps]');
  const script = document.querySelector('script[data-guest]');
  if (!section || !script) return {open() {}, close() {}};
  const oneLine = text => text.replace(/[\r\n\t]/gu, ' ');
  const loaded = Promise.all([fetch(script.dataset.guest).then(r => r.ok ? r.arrayBuffer() : Promise.reject(Error())), import(script.dataset.host)]);
  loaded.catch(() => {});
  async function guest(lines) {
    const [wasm, {runModule}] = await loaded;
    let out = '';
    await runModule(wasm, part => { out += part; }, lines.join('\n') + '\n');
    return out.split('\n');
  }
  async function submit(form) {
    const status = form.querySelector('[role=status]');
    const fields = [...(form.dataset.needs ? [section.dataset[form.dataset.needs] ?? ''] : []),
      ...[...form.elements].filter(e => e.name).map(e => oneLine(e.value))];
    const [path, body] = await guest(['release-request', form.dataset.releaseStep, fields.join('\t')]);
    if (path === 'invalid') { status.textContent = body; return; }
    let code = '0', text = '';
    try {
      const response = await accountRequest(section.dataset.api + path, {method: 'POST',
        headers: {'Content-Type': 'application/json', 'X-CSRF-Token': parts.csrfToken}, body});
      [code, text] = [String(response.status), oneLine(await response.text())];
    } catch { /* the guest words a request that never completed */ }
    const [outcome, ...rest] = await guest(['release-reply', form.dataset.releaseStep, code, text]);
    if (outcome === 'ok' && form.dataset.creates) section.dataset[form.dataset.creates] = rest[0];
    status.textContent = outcome === 'ok' ? `${rest[1]}${form.dataset.creates === 'submission' ? ' ' + rest[0] : ''}` : rest[0];
  }
  for (const form of section.querySelectorAll('form[data-release-step]')) {
    form.addEventListener('submit', event => {
      event.preventDefault();
      submit(form).catch(() => { form.querySelector('[role=status]').textContent = 'The registry is unavailable. Try again shortly.'; });
    });
  }
  // A returning publisher continues with an organization or package from GET /v1/account.
  const pick = section.querySelector('[data-release-pick]');
  const choice = pick.querySelector('select');
  let picks = [];
  async function account() {
    let code = '0', text = '';
    try {
      const response = await accountRequest(section.dataset.api + '/v1/account');
      [code, text] = [String(response.status), oneLine(await response.text())];
    } catch { /* the guest words a request that never completed */ }
    const lines = (await guest(['release-account', code, text])).filter(Boolean).map(l => l.split('\t'));
    choice.length = 1;
    picks = lines.filter(([kind]) => kind === 'pick');
    picks.forEach(([, label], i) => choice.add(new Option(label, String(i))));
    pick.querySelector('[role=status]').textContent = lines.find(([kind]) => kind === 'error')?.[1] ?? '';
  }
  choice.addEventListener('change', () => {
    const [, , organization, pkg, version, message] = (choice.value === '' ? undefined : picks[Number(choice.value)]) ?? ['', '', '', '', '', ''];
    section.dataset.organization = organization;
    section.dataset.package = pkg;
    if (version) section.querySelector('[data-release-step=release] [name=version]').value = version;
    pick.querySelector('[role=status]').textContent = message;
  });
  return {open() { section.hidden = false; account().catch(() => {}); }, close() { section.hidden = true; }};
}
