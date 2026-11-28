# UX audit — sign in, upload, account panel, receipt form

Auditor: `UxPiAccount` · Target: <https://packages.ospreylang.dev/> (mirror <https://nimblesite.github.io/osprey-packages/>) · API: <https://packages-api.ospreylang.dev/v1>
Method: Playwright/Chromium at 1440×900, 1024×768, 390×844 (+320px reflow, 200% zoom). Live API plus route-mocked API states (signed in/out, 401/404/500/503, 11 s delays, network abort) and a CDP virtual authenticator for the passkey ceremony. Scripts and screenshots in `/tmp/ux-UxPiAccount/`.

| Severity | Count |
|---|---|
| critical | 6 |
| major | 14 |
| minor | 13 |
| nit | 7 |
| **Total** | **40** |

Headline: there is no sign-in page, the passkey and publication endpoints return 503 in production, the registry is empty so the upload form is dead, the review step has no submit button, and the sign-out button disappears after a second sign-in.

## Site-wide / sign-in discovery

- **[critical]** No sign-in route exists. `/signin/`, `/login/`, `/register/`, `/recover/`, `/account/` all return 404 "Page not found" (1440/1024/390); the 404 page offers only a tiny "Browse packages" link. The repo's own E2E (`scripts/packages/registry-hosted-passkey.cjs`) expects `/signin/`, `/register/`, `/recover/`, a header "Sign in" link and an "Account" nav — none are deployed → a user looking for sign in expects `/signin/` (and a link to it from the 404 page).
- **[major]** No "Sign in" control anywhere in the header: desktop nav shows only "Upload a package"; the mobile `Menu` lists Browse / By publisher / By tag / Upload. Sign-in is only discoverable by scrolling ~800 px down `/upload/` to the "Publisher account" card → a persistent Sign in / Account control in the header on every page.
- **[major]** The mirror `nimblesite.github.io/osprey-packages/upload/` (the URL AGENTS.md advertises) serves a different, stale build: "Public uploads are unavailable." plus a "Publish to a folder registry" link, no form, no sign-in; the aside copy also differs ("Your signing credential to approve the release" vs live "to authorize the submission"). CSS hash differs (`registry.e5b3f1a50ee3.css` vs `registry.f3c439e00338.css`) → mirror and live must be the same build, or the mirror should redirect.
- **[minor]** Header "Upload a package" link lacks `aria-current="page"` when on `/upload/` → add it.
- **[nit]** `/upload`, `/upload/` and `/upload/index.html` all return 200 → one canonical URL with redirects.

## Upload page — "Prepare a release" form

