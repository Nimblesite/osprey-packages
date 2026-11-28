# Directory, guide, navigation and content UX audit

Tested the live registry and GitHub Pages mirror in Chromium at 1440×900, 1024×768 and 390×844. I followed the directory links, used the mobile menu with pointer and keyboard, exercised Back/Forward/reload, submitted empty and nonsensical searches, tried unknown publisher/tag URLs, disabled JavaScript, and inspected focus order, target sizes, overflow, console/network errors and screenshots. The live API returned `{"packages":[]}`; there is no populated publisher or tag journey to reach.

## Summary

| Severity | Count |
| --- | ---: |
| critical | 4 |
| major | 19 |
| minor | 29 |
| nit | 11 |
| **Total** | **63** |

## Home — directory entry points and empty/search copy

- **[minor]** “No packages published yet.” is a dead end below the directory chips (home, all viewports, with the live API returning an empty array) → explain the empty registry and provide a useful next action such as the publishing guide or upload flow.
- **[minor]** A gibberish search produces the same “No packages published yet.” copy as an unsearched catalog, with no query echo, result count or clear-search action (home, 390×844, search `xyzzy definitely no such package`) → say that no results match the submitted query and let the user clear or amend it.
- **[minor]** “By publisher” and “By tag” are only about 39px high on mobile, below the 44px touch-target minimum (home, 390×844, tap the two lavender chips) → provide at least 44×44px targets and adequate separation.
- **[nit]** The decorative hero artwork is cropped to a roughly 9px strip above a large dark panel, looking like a rendering accident rather than intentional art (home, 390×844) → use a deliberate mobile crop or remove the decoration at this breakpoint.

## Live By publisher directory — `/publishers/`

- **[critical]** The directory URL responds `308 Location: /package`, discarding the `/publishers/` route before the catalog renderer runs; the final error page is HTTP 200 (live, all viewports, open `/publishers/` or click “By publisher”) → preserve the route and render the publisher directory with an appropriate success/error status.
- **[major]** The destination contains only “The registry could not load this page.” and has no `h1` or other heading (live `/publishers/`, all viewports) → show a “Publishers” heading and either publisher results or a truthful empty state.
- **[major]** The failure has no Retry button, Browse packages link, support link or diagnostic next step; only the small brand link and Upload remain (live `/publishers/`, all viewports, reload or revisit after failure) → provide working recovery actions and keep directory navigation available.
- **[minor]** The browser title is “Package · Osprey Packages,” mislabelling the publisher directory in tabs, bookmarks and history (live `/publishers/`, inspect the title after redirect) → use “Publishers · Osprey Packages.”
- **[nit]** While loading, the status says “Loading packages…” instead of identifying the publisher directory (live `/publishers/`, delay the catalog request) → use route-appropriate loading copy such as “Loading publishers….”
- **[minor]** `/publishers` without the trailing slash returns the 404 page while guide URLs canonicalize to slash URLs (live, request `/publishers`) → redirect to `/publishers/` consistently instead of rejecting a common URL variant.

## Live publisher profiles — `/publishers/{publisherId}/`

- **[critical]** Publisher profile URLs also redirect to `/package`, dropping the publisher ID; even a syntactically valid UUID becomes the same HTTP 200 generic failure (live, all viewports, open `/publishers/00000000-0000-4000-8000-000000000000/`) → preserve the stable publisher ID and render the requested public profile.
- **[major]** An unknown publisher is indistinguishable from an outage: the user gets “The registry could not load this page.” rather than a not-found response (live, open an unused UUID) → return a real 404 with “Publisher not found,” a Packages link and related recovery options.
- **[minor]** Profiles inherit the generic “Package · Osprey Packages” title rather than a publisher name or even “Publisher” (live, inspect the title after following a publisher URL) → use the public display name in the title when found and “Publisher not found” otherwise.

## Live By tag directory — `/tags/`

- **[critical]** `/tags/` responds `308 Location: /package`, so both the home chip and mobile menu lead to an HTTP 200 error instead of a tag directory (live, all viewports, click “By tag”) → preserve `/tags/` and render available tags or the intended empty state.
- **[major]** The resulting page has no “Tags” heading, no tags, no explanation of the five-package threshold and no retry/recovery control (live `/tags/`, all viewports) → provide a labelled directory and a truthful empty/populated state with recovery navigation.
- **[minor]** The tag directory is titled “Package · Osprey Packages” in the browser (live `/tags/`) → use “Tags · Osprey Packages.”
- **[nit]** Its loading message is the generic “Loading packages…” (live `/tags/`, delay the API request) → say “Loading tags….”
- **[minor]** `/tags` without a trailing slash returns 404 instead of canonicalizing to `/tags/` (live, request `/tags`) → match the redirect behaviour used by the guide routes.

## Live tag pages — `/tags/{tag}/`

