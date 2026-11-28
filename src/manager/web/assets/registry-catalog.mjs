// Feed an anonymous API response to the registry's WASI renderer.
const binding = document.querySelector('script[data-catalog]');
const detail = document.getElementById('package-details');
const results = detail ?? document.getElementById('results');
const status = document.getElementById('catalog-status');
const field = document.querySelector('input[type=search]');
if (field) field.value = new URLSearchParams(location.search).get('q') ?? '';
function retryMessage(response) {
  const raw = response.headers.get('Retry-After')?.trim() ?? '';
  const seconds = /^\d+$/u.test(raw) ? Number(raw) : 0;
  const reason = response.status === 429 ? 'Too many requests.' : 'The package catalog is temporarily busy.';
  return seconds > 0 ? `${reason} Please retry in ${seconds} seconds.` : `${reason} Please retry in a moment.`;
}

try {
  const options = {credentials: 'omit', redirect: 'error', signal: AbortSignal.timeout(10000)};
  const endpoint = new URL(binding.dataset.catalog);
  if (detail && /^\/publishers\/[^/]+/u.test(location.pathname)) {
    endpoint.pathname = '/v1' + location.pathname.replace(/\/$/u, '') + '/releases';
  }
  const [api, guest, {runModule}] = await Promise.all([
    fetch(endpoint, options), fetch(binding.dataset.guest), import(binding.dataset.host),
  ]);
  if (detail && api.status === 404) throw new Error(status.dataset.missing);
  if (api.status === 429 || api.status === 503) throw new Error(retryMessage(api));
  if (!api.ok || !guest.ok) throw Error('Catalog unavailable');
  const source = JSON.stringify(await api.json());
  const lines = ['hosted-results', location.pathname, (field?.value ?? '').replace(/[\r\n]/gu, ' '), binding.dataset.content, source, ''];
  let html = '';
  await runModule(await guest.arrayBuffer(), part => { html += part; }, lines.join('\n'));
  if (!html.trim()) throw Error('Invalid projection');
  results.innerHTML = html;
  status.textContent = '';
  if (location.hash) document.getElementById(location.hash.slice(1))?.scrollIntoView();
} catch (error) {
  results.replaceChildren();
  const retryable = error.message.includes('Please retry');
  status.textContent = (detail && error.message === status.dataset.missing) || retryable ? error.message : status.dataset.error;
}
