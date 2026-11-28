// Populate a form from a JSON collection and review its values before authorization.
const form = document.querySelector('[data-collection-form]');
const select = form.querySelector('select');
const review = document.getElementById(form.dataset.review);
const message = form.querySelector('[role=status]');

function accountRequest(url, options) {
  return fetch(url, {
    ...options, credentials: 'include', cache: 'no-store', redirect: 'error', signal: AbortSignal.timeout(10000),
  });
}

// [PACKAGE-HOSTED-AUTH] sign-in hierarchy: passkey first when the browser has WebAuthn, GitHub second.
const passkeySupported = () => typeof PublicKeyCredential === 'function'
  && typeof PublicKeyCredential.parseRequestOptionsFromJSON === 'function';

function signedOut(parts) {
  parts.signOut.hidden = true;
  parts.passkey.hidden = !passkeySupported();
  parts.login.hidden = false;
}

function signedIn(parts, csrfToken) {
  parts.status.textContent = parts.panel.dataset.active;
  parts.passkey.hidden = true;
  parts.login.hidden = true;
  parts.signOut.hidden = false;
  parts.csrfToken = csrfToken;
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

function accountParts(panel) {
  return {panel, status: panel.querySelector('[role=status]'), login: panel.querySelector('a'),
    passkey: panel.querySelector('[data-passkey]'), signOut: panel.querySelector('[data-sign-out]'), csrfToken: ''};
}
const account = document.querySelector('[data-session-url]');
if (account) {
  const parts = accountParts(account);
  bindPasskey(parts);
  bindLogout(parts);
  void showSession(parts);
}
try {
  const response = await fetch(form.dataset.collection, {credentials: 'omit', signal: AbortSignal.timeout(10000)});
  if (!response.ok) throw Error('Collection unavailable');
  const items = (await response.json())[select.dataset.collectionKey];
  if (!Array.isArray(items)) throw Error('Invalid collection');
  for (const item of items) {
    const name = item[select.dataset.valueKey];
    if (typeof name !== 'string') throw Error('Invalid entry');
    select.add(new Option(name, name));
  }
  if (items.length) {
    form.querySelector('fieldset').disabled = false;
    message.textContent = '';
  } else message.textContent = form.dataset.empty;
} catch {
  message.textContent = form.dataset.error;
}
form.addEventListener('submit', event => {
  event.preventDefault();
  for (const output of review.querySelectorAll('[data-field]')) {
    output.textContent = form.elements.namedItem(output.dataset.field).value;
  }
  review.hidden = false;
  review.focus();
});
form.addEventListener('input', () => { review.hidden = true; });
