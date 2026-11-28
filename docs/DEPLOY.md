# Deploy: what the owner does

Agents do everything else. Production is the only environment. Deploys run from `main` only.

## Do now

- [x] **Nameservers.** GoDaddy → `ospreylang.dev` → Nameservers → `isaac.ns.cloudflare.com`, `ivy.ns.cloudflare.com`. Done 2026-11-28.
- [ ] **Workers Paid (US$5/month).** Cloudflare → Workers & Pages → Plans. Workers Free stops the API after 100,000 requests a day.
- [ ] **Launch budget.** Give a monthly A$ figure. Today: A$50 cap, 1 instance, 16 concurrent requests. Recommended for launch: A$300, 10 instances.
- [ ] **GitHub sign-in.** GitHub → Settings → Developer settings → OAuth Apps → New.
  - Homepage: `https://packages.ospreylang.dev`
  - Callback: `https://adhpkrcgqgwwpbaplcfs.supabase.co/auth/v1/callback`
  - Paste the ID and secret into `GITHUB_OAUTH_CLIENT_ID_PRODUCTION` and `GITHUB_OAUTH_CLIENT_SECRET_PRODUCTION` in `src/manager/ops/deploy.env`.

## Do when CI is green

- [ ] **Merge PR #1** (`deslop-cleanup`) to `main`. Agents never merge. Nothing reaches production until this is merged.

## Then agents release

- On a clean checkout of `main`: `make deploy STEP=release`, or Actions → Deploy.
- Schema change: `make deploy STEP=database`.
- Any other branch, an unmerged commit or a dirty tree fails. CI proves it (`scripts/packages/test-deploy-main-only.sh`).
- Details: [src/manager/ops/README.md](../src/manager/ops/README.md).

## Hostnames

| | |
| --- | --- |
| Website | `packages.ospreylang.dev` |
| Redirect to the website | `package.ospreylang.dev` |
| API | `packages-api.ospreylang.dev` |
| Source downloads | `packages-content.ospreylang.dev` |

## Cost

- Cloudflare: US$0 (US$5/month with Workers Paid).
- Cloud Run: about A$0–5/month at 1 instance, scales to zero.
- Supabase: about US$10/month, spend cap on.
- Hard cap: A$50/month on the GCP project. At 100% billing is unlinked and the API stops. Relink: `gcloud billing projects link osprey-registry --billing-account=<ID>`.
