# Deploy: what I need from you

Stack: Cloudflare → Cloud Run → Supabase (`[PACKAGE-HOSTED-TOPOLOGY]`). I run the rest with `make deploy`.

The domain is `ospreylang.dev`. I added it to Cloudflare as a zone and copied its 8 existing DNS records unchanged (DNS-only), so the Osprey site and `api.ospreylang.dev` keep working. Everything else is created or looked up by `make deploy`: the GCP project, billing link, A$50 budget, Cloudflare IDs, the Supabase token from your `supabase login`, and CI's Pages token.

Five things only you can do. The first puts the site on the internet; the next two decide whether the API survives a launch crowd:

1. **Point `ospreylang.dev` at Cloudflare.** GoDaddy → My Products → `ospreylang.dev` → DNS → Nameservers → Change → "I'll use my own nameservers": `isaac.ns.cloudflare.com` and `ivy.ns.cloudflare.com`. Nothing at `packages.ospreylang.dev` resolves until this is done; I have no GoDaddy login.
2. **Buy Workers Paid (US$5/month).** Cloudflare dashboard → Workers & Pages → Plans → Workers Paid. The account is on Workers Free, which stops the API Worker after 100,000 requests a day, account-wide. A purchase needs your card, so I cannot do it.
3. **Set the launch budget.** Tell me a monthly A$ figure. Today the hard cap is A$50 and Cloud Run is 1 instance × 16 concurrent requests; more requests than that get a 429. One busy instance costs about A$100/month, so under sustained load the A$50 cap unlinks billing and the API goes down until relinked. For a launch crowd I recommend A$300 and 10 instances (160 concurrent requests). The website itself is static on Cloudflare Pages and has no such limit.
4. **GitHub sign-in** (no API exists for this): GitHub → Settings → Developer settings → OAuth Apps → New. Homepage `https://packages.ospreylang.dev`; callback `https://adhpkrcgqgwwpbaplcfs.supabase.co/auth/v1/callback`. Paste the ID and secret into `GITHUB_OAUTH_CLIENT_ID_PRODUCTION` / `GITHUB_OAUTH_CLIENT_SECRET_PRODUCTION` in `src/manager/ops/deploy.env`. Until then the site is live but signed-out only.
5. **Merge PR #1** (`deslop-cleanup`) to `main` once CI is green: the deploy workflow runs from `main`, and agents never merge. Production does not wait for this; I deploy from this machine.

I run `make deploy STEP=local`. It is done when the run ends with `local done`.

Production is the only environment. A test environment, when one exists, is an exact copy of production (Prod → Dev), never built from scratch. Test environments are paused.

## Hostnames

| | production |
| --- | --- |
| Website | `packages.<DOMAIN>` |
| API | `packages-api.<DOMAIN>` |
| Source downloads | `packages-content.<DOMAIN>` |

The names are single-label on purpose: Cloudflare's free certificate covers `*.<DOMAIN>`, not `*.packages.<DOMAIN>`. The website and the API share `<DOMAIN>`, so the login cookie stays same-site. Free `*.workers.dev` / `*.pages.dev` hostnames would break sign-in.

## Cost

- Cloudflare: US$0.
- Cloud Run: 1 vCPU / 512 MiB, billed only while serving, scales to zero, at most 1 instance: about A$0–5/month.
- Supabase: always the smallest (Micro) compute, about US$10/month per project on the paid org. Keep the org's spend cap on.
- Domain: US$0 (`ospreylang.dev`, already owned).
- Hard cap: one project-wide A$50/month budget, created by every `make deploy` before anything else. It emails at 50/90/100%, and at 100% a Cloud Workflow unlinks billing from the project, which stops all GCP spend. Tested: a cost-equals-budget notification unlinked billing within two minutes. Recover with `gcloud billing projects link osprey-registry --billing-account=<ID>`.
- Supabase is billed separately: Micro compute is a fixed ~US$10/month per project, and the org's spend cap (on by default for Pro) blocks overages.

## Later

- Ship code: `make deploy STEP=release`, or Actions → Deploy.
- Schema change: `STEP=database`.
- Details: [src/manager/ops/README.md](../src/manager/ops/README.md).

## Publication scan worker

The image includes the one-shot command `/usr/local/bin/registry-scan-once` for a separately provisioned worker identity [PACKAGE-SECURITY-SCAN-VERDICT]. The API listener starts by default. The worker claims one pending submission or accepts its UUID as an argument. Mount the scanner’s PostgreSQL service file at `/run/registry-scan/pg_service.conf`, its PostgreSQL root CA at `/run/catalog-ca/ca.pem`, its pinned NAP configuration (`configId`, `agentRevision`, `apiKey`) at `/run/registry-scan/agent.json`, and immutable canonical bundles read-only at `/run/registry-quarantine/<sha256 hex>.json`. A missing mount, invalid digest or agent failure leaves the submission pending. A successful empty-queue run performs no remote scan. Hosted activation depends on provisioning the tool-free agent and the signed-intent collector.
