# Deploy: what I need from you

Stack: Cloudflare → Cloud Run → Supabase (`[PACKAGE-HOSTED-TOPOLOGY]`). Everything else is scripted: `make deploy ENV=staging`.

## 1. Accounts (one time)

| # | Do this | Put in `src/manager/ops/deploy.env` |
| --- | --- | --- |
| 1 | `gcloud auth login && gcloud auth application-default login` | – |
| 2 | `gcloud projects create osprey-registry` (or pick an existing one), then `gcloud billing projects link osprey-registry --billing-account=<ID>` | `GCP_PROJECT_ID`, `GCP_BILLING_ACCOUNT` (`gcloud billing accounts list`) |
| 3 | Cloudflare → Add site `ospreylang.dev` (Free). Check that the imported GitHub Pages records are **DNS only** (grey). At GoDaddy, switch the nameservers to the two Cloudflare gives you. | `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_ZONE_ID` (zone Overview page) |
| 4 | Cloudflare → My Profile → API Tokens → Custom token **"osprey-registry-terraform"**: Account › Workers Scripts › Edit, Account › Cloudflare Pages › Edit, Zone › DNS › Edit, Zone › Workers Routes › Edit, Zone › Zone Settings › Edit, Zone › Zone WAF › Edit, Zone › Zone › Read. Resources: your account plus zone `ospreylang.dev` only. | `CLOUDFLARE_API_TOKEN` |
| 5 | Second custom token, **"osprey-registry-pages"**: Account › Cloudflare Pages › Edit only. CI uses it. | `CLOUDFLARE_PAGES_TOKEN` |
| 6 | Supabase → Account → Access Tokens → Generate. Then run `supabase orgs list`. | `SUPABASE_ACCESS_TOKEN`, `SUPABASE_ORG_ID` (the org's slug) |
| 7 | `gh auth status` must show admin on `Nimblesite/osprey-packages` | – |

`cp src/manager/ops/deploy.env.example src/manager/ops/deploy.env` and fill it in. The file is gitignored.

## 2. Pull the trigger

1. Merge branch `deslop-cleanup` (PR #1) to `main`. The deploy workflow must exist on `main`.
2. `make deploy ENV=staging` takes about 30 minutes and is safe to re-run. It creates the Supabase project, the infrastructure and the first CI image, then migrates, releases and smoke-tests.
3. The run prints a GitHub OAuth callback URL. GitHub → Settings → Developer settings → OAuth Apps → New:
   - Homepage `https://packages-staging.ospreylang.dev`
   - Callback: the printed URL
   - Put the ID and secret in `GITHUB_OAUTH_CLIENT_ID_STAGING` / `GITHUB_OAUTH_CLIENT_SECRET_STAGING`
   - Run `make deploy ENV=staging STEP=supabase`
4. Production: repeat steps 2–3 with `ENV=production` and the `_PRODUCTION` OAuth app (homepage `https://packages.ospreylang.dev`).

Done when the last line reads `smoke done`: the edge answers, a direct `run.app` request gets 403 and the website returns 200.

## Hostnames

| | staging | production |
| --- | --- | --- |
| Website | `packages-staging.ospreylang.dev` | `packages.ospreylang.dev` |
| API | `packages-api-staging.ospreylang.dev` | `packages-api.ospreylang.dev` |
| Source downloads | `packages-content-staging.ospreylang.dev` | `packages-content.ospreylang.dev` |

## Cost

- Cloudflare: US$0.
- Cloud Run: scales to zero, at most 2 instances, about US$0–5/month.
- Supabase: US$0 on a free org slot, or about US$10/month per project on a paid org.
- Budget alert at US$25 (50/90/100%).

## Later

- Ship code: `make deploy ENV=<env> STEP=release`, or Actions → Deploy.
- Schema change: `STEP=database`.
- Details: [src/manager/ops/README.md](../src/manager/ops/README.md).
