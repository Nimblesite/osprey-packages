# Deploy: owner steps

- [x] GoDaddy nameservers → `isaac.ns.cloudflare.com`, `ivy.ns.cloudflare.com`
- [ ] Give a monthly A$ budget (now A$50; launch: A$300)
- [ ] GitHub → Settings → Developer settings → OAuth Apps → New
  - Homepage: `https://packages.ospreylang.dev`
  - Callback: `https://adhpkrcgqgwwpbaplcfs.supabase.co/auth/v1/callback`
  - ID and secret → `src/manager/ops/deploy.env`
- [ ] Merge PR #1 to `main` when CI is green

Cloudflare stays on the free plan: no card, no usage billing.

Deploys run from `main` only: `make deploy STEP=release`. Details: [ops README](../src/manager/ops/README.md).