- **[critical]** Tag URLs redirect to `/package` and discard the tag, making tag bookmarks and shared links unusable (live, all viewports, open `/tags/not-a-real-tag/` or `/tags/networking/`) → preserve the tag path and render its package results.
- **[major]** An unknown tag produces a generic HTTP 200 load failure rather than “Tag not found” (live, open `/tags/not-a-real-tag/`) → return a truthful 404 and link back to the tag directory and catalog.
- **[minor]** Tag pages also use “Package · Osprey Packages,” so history and bookmarks cannot distinguish one tag from another (live, inspect the title) → include the escaped tag name in the page title.

## Package guide — `/guide/`

- **[major]** The guide teaches visitors to run a local folder registry from a source checkout, not how to consume packages from the registry they are visiting (live and mirror, all viewports) → lead with the hosted registry URL and normal installed-client workflow; move maintainer-only local setup to a separate advanced section.
- **[minor]** The VS Code instructions assume the extension and a configured local registry but provide no extension/install link or setup explanation (first section) → link the extension and state the prerequisites before naming the command.
- **[minor]** “The local registry shows audit unverified” is unexplained, lower-case jargon that makes adding a package sound unsafe without describing any consequence (first section) → quote the exact status and explain its risk and how to obtain verified evidence.
- **[minor]** “Inspect its release” gives no inspection criteria (first section) → tell users to check the version, digest, license, warnings and audit/provenance evidence before adding it.
- **[major]** At 390px the command block is 363px wide but its content is 944px wide, so most flags and command tails are invisible without horizontal scrolling (Package guide, 390×844) → wrap or restructure commands into readable mobile lines without changing their meaning.
- **[nit]** Neither guide provides a copy control; on mobile the user must select text inside a clipped horizontal scroller (both guides, 390×844) → provide an accessible Copy command button with confirmation.
- **[minor]** Desktop prose spans the full 1216px content width, producing roughly 120-character lines that are difficult to scan (Package guide, 1440×900) → constrain reading measure to approximately 65–80 characters.
- **[minor]** The guide requires an `osprey-packages` checkout, Make and `./target/osprey-pkg` but lists no prerequisites and gives no repository or installation link (command-line section) → provide a complete setup path for someone who does not already have a built source tree.
- **[minor]** Only POSIX shell syntax is supplied; there is no PowerShell/cmd alternative for Windows users (command-line section) → provide platform tabs or clearly labelled per-platform commands.
- **[minor]** The page ends after command definitions, with no expected output, failure troubleshooting, next step or link to fuller package-manager documentation (end of guide) → add verification output, common failures and a clear continuation.
- **[nit]** There is no meta description or Open Graph summary; only charset and viewport metadata are present (inspect `/guide/` source) → provide a concise package-guide summary for search results and shared links.

## Publishing guide — `/publishing/`

- **[major]** The primary instructions are for a local folder registry, while the hosted section merely says “Hosted publishing is in development”; a visitor leaves without any way to publish here (live and mirror, all viewports) → put the actual hosted workflow first or clearly mark the site read-only and link to the supported alternative.
- **[major]** The text says to set `$registry` and `$project`, but the example never defines either variable, so its sole command is not runnable as written (first section) → include concrete, clearly labelled assignments and a complete working example.
- **[major]** The guide demands “publication metadata” without a manifest example or reference, then says to restart a server it never explains how to start (first section) → show the required manifest and the full start/publish/restart sequence or link to exact documentation.
- **[major]** “Hosted publishing is in development” directly contradicts the persistent global “Upload a package” CTA, which implies hosted publication is available (all pages) → make availability copy and CTA behaviour agree before sending users into the flow.
- **[major]** At 390px the command block is 363px wide but needs 743px, clipping roughly half the only publish command with no visible scroll cue (Publishing guide, 390×844) → use mobile-safe line continuation or wrapping and a copy control.
- **[minor]** The hosted section says publishers sign with “their own credential” but never identifies the credential, setup, signing step or relationship to passkeys/GitHub (second section) → explain the concrete credential journey and link to account/signing help.
- **[minor]** Setup copy is inconsistent: Publishing says “From the Osprey checkout,” while Package guide says “From the osprey-packages checkout” (compare the two introductions) → name the correct repository consistently and link to it.
- **[minor]** The guide ends with attribution trivia rather than an actionable publishing next step, and does not cross-link the Package guide or package-manager docs (end of page) → end with the next supported action and relevant documentation links.
- **[nit]** Like Package guide, the page has no description or social metadata (inspect `/publishing/` source) → add a summary that also sets expectations about hosted availability.

## 404 page

