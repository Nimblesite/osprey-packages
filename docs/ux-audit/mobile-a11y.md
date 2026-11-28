# Mobile, tablet, accessibility and performance UX audit

Tested in Chromium at 1440×900, 1024×768 and 390×844, with touch emulation on mobile. I used keyboard-only Tab/Enter/Escape navigation, axe-core WCAG checks, API delay/failure injection, throttled mobile network/CPU, reduced-motion emulation, direct URLs, back/forward/reload, and screenshots. The live deployment changed during the audit; each finding below was reproduced when captured.

| Severity | Count |
|---|---:|
| critical | 0 |
| major | 6 |
| minor | 10 |
| nit | 2 |
| **Total** | **18** |

## Home — `https://packages.ospreylang.dev/`

- **[minor]** Back restores a different query in the field from the URL (all viewports): search `json`, then `other`, then press Back. The URL becomes `?q=json` but the input still contains `other`; results and visible query can therefore disagree → restore the input and results from the URL on `popstate`/history restoration.
- **[minor]** Empty and whitespace-only searches create junk history entries (all viewports): blank submits `?q=` and three spaces submit `?q=+++` without trimming or validation → trim the query and prevent an empty search from navigating or adding history.
- **[minor]** A submitted query is not acknowledged in the result state (390×844, 1024×768 and 1440×900): `?q=json` still says only “No packages published yet,” with no query echo, no-results-for-query copy or clear-search action → say “No packages match ‘json’” and provide a clear/reset action.
- **[minor]** The “By publisher” and “By tag” chips are only 39.2px tall at 390×844 (and at the other viewports), below the requested 44px touch target → make the full chip hit area at least 44×44px without relying on precise taps.
- **[minor]** The catalog failure state is a dead end (390×844 and 1024×768): when `/v1/packages` fails, the page says “The public catalog is unavailable” but offers neither Retry nor a recovery link; only an unstated manual reload remains → provide a keyboard-accessible Retry button and preserve the current query while retrying.

## Global header and navigation — every live and mirror page

- **[minor]** No navigation link exposes `aria-current`, and there is no visual current-page state (all viewports). On `/upload/`, for example, “Upload a package” links to the current page but looks identical to its state elsewhere; mobile Browse/Publisher/Tag links have the same problem → set `aria-current="page"` and a visible active style on the applicable navigation item.

## Upload — `https://packages.ospreylang.dev/upload/`

- **[major]** Several essential controls miss the 44px target badly at 390×844 and 1024×768: “Review release” is 31px tall, the Package select is 42.8px, and “Sign in with GitHub” is only 22.3px. The authentication alternative is especially hard to hit on a phone → give every interactive control at least a 44px-high hit area and adequate separation.
- **[minor]** The hero’s “Browse packages” back link is only 24.8px tall at 390×844 and 1024×768 (also 24.8px on desktop; the mirror has the same defect) → expand its clickable area to at least 44px high.
- **[minor]** Every anonymous visit produces a failed `GET /v1/auth/session` with HTTP 401 and a console error (all viewports), treating the normal signed-out state as a resource-loading failure → use a non-error signed-out response or handle the expected state without polluting the console and failed-request stream.
- **[nit]** The empty-catalog message has zero separation from the button above it (390×844 and 1024×768): “Review release” ends at y=721 and “The registry has no packages.” starts at y=721, making the status look crammed into the control → add clear vertical spacing and group the status with the form rather than the button edge.

## Publishers directory — `https://packages.ospreylang.dev/publishers/`

- **[major]** Following the visible publisher link redirects to `/package` and renders “The registry could not load this page” with no `h1` at any tested viewport; axe reports `page-has-heading-one`. Screen-reader and keyboard users get no page title/heading context or structured error → render a real Publishers `h1` and directory, or an honest publisher-directory error page with a heading and recovery action.

## Tags directory — `https://packages.ospreylang.dev/tags/`

- **[major]** Following the visible tag link also redirects to `/package` and produces the same headingless generic error at 390×844, 1024×768 and 1440×900; axe reports `page-has-heading-one` → render a Tags `h1` and usable empty/directory state, or a properly identified error with retry and browse recovery.

## Package guide — `/guide/` on live and mirror

- **[major]** The command block is horizontally scrollable but keyboard-inaccessible at 390×844: `<pre>` has `overflow-x:auto`, 947px of content in a 363px client area, and no `tabindex`; Tab skips from navigation to the footer, so keyboard-only users cannot focus and scroll to the clipped commands → wrap commands where possible, or make the scroll region focusable with a visible focus indicator and an accessible label.

## Publishing guide — `/publishing/` on live and mirror

- **[major]** The publishing command has the same keyboard trap-by-omission at 390×844: its `<pre>` contains 745px of text in a 363px viewport but is not focusable, so keyboard-only users cannot reveal the offscreen command → make the region keyboard-scrollable and labelled, or wrap/provide individually accessible commands.

## 404 and error presentation

- **[nit]** Equivalent failures use unrelated visual hierarchies at 390×844: an unknown URL gets a plain “Page not found” heading on the page background, while `/package` failure puts one sentence inside a tall dark hero panel → use one consistent error template, heading hierarchy and recovery pattern so failure states are recognizable rather than looking like different products.

## Mirror home — `https://nimblesite.github.io/osprey-packages/`

- **[major]** The mirror is a nonfunctional dead end at 390×844 and 1024×768: the search input and button are disabled, “The public catalog is unavailable” is the only state, and there is no Retry or link to the canonical live registry. Disabled controls are skipped in keyboard order and are not programmatically associated with the explanation → either provide working mirror search or replace the disabled form with a clear explanation and a prominent live-registry/retry action.
- **[minor]** The mirror omits the visible “By publisher” and “By tag” shortcuts that the live home shows (390×844 and 1024×768), leaving directory discovery only inside mobile menu links that lead to 404s → keep information architecture consistent across live and mirror and do not hide the only directory entry points in a broken menu.

## Mirror upload — `https://nimblesite.github.io/osprey-packages/upload/`

- **[minor]** The sole publishing recovery action, “Publish to a folder registry,” is an 18px-high inline link at 390×844 (also 18px at tablet/desktop), far below a reliable touch target → make the recovery action a button-like link with a minimum 44px-high hit area.