- **[critical]** Live registry is empty (`/v1/packages` → `{"packages":[]}`), so the whole fieldset (package `<select>`, commit input, button) is disabled and the status reads "The registry has no packages." (all viewports). Dead end: nothing explains how to get a package listed, no link to docs or a create-package flow → an empty-state with a next step ("Register a package", docs link).
- **[critical]** The flow dead-ends after "Review release" (verified with a mocked non-empty catalog): the review article shows "Package X / Commit Y" and "Publication requires an authorized account and a signature." — there is no Submit / Publish / Sign / Continue button anywhere on the page → a submit action, or an explicit instruction of where the signature is produced and how it is submitted.
- **[major]** Disabled state is misleading (live, all viewports): the select text and commit input grey out, but the "Review release" button stays full lime with normal cursor and no dimming — it looks clickable and does nothing → dim it, change the cursor, or hide the form and show the empty state alone.
- **[major]** Commit hash validation (mocked catalog, 1440): the only feedback is the browser bubble "Please match the requested format."; the `title` ("Enter the full 40-character Git commit hash") is not shown by Chromium; there is no placeholder, example, visible hint or `:invalid` styling → visible format hint + inline error.
- **[minor]** Commit input has `spellcheck=true`, no `autocapitalize=off`/`autocorrect=off`/`autocomplete=off`/`inputmode` → mobile keyboards autocorrect and capitalise a hex hash; browser autofill can fill it.
- **[minor]** `maxlength="40"` silently truncates: typing a 41st char or pasting a hash with a trailing character drops the extra char; pasting with leading whitespace fails the pattern with the generic bubble → trim on paste, validate the whole value.
- **[minor]** Label grouping ambiguous (all viewports): labels sit 0.5 rem from the previous input and 0.5 rem from their own (fieldset `gap`), so "Git commit" reads as the caption of the Package select → tighter label-to-own-input spacing, more space between groups.
- **[minor]** Select and commit input use browser-default chrome — pure black text on white with a system border — not the site palette (`--ink` #172921, `--paper`); they look unstyled beside the lime buttons → inherit palette and radius consistently.
- **[minor]** "Review release" is 123×31 px with 13.3 px text (all viewports): below the 44 px tap target and the smallest element in the form although it is the primary action; "Sign in with a passkey" is 18.4 px/49 px → consistent button scale and ≥44 px targets.
- **[minor]** Review article has no panel, border or spacing: it sits flush under the button, its h3 repeats the button label "Review release", and the status text ("The registry has no packages.") hugs the button like a caption (1440/390) → a bordered review card with a clear heading and spacing.
- **[nit]** Package `<select>` is `required` with no required indicator; "Choose a package" renders as a normal option → placeholder-style option + required marker.
- **[nit]** Catalog error "Could not load packages from the registry. Reload to retry." offers no Retry button.

## Upload page — Publisher account panel (sign in / sign out)

- **[critical]** Passkey sign-in is broken in production: `POST /v1/auth/passkey/options` → 503 `registry.not-ready`; clicking "Sign in with a passkey" (live, 726 ms) shows "Passkey sign-in did not complete. Sign in with GitHub instead." — it blames the user's passkey instead of saying the service is down → surface the server failure ("Passkey sign-in is unavailable right now") and still offer GitHub.
- **[major]** If `GET /v1/auth/session` fails (mocked 500, network abort, or an 11 s delay that trips the 10 s `AbortSignal`), every sign-in control stays `hidden` and the status reads "The registry could not verify your session. Reload to retry." — the user cannot sign in at all even though the sign-in endpoints may work (1440) → on session-check failure show the sign-in buttons (treat as signed out) with a warning.
- **[major]** After Sign out the button is `remove()`d from the DOM; a later passkey sign-in sets `.hidden=false` on the detached node, so the second sign-in has no Sign out button — the user is stuck signed in until reload (verified with a virtual authenticator, 1440) → keep the button and toggle `hidden`.
- **[major]** Signed-in state shows no identity (no handle, email or avatar): "Signed in. Publication requires a package grant and signature." — yet the card says "Use the account with publishing permission for this package", so the user cannot verify which account is active (mocked 200, 1440/390) → show the signed-in identity and its grants.
- **[major]** Without WebAuthn (older Safari/Firefox, or `PublicKeyCredential.parseRequestOptionsFromJSON` missing — verified by deleting `PublicKeyCredential`), the only sign-in method is a 14.4 px underlined text link 126×22 px styled as a footnote (1440) → when it is the sole method it must be a full-size primary button.
- **[major]** "Sign in with GitHub" is a plain same-tab link to `packages-api.ospreylang.dev/v1/auth/github/start` → Supabase → `github.com/login` (verified). It leaves the site with no warning, and Back reloads `/upload/` and discards the typed commit hash (verified: commit `""` after Back) → preserve form state across sign-in (e.g. sessionStorage) or prompt sign-in before the form.
- **[minor]** Signed-out state blanks the `role=status` region (no "Not signed in" text); the passkey and GitHub controls appear silently with no announcement or focus, so the card shows a lone button with no context (all viewports) → "You are not signed in." as the resting text.
- **[minor]** After a successful passkey sign-in focus drops to `<body>` (the focused button is hidden) and the receipt panel appears ~1000 px down with no scroll, focus or announcement (1440) → move focus to the status/identity line and reveal the receipt panel.
- **[minor]** No loading state on "Sign in with a passkey": the button is disabled during the ceremony but its appearance is unchanged (`:disabled` has no style) and the text never changes → "Waiting for your passkey…" and a dimmed button.
- **[minor]** Every passkey failure — options 503, verify 401, user cancels the user-verification prompt (all mocked) — collapses to the same "Passkey sign-in did not complete. Sign in with GitHub instead." A cancelled prompt is indistinguishable from an outage → distinct messages for cancelled / rejected / unavailable.
- **[minor]** Sign out is 84×35 px with 13.3 px text and a dark UA border — a third button style on the page (Review release: lime, no border; passkey: lime, 18.4 px; Sign out: lime + black border) and under the tap-target size → one button component.
- **[minor]** The expected signed-out state logs a console error and `net::ERR_ABORTED` for the 401 session response on every load (the body is never read, so the connection is held until the 10 s abort); `networkidle` takes ~10.7 s → read/consume the 401 body; don't treat 401 as an error.
- **[nit]** All status messages are plain 16 px text with no colour or icon: "Signed out." looks identical to the error "Passkey sign-in did not complete…" → style errors vs informational messages.

## Upload page — Publication review (receipt form)

- **[critical]** `GET /v1/publications/{id}` → 503 `registry.not-ready` in production; "Check status" always says "The registry could not load this submission." (live) → deploy the endpoint or hide the panel until it works.
- **[critical]** Mobile 390 (mocked 200): the status text contains the unbreakable 71-char `sha256:…` digest; `scrollWidth 622 > clientWidth 390`, the digest runs off the right edge and the whole page scrolls sideways (screenshot `receipt-390.png`) → `overflow-wrap:anywhere` on the status and a short digest.
- **[major]** "Check status" shows the identical "The registry could not load this submission." for 404 (unknown ID), 401 (session expired), 500 and 503 (all mocked) → distinct "not found" / "sign in again" / "unavailable" messages.
- **[major]** Unstyled browser-default controls (1440/390): "Check status" and "Approve this version" are grey UA buttons (13.3 px, ~21 px tall, black border, `#efefef`); the "Submission ID" input is 153 px wide with a `#767676` border and clips a UUID ("11111111-2222-4333-84") → apply the site's input/button styles; full-width input on mobile.
- **[major]** "Approve this version" is a one-click administrator approval with no confirmation dialog and no summary of what is being approved, styled as the least prominent element on the page (mocked `awaiting-admin` + `canApprove`) → confirm step with package, version and digest.
- **[major]** Placement: the receipt panel sits below "What you'll need", its top at 1055 px at 1440 (below the fold), and its h2 "Publication review" is flush against the cards above (no top margin, unlike every other section). It appears on sign-in with no scroll or focus → place it inside/next to the "Publisher account" card with normal section spacing and focus it on reveal.
- **[minor]** "Enter a valid submission ID." — no format hint, `pattern`, `inputmode`, placeholder or example; uppercase UUIDs are rejected; `maxlength="36"` silently truncates longer pastes so a 37-char paste yields the misleading "The registry could not load this submission." instead of "invalid ID" (mocked) → accept case-insensitively, show an example, validate before truncating.
- **[minor]** Status prints the full digest inline: "Version 2.3 · sha256:aaaa…aaaa. Waiting for administrator approval." — noise, no copy button, no link to the package/version (mocked) → "my-pkg 2.3 · digest aaaa…aaaa ⧉".
- **[minor]** No loading state on "Check status" (button stays enabled, no spinner); a slow API (mocked 11 s) shows nothing for 10 s then the generic error; no retry (1440) → busy state and a Retry affordance.
- **[nit]** Findings render as a plain bulleted list with no severity or labels; "Address each finding and submit the corrected commit" has no link back to the form.
- **[nit]** Submission ID input has `spellcheck=true`, no `autocapitalize=off`.

## API-down behaviour (whole page)

- **[major]** With the API unreachable (mocked `connectionrefused`, 1440): catalog status "Could not load packages from the registry. Reload to retry." and session status "The registry could not verify your session. Reload to retry." appear together; the fieldset is disabled and both sign-in controls are `hidden`. The page is a complete dead end — no Retry button, no status-page link, no explanation of which service is down → a single prominent error state with Retry and a status link.

## Timings / misc

- **[nit]** Page shell is fast (TTFB ~155 ms, load ~207 ms) but nothing indicates activity beyond text ("Loading packages…", "Checking your registry session…"); `networkidle` takes ~10.7 s because of the unread 401 body → consume the response body.
- **[nit]** Contrast is fine everywhere measured (lowest: facts `dt` 5.9:1, footer 6.4:1; disabled select text 3.95:1 is exempt). 200% zoom at 1024 and 320 px reflow do not overflow — the only overflow is the digest in the receipt status above.