- **[minor]** The “Browse packages” recovery link is only 18px high, making the sole in-content recovery action unnecessarily hard to hit (live and mirror 404, all viewports; especially 390×844) → give it at least a 44px-high target and button-like prominence.
- **[minor]** Recovery is limited to Browse packages: there is no search, publisher/tag navigation, missing-URL context or support link (open `/definitely-not-a-page/`) → provide search and useful recovery routes, particularly when a directory/profile link fails.
- **[nit]** On a 390×844 viewport the footer ends around the middle of the screen and leaves a large blank region below it (open any unknown URL) → use a full-height layout that anchors the footer to the bottom on short pages.
- **[nit]** The 404 has no meta description (inspect the response head) → add concise not-found metadata and prevent indexing with an appropriate robots policy.

## Header and navigation on every page

- **[major]** At 1440×900 and 1024×768 the primary navigation hides Browse packages, By publisher and By tag despite abundant space; only Upload a package is exposed (inspect every tested page) → show the complete directory navigation on desktop/tablet instead of forcing users through the home chips.
- **[minor]** The header brand link is only 36px high on desktop and 28px on mobile (all pages) → enlarge its interactive box to at least 44px high without changing the visual logo size.
- **[minor]** The mobile menu does not close on Escape or an outside click; it remains over page content until Menu is clicked again or navigation occurs (390×844, open Menu, press Escape or tap outside) → support standard disclosure dismissal and restore focus to the trigger on Escape.
- **[nit]** No navigation link has `aria-current` or a visible current-page state, including Upload and mobile Browse packages (inspect header links on their own pages) → expose the current location visually and programmatically.
- **[minor]** With JavaScript disabled, redirected directory/profile/tag pages leave “Loading packages…” on screen indefinitely and include no `<noscript>` explanation (disable JavaScript and open `/publishers/`) → render a usable fallback or explicitly explain the requirement with navigation that does not depend on the renderer.

## Footer on every page

- **[minor]** The sentence “A package registry for the Osprey language” unexpectedly links to the Osprey language homepage rather than registry information (click the footer on any page) → label the external destination explicitly or link the registry phrase to an actual registry/about page.
- **[minor]** The footer contains only that one external link; it provides no publisher, tag, Package guide, Publishing guide, support or canonical-live navigation (all pages, both hosts) → add a useful footer directory and recovery links.
- **[nit]** Footer copy renders at approximately 13.3px, making already unhelpful navigation copy even less readable (computed style at all viewports) → use the normal body size or at least a clearly readable small-text size.

## Cross-page availability, errors and presentation

- **[major]** Neither Package guide nor Publishing guide is linked from the home page, desktop header, mobile menu, footer or Upload page; both are orphan URLs (crawl every link reachable from home) → expose both guides in persistent Publish/Packages navigation and at relevant decision points.
- **[minor]** Every live page load attempts Cloudflare Insights and violates `script-src 'self' 'wasm-unsafe-eval'`, producing a console error and failed request (all tested live pages/viewports) → align analytics with the CSP or stop injecting the blocked script.
- **[nit]** Guide and directory-error heroes retain a roughly 296px-tall dark panel on mobile even when there is only one heading or sentence; the decorative image is reduced to a thin strip (390×844) → size the hero to its content and use a deliberate responsive composition.

## Mirror By publisher directory — `/osprey-packages/publishers/`

- **[major]** The mirror home and mobile menu link to this directory, but it returns the actual 404 page at all three viewports (mirror, click “By publisher”) → publish the directory route or remove the false affordance and offer the canonical live directory.
- **[minor]** The resulting 404 offers no canonical-live equivalent, so users who followed a mirror-specific directory link cannot continue the same task (mirror `/publishers/`) → link directly to the corresponding live publisher directory when local rendering is unavailable.

## Mirror By tag directory — `/osprey-packages/tags/`

- **[major]** The advertised tag directory returns 404 at 1440, 1024 and 390px (mirror, click “By tag”) → provide the same tag directory as the live site or a clear canonical-live fallback.

## Mirror publisher profiles — `/osprey-packages/publishers/{publisherId}/`

- **[major]** Publisher profile paths are not served by the mirror renderer; tested UUID paths return the generic 404 document (mirror, open `/publishers/11111111-1111-4111-8111-111111111111/`) → support stable profile deep links or redirect each one to its canonical live equivalent.

## Mirror tag pages — `/osprey-packages/tags/{tag}/`

- **[major]** Tag deep links are absent from the mirror; for example `/tags/networking/` returns 404 (mirror, direct navigation) → preserve tag routes and package results or redirect to the matching live tag page.

## Mirror guides and 404

- **[major]** The mirror ships the same local-checkout-only Package and Publishing guides while its own directory routes are 404, leaving no end-to-end registry journey (mirror, follow all visible navigation and read both guides) → keep mirror content and route capability in parity or clearly direct users to the canonical registry.
- **[minor]** Mirror 404 navigation recovers only to the same mirror home whose directory links are broken, creating a loop back into failure (mirror, open an unknown URL, click Browse packages, then either directory chip) → include a working canonical-live recovery option.
