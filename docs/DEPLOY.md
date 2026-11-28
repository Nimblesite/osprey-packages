# Deploy: what I need from you

Stack: Cloudflare → Cloud Run → Supabase (`[PACKAGE-HOSTED-TOPOLOGY]`). I run the rest with `make deploy`.

The domain is `nimblesite.ai` (already on Cloudflare); `ospreylang.dev` is still on GoDaddy DNS. Everything else is created or looked up by `make deploy`: the GCP project, billing link, A$50 budget, Cloudflare IDs, the Supabase token from your `supabase login`, and CI's Pages token.

1. Cloudflare → My Profile → API Tokens → Create → Custom token **"osprey-registry-terraform"**. Permissions: Account › Workers Scripts › Edit, Account › Cloudflare Pages › Edit, Account › Account API Tokens › Edit, Zone › DNS › Edit, Zone › Workers Routes › Edit, Zone › Zone › Read. Resources: your account and the `nimblesite.ai` zone. Paste it as `CLOUDFLARE_API_TOKEN=` in `src/manager/ops/deploy.env`.
2. Merge PR #1 (`deslop-cleanup`) to `main`: the deploy workflow runs from `main`, and agents never merge.
3. GitHub sign-in (no API exists for this): GitHub → Settings → Developer settings → OAuth Apps → New, once per environment. Homepage `https://packages-staging.nimblesite.ai` (production: `https://packages.nimblesite.ai`); callback is the URL `make deploy` prints. Paste the ID and secret into `GITHUB_OAUTH_CLIENT_{ID,SECRET}_{STAGING,PRODUCTION}` in `deploy.env`.

I run `make deploy ENV=staging`, then `ENV=production`. It is done when the run ends with `smoke done`.

## Hostnames

| | staging | production |
| --- | --- | --- |
| Website | `packages-staging.<DOMAIN>` | `packages.<DOMAIN>` |
| API | `packages-api-staging.<DOMAIN>` | `packages-api.<DOMAIN>` |
| Source downloads | `packages-content-staging.<DOMAIN>` | `packages-content.<DOMAIN>` |

The names are single-label on purpose: Cloudflare's free certificate covers `*.<DOMAIN>`, not `*.packages.<DOMAIN>`. The website and the API share `<DOMAIN>`, so the login cookie stays same-site. Free `*.workers.dev` / `*.pages.dev` hostnames would break sign-in.

## Cost

- Cloudflare: US$0.
- Cloud Run: 1 vCPU / 512 MiB, billed only while serving, scales to zero, at most 2 instances: about US$0–5/month.
- Supabase: always the smallest (Micro) compute, about US$10/month per project on the paid org. Keep the org's spend cap on.
- Domain: US$0 (`nimblesite.ai`, already owned).
- One project-wide GCP budget alert at A$50/month (50/90/100%), created by every `make deploy` before anything else.

## Later

- Ship code: `make deploy ENV=<env> STEP=release`, or Actions → Deploy.
- Schema change: `STEP=database`.
- Details: [src/manager/ops/README.md](../src/manager/ops/README.md).
