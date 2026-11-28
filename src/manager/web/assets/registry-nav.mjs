// The header follows the session [PACKAGE-HOSTED-AUTH]: Sign in while signed out, Release a package once signed in.
// Anonymous visitors make no API request: only a browser that signed in here asks for its session again.
const key = 'registry-session';
const show = signedIn => {
  for (const node of document.querySelectorAll('.prose-bar [data-session]')) node.hidden = (node.dataset.session === 'in') !== signedIn;
};
document.addEventListener(key, event => show(event.detail === true));
const url = localStorage.getItem(key);
// A page with an account panel reports its own session through the event above.
if (url && !document.querySelector('[data-session-url]')) {
  try {
    if (new URL(url).pathname !== '/v1/auth/session') throw Error('Invalid session URL');
    const response = await fetch(url, {credentials: 'include', cache: 'no-store', redirect: 'error', signal: AbortSignal.timeout(10000)});
    if (response.status === 200 && (await response.json()).authenticated === true) show(true);
    else if (response.status === 401) localStorage.removeItem(key);
  } catch {
    localStorage.removeItem(key);
  }
}
