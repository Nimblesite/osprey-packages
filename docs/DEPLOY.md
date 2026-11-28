# Deploy: what I need from you

Stack: Cloudflare → Cloud Run → Supabase (`[PACKAGE-HOSTED-TOPOLOGY]`). Everything else is scripted: `make deploy ENV=staging`.

## Pick the domain (one decision)

The zone must be on Cloudflare: the Worker, the rate limit and Pages all live there. Every hostname comes from `DOMAIN` in `deploy.env`. Pick a name you will keep, because installed packages and lockfiles point at the API URL.

| | Option A: `ospreylang.dev` | Option B: `nimblesite.ai` |
| --- | --- | --- |
| URLs | `packages.ospreylang.dev` | `packages.nimblesite.ai` |
| Brand | Osprey's own | Nimblesite's |
| Work | Move the DNS (below), about 15 minutes plus up to 24 hours waiting | None: the zone is already on Cloudflare (NAP uses it) |
| Set | `DOMAIN=ospreylang.dev` | `DOMAIN=nimblesite.ai` |

### Option A: move `ospreylang.dev` DNS from GoDaddy to Cloudflare

Only the DNS moves. The domain stays registered and paid at GoDaddy.

1. Cloudflare → Add a domain → `ospreylang.dev` → Free plan. Cloudflare copies the existing records: four GitHub Pages `A` records and the `www` CNAME.
2. Set every copied record to **DNS only** (grey cloud), so the GitHub Pages docs site keeps its own certificate and keeps working.
3. GoDaddy → My Products → `ospreylang.dev` → DNS → Nameservers → Change → "I'll use my own nameservers" → paste the two Cloudflare nameservers → Save.
4. Wait for Cloudflare's "zone active" email, usually within an hour and at most 24 hours. The docs site stays up throughout because the records are identical.
5. Rollback: put GoDaddy's nameservers back.

## Accounts (one time)

| # | Do this | Put in `src/manager/ops/deploy.env` |
| --- | --- | --- |
| 1 | `gcloud auth login && gcloud auth application-default login` | – |
| 2 | `gcloud projects create osprey-registry` (or pick an existing one), then `gcloud billing projects link osprey-registry --billing-account=<ID>` | `GCP_PROJECT_ID`, `GCP_BILLING_ACCOUNT` (`gcloud billing accounts list`) |
| 3 | Cloudflare → your `DOMAIN` zone → Overview, right-hand column | `DOMAIN`, `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_ZONE_ID` |
| 4 | Cloudflare → My Profile → API Tokens → Custom token **"osprey-registry-terraform"**: Account › Workers Scripts › Edit, Account › Cloudflare Pages › Edit, Zone › DNS › Edit, Zone › Workers Routes › Edit, Zone › Zone Settings › Edit, Zone › Zone WAF › Edit, Zone › Zone › Read. Resources: your account plus the `DOMAIN` zone only. | `CLOUDFLARE_API_TOKEN` |
| 5 | Second custom token, **"osprey-registry-pages"**: Account › Cloudflare Pages › Edit only. CI uses it. | `CLOUDFLARE_PAGES_TOKEN` |
| 6 | Supabase → Account → Access Tokens → Generate. Then run `supabase orgs list`. | `SUPABASE_ACCESS_TOKEN`, `SUPABASE_ORG_ID` (the org's slug) |
| 7 | `gh auth status` must show admin on `Nimblesite/osprey-packages` | – |

`cp src/manager/ops/deploy.env.example src/manager/ops/deploy.env` and fill it in. The file is gitignored.

Option B only: the free plan allows one rate-limit rule per zone, and NAP's `nap-rate-all` rule already holds that slot.

1. Set `RATE_LIMIT_EXTRA_HOSTS=api.nimblesite.ai` so the registry rule keeps protecting NAP.
2. Before the production deploy, delete `nap-rate-all` under Cloudflare → `nimblesite.ai` → Security → WAF → Rate limiting rules.

Staging never touches the rule. The zone-wide minimum TLS 1.2 is harmless for NAP.

## Pull the trigger

1. Merge branch `deslop-cleanup` (PR #1) to `main`. The deploy workflow must exist on `main`.
2. `make deploy ENV=staging` takes about 30 minutes and is safe to re-run. It creates the Supabase project, the infrastructure and the first CI image, then migrates, releases and smoke-tests.
3. The run prints a GitHub OAuth callback URL. GitHub → Settings → Developer settings → OAuth Apps → New:
   - Homepage `https://packages-staging.<DOMAIN>`
   - Callback: the printed URL
   - Put the ID and secret in `GITHUB_OAUTH_CLIENT_ID_STAGING` / `GITHUB_OAUTH_CLIENT_SECRET_STAGING`
   - Run `make deploy ENV=staging STEP=supabase`
4. Production: repeat steps 2–3 with `ENV=production` and the `_PRODUCTION` OAuth app (homepage `https://packages.<DOMAIN>`).

Done when the last line reads `smoke done`: the edge answers, a direct `run.app` request gets 403 and the website returns 200.

## Hostnames

| | staging | production |
| --- | --- | --- |
| Website | `packages-staging.<DOMAIN>` | `packages.<DOMAIN>` |
| API | `packages-api-staging.<DOMAIN>` | `packages-api.<DOMAIN>` |
| Source downloads | `packages-content-staging.<DOMAIN>` | `packages-content.<DOMAIN>` |

The names are single-label on purpose: Cloudflare's free certificate covers `*.<DOMAIN>`, not `*.packages.<DOMAIN>`. The website and the API share `<DOMAIN>`, so the login cookie stays same-site. Free `*.workers.dev` / `*.pages.dev` hostnames would break sign-in.

## Cost

- Cloudflare: US$0.
- Cloud Run: scales to zero, at most 2 instances, about US$0–5/month.
- Supabase: US$0 on a free org slot, or about US$10/month per project on a paid org.
- Domain: US$0, since both options use a domain you already own.
- Budget alert at US$25 (50/90/100%).

## Later

- Ship code: `make deploy ENV=<env> STEP=release`, or Actions → Deploy.
- Schema change: `STEP=database`.
- Details: [src/manager/ops/README.md](../src/manager/ops/README.md).
