# AGENTS.md 📦

**Osprey package manager:** `osprey-pkg` client, registry API (local folder registry + hosted Cloud Run on Supabase), registry website, VS Code package workspace. 🌐 <https://nimblesite.github.io/osprey-packages/>

- 🗄️ Backend = Osprey + Supabase, ❌ Rust. APIs beside Supabase go on GCP
- 🧱 DB migrations = [DataProvider Migrations](https://dataprovider.tech/docs/migrations/) (`src/manager/ops/supabase/migrations/schema.yaml`); ❌ SQL, DDL: SQL is illegal in this repo
- 🗃️ Data access = stored procedures + functions, declared in `schema.yaml` `functions:` and called by the API. DataProvider is ONLY the migration tool: ❌ DataProvider or LQL for querying data, ❌ ad-hoc query text in application code
- 🔐 Package integrity is the product: hashes, locks and trust checks never fail open
- 🧠 One memory strategy per app, never a matrix: client = GC, folder + hosted API = ARC, WASM (editor, website) = ARC. `CLI_MEMORY` / `API_MEMORY` / `WASM_MEMORY` in `Makefile`
- 🧪 `make ci` = every suite once under its app's strategy, then the website check

## 🐦 Osprey
- 🛠️ Compiler: use what's installed. 1️⃣ the VS Code extension's bundled one (`~/.vscode/extensions/nimblesite.osprey-<version>-<platform>/bin/<platform>/osprey`), 2️⃣ `brew install nimblesite/tap/osprey` (macOS/Linux) or `scoop install osprey` (Windows, [bucket](https://github.com/Nimblesite/scoop-bucket)). ❌ build ospreylang just to run a program. [Install](https://www.ospreylang.dev/docs/installation/)
- 📖 Learn it: [docs](https://www.ospreylang.dev/docs/) · [first app](https://www.ospreylang.dev/docs/my-first-app/) · [types](https://www.ospreylang.dev/docs/types/) · [functions](https://www.ospreylang.dev/docs/functions/) · [operators](https://www.ospreylang.dev/docs/operators/) · [keywords](https://www.ospreylang.dev/docs/keywords/) · [stdlib](https://www.ospreylang.dev/docs/stdlib/)
- ⚡ Effects = how Osprey does I/O and testing: [effects](https://www.ospreylang.dev/docs/effects/)
- ✅ Proofs + bug hunting: [formal verification](https://www.ospreylang.dev/docs/proofs/formal-verification/) · [hunt](https://www.ospreylang.dev/docs/hunt/)
- 🤖 For agents: [Python flavor for AI](https://www.ospreylang.dev/docs/python/for-ai/) · 📜 [language spec](https://www.ospreylang.dev/spec/) · 🏷️ [releases](https://www.ospreylang.dev/docs/releases/)
- 📦 Here: [package manager](https://www.ospreylang.dev/docs/package-manager/) · [`@osprey/json`](https://www.ospreylang.dev/docs/packages/json/)

## 🏗️ Toolchain
- 📦 `make _toolchain` lays the released Osprey at the tag pinned in `scripts/osprey-toolchain.sh` into `target/osprey` (compiler, runtime archives, published `@osprey` packages), SHA-256 pinned there. ❌ ospreylang checkouts in this repo
- 🎯 `make help` first. Entry points = commented make targets in `Makefile`
- 📌 Need a newer compiler → bump the tag in `scripts/osprey-toolchain.sh` to a released one and pin its digests. ❌ Edit ospreylang files from here
- 🧾 Specs + plans live in `docs/`; cite their IDs (`// Implements [GROUP-TOPIC]`). Language specs stay in ospreylang

## 🔒 Safety
- 1️⃣ Memory safety + security first. 0️⃣ tolerance. Attack first
- 🛑 Osprey never panics, aborts or exits: every failure is `Result` or a handled effect. ❌ fake zero/empty values
- 🟥 Red = fail: every tracked program compiles
- ✅ Can be [formally verified](https://www.ospreylang.dev/docs/proofs/formal-verification/) → MUST be. Every program entry runs [`osprey hunt`](https://www.ospreylang.dev/docs/hunt/) in CI (`make _hunt`)

## 🧪 Tests
- ✅ E2E use-case tests: many inputs, many interactions, many assertions. Unit tests only when isolation is needed
- 🧪 Test before fix. ❌ weaken, skip or delete a red test
- 💯 coverage aim; `scripts/coverage-thresholds.json` only goes ⬆️
- 🚦 CI = 3 phases, each once: build + check → tests with coverage → coverage gate. ❌ weaken gates, `if:` or timeouts

## ✍️ Code
- 🐛 Duplication + dead code = bugs. Run [deslop](https://deslop.live/docs/for-ai/)
- 📏 Files < 500 LOC, functions < 20 LOC. Pure functions, immutable types, expressions over statements
- 🧹 Osprey: drop every inferable type annotation (Hindley-Milner)
- 📦 Minimize deps. 🚫📦 No build output in git: generate, gitignore, ship as CI artifacts
- 🗺️ Data models in [typeDiagram](https://typediagram.dev/docs/language-reference.html); mermaid, ❌ ASCII art

## 🤝 Workflow
- ❌ subagents, linked worktrees, git hooks. One checkout
- ⏱️ Heavy CPU runs: `nice` + strict timeouts
- 🤖 Legwork → pi: ONLY `zai/glm-5.4` or `kimi-coding/k3.1-pro`
- 🙅 Never commit as co-author. Never merge PRs
- 🚀 Deploys run from `main` only: `deploy.sh` and the deploy workflows fail on any other branch, an unmerged commit or a dirty tree. ❌ Deploy a feature branch
