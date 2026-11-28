// Browser bridge for the hosted catalog: it only fetches and writes. Which API path to read and what
// each reply becomes on the page are decided by the Osprey guest (CatalogReply) [PACKAGE-HOSTED-ROUTES-CATALOG].
const binding = document.querySelector('script[data-catalog]');
const detail = document.getElementById('package-details');
const results = detail ?? document.getElementById('results');
const status = document.getElementById('catalog-status');
const field = document.querySelector('input[type=search]');
if (field) field.value = new URLSearchParams(location.search).get('q') ?? '';
const kind = detail ? 'detail' : 'results';
const oneLine = text => text.replace(/[\r\n]/gu, ' ');

async function guest(wasm, runModule, lines) {
  let out = '';
  await runModule(wasm, part => { out += part; }, lines.join('\n') + '\n');
  return out;
}

async function reply(endpoint) {
  try {
    const response = await fetch(endpoint, {credentials: 'omit', redirect: 'error', signal: AbortSignal.timeout(10000)});
    return [String(response.status), oneLine(response.headers.get('Retry-After') ?? ''), await response.text()];
  } catch {
    return ['0', '', ''];
  }
}

try {
  const [module, {runModule}] = await Promise.all([fetch(binding.dataset.guest), import(binding.dataset.host)]);
  if (!module.ok) throw Error('Guest unavailable');
  const wasm = await module.arrayBuffer();
  const path = await guest(wasm, runModule, ['catalog-endpoint', location.pathname, kind]);
  const endpoint = new URL(binding.dataset.catalog);
  endpoint.pathname = path.trim();
  const [code, retryAfter, body] = await reply(endpoint);
  const out = await guest(wasm, runModule, ['catalog-reply', location.pathname, oneLine(field?.value ?? ''), binding.dataset.content, kind, code, retryAfter, oneLine(body)]);
  const split = out.indexOf('\n');
  const [target, text] = [out.slice(0, split), out.slice(split + 1)];
  if (target === 'html') {
    results.innerHTML = text;
    status.textContent = '';
    if (location.hash) document.getElementById(location.hash.slice(1))?.scrollIntoView();
  } else {
    results.replaceChildren();
    status.textContent = text.trim();
  }
} catch {
  results.replaceChildren();
  status.textContent = status.dataset.error;
}
