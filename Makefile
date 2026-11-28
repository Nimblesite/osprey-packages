# The Osprey package manager [REPO-SPLIT]. It builds with the released Osprey toolchain pinned in
# scripts/osprey-toolchain.sh, laid into target/osprey: the compiler, its runtime archives and the
# published @osprey packages. No ospreylang checkout. `make help` lists the public targets; `_` ones are internal.
BIN ?= target/osprey/osprey
OSPREY = $(abspath $(BIN))
TOOLCHAIN = target/osprey/.release
MKDIR = mkdir -p

.PHONY: help _toolchain build ci
## help: List this repository's targets.
help:
	@grep -h -E '^## ' Makefile | sed 's/^## //'

# _toolchain: Lay the released Osprey toolchain pinned in scripts/osprey-toolchain.sh into target/osprey.
_toolchain $(TOOLCHAIN): scripts/osprey-toolchain.sh
	scripts/osprey-toolchain.sh

REGISTRY_CLIENT_SOURCES = $(shell find src/manager -type f \( -name '*.osp' -o -name '*.ospml' -o -name 'osprey.toml' \))
target/osprey-pkg: $(TOOLCHAIN) $(REGISTRY_CLIENT_SOURCES)
	$(OSPREY) build src/manager/cli --quiet --warnings-as-errors -o $@
target/osprey-registry: $(TOOLCHAIN) $(REGISTRY_CLIENT_SOURCES)
	$(OSPREY) build src/manager/api --quiet --warnings-as-errors -o $@
target/package-workspace.wasm: $(TOOLCHAIN) $(REGISTRY_CLIENT_SOURCES)
	$(OSPREY) build src/manager/editor --target=wasm32 --quiet --warnings-as-errors -o $@

## build: The package client, the folder-registry server and the editor WASM.
build: target/osprey-pkg target/osprey-registry target/package-workspace.wasm

## canary: What ospreylang's CI runs from this repository's main with its own compiler
##         (make canary BIN=<compiler>) [REPO-SPLIT-CANARY]: fixtures and schema, the package
##         frontend, and the consumer flow against sample-registry. Windows runs the frontend only:
##         the fixture and registry tree walks shell out to POSIX `find`.
.PHONY: canary
canary: export OSPREY_E2E_COMPILER = $(OSPREY)
canary: export OSPREY_E2E_MEMORY = gc
canary: $(TOOLCHAIN)
	$(if $(filter Windows_NT,$(OS)),,$(OSPREY) test src/manager/fixture-check)
	$(OSPREY) test src/manager/cli/tests
	$(if $(filter Windows_NT,$(OS)),@echo "canary: fixture-check and e2e not run on Windows: the package tree walk needs POSIX find",$(OSPREY) test src/manager/e2e)

## ci: Every check this host can run: each suite under GC and ARC with coverage, the hashing and
##     website checks, then the per-project coverage gate (scripts/coverage-thresholds.json).
ci: build _lint
	rm -rf target/coverage
	$(MAKE) _test_registry REGISTRY_MEMORY=gc REGISTRY_COVERAGE=target/coverage
	$(MAKE) _test_registry REGISTRY_MEMORY=arc REGISTRY_COVERAGE=target/coverage
	$(MAKE) _package-hashing
	$(MAKE) _registry-website-check
	$(MAKE) _hunt HUNT_MEMORY=gc
	$(MAKE) _hunt HUNT_MEMORY=arc
	node scripts/coverage.mjs . target/coverage/*.json

# _hunt: KLEE symbolic execution from every shipped program entry (the client, the folder registry and
#        the hosted API). Each crash it finds is replayed natively; a reproduced crash or a compile
#        failure exits 1. Reports land in target/hunt/<memory>-<program>.
HUNT_MEMORY ?= gc
HUNT_PROGRAMS = cli api api/hosted
.PHONY: _hunt
_hunt: $(TOOLCHAIN)
	set -e; for p in $(HUNT_PROGRAMS); do \
	  nice $(OSPREY) hunt src/manager/$$p --memory=$(HUNT_MEMORY) --max-time 120 --input-bytes 8 --quiet \
	    --out target/hunt/$(HUNT_MEMORY)-$$(echo $$p | tr / -); \
	done

# _lint: The analysis gate, phase 1: every project compiles with --warnings-as-errors, every source is
#        osprey-fmt clean, and duplication stays under .deslop.toml's threshold (scripts/deslop.sh).
LINT_PROJECTS = $(sort $(dir $(shell find src/manager -name osprey.toml -not -path '*/fixtures/*' -not -path '*/sample-registry/*' -not -path '*/e2e/consumer*')))
.PHONY: _lint
_lint: $(TOOLCHAIN)
	set -e; for p in $(LINT_PROJECTS); do [ -d $$p/src ] || continue; nice $(OSPREY) $$p --check --warnings-as-errors --quiet; done
	$(OSPREY) fmt --check src/manager
	nice scripts/deslop.sh

# _package-hashing: The package hash rotates machine words with no allocation (the emitted IR of
#                  bytes.osp, sha256.osp and policy.osp). Expect every unittest to pass.
.PHONY: _package-hashing
_package-hashing: $(TOOLCHAIN)
	OSPREY_COMPILER=$(OSPREY) python3 scripts/packages/test-package-sha256.py

# Osprey package system (src/manager/): one process runs every suite from the
# src/manager/tests project with core, host and CLI sources assembled together,
# because `osprey test` compiles suites in isolation and cannot import them.
# src/manager/fixture-check runs first and fails fast: every fixture is data,
# parses strictly, cites a defined spec section and is indexed, every typed
# fixture value is schema-valid and canonically ordered, and every registry
# source cites only defined sections. src/manager/manifest/tests is the TOML
# parser and manifest-rule suite, a separate program until that code joins
# core. src/manager/e2e runs last: it starts the
# server over src/manager/sample-registry on 127.0.0.1:18797, compares every
# endpoint with the pure router, fetches every release, and builds and runs a
# consumer project against the fetched sources. Local tests and CI run all
# suites under both managed backends; the TAP runner propagates failed checks.
REGISTRY_MEMORY ?= gc
# REGISTRY_COVERAGE=<dir> writes each suite's line coverage to <dir>/<memory>-<suite>.json, which
# scripts/coverage.mjs gates against scripts/coverage-thresholds.json.
REGISTRY_COVERAGE ?=
registry_coverage = $(if $(REGISTRY_COVERAGE),--coverage-json $(REGISTRY_COVERAGE)/$(REGISTRY_MEMORY)-$(1).json)
REGISTRY_NATIVE_CLIENT = $(CURDIR)/target/$(if $(filter arc,$(REGISTRY_MEMORY)),registry-tests/osprey-pkg-arc,osprey-pkg)
.PHONY: _test_registry
_test_registry: export OSPREY_E2E_COMPILER = $(OSPREY)
_test_registry: export OSPREY_E2E_MEMORY = $(REGISTRY_MEMORY)
_test_registry:
	@case "$(REGISTRY_MEMORY)" in gc|arc) ;; *) echo "Registry tests require GC or ARC"; exit 1 ;; esac
	$(if $(REGISTRY_COVERAGE),mkdir -p $(REGISTRY_COVERAGE))
	@echo "==> Registry fixture and schema validation (fail-fast)..."
	$(OSPREY) test src/manager/fixture-check --memory=$(REGISTRY_MEMORY) $(call registry_coverage,fixture-check)
	@echo "==> Registry manifest (TOML parser and manifest rules) tests..."
	$(OSPREY) test src/manager/manifest/tests --memory=$(REGISTRY_MEMORY) $(call registry_coverage,manifest-tests)
	@echo "==> Registry CLI (package frontend) tests..."
	$(OSPREY) test src/manager/cli/tests --memory=$(REGISTRY_MEMORY) $(call registry_coverage,cli-tests)
	@echo "==> Registry (Osprey package system) tests..."
	$(OSPREY) test src/manager/tests --memory=$(REGISTRY_MEMORY) $(call registry_coverage,tests)
	@echo "==> Registry end-to-end: server, fetch and consumer build..."
	$(OSPREY) test src/manager/e2e --memory=$(REGISTRY_MEMORY) $(call registry_coverage,e2e)
	$(OSPREY) test src/manager/auth-tests --memory=$(REGISTRY_MEMORY) $(call registry_coverage,auth-tests)
	$(OSPREY) test src/manager/database-tests --memory=$(REGISTRY_MEMORY) $(call registry_coverage,database-tests)
	$(OSPREY) test src/manager/governance-tests --memory=$(REGISTRY_MEMORY) $(call registry_coverage,governance-tests)
	$(OSPREY) test src/manager/hosted-tests --memory=$(REGISTRY_MEMORY) $(call registry_coverage,hosted-tests)
	$(OSPREY) test src/manager/web --memory=$(REGISTRY_MEMORY) $(call registry_coverage,web)
	$(OSPREY) test src/manager/editor/tests --memory=$(REGISTRY_MEMORY) $(call registry_coverage,editor-tests)
	$(OSPREY) test src/manager/editor/wire-tests --memory=$(REGISTRY_MEMORY) $(call registry_coverage,editor-wire-tests)
	@echo "==> Native publication and installed-source integrity regressions..."
	@if [ "$(REGISTRY_MEMORY)" = arc ] && [ -z "$$OSPREY_PACKAGE_CLIENT" ]; then \
	  mkdir -p "$(CURDIR)/target/registry-tests" && \
	  "$(OSPREY)" build src/manager/cli --memory=arc --quiet --warnings-as-errors -o "$(REGISTRY_NATIVE_CLIENT)"; \
	fi
	OSPREY_PACKAGE_CLIENT="$${OSPREY_PACKAGE_CLIENT:-$(REGISTRY_NATIVE_CLIENT)}" python3 scripts/packages/test-package-publication.py
	OSPREY_PACKAGE_CLIENT="$${OSPREY_PACKAGE_CLIENT:-$(REGISTRY_NATIVE_CLIENT)}" python3 scripts/packages/test-package-interruption.py

.PHONY: _registry-test registry-serve _registry-serve-sample _registry-blockers
# _registry-test: Run the Osprey package-system suites.
_registry-test: build
	$(MAKE) _test_registry

## registry-serve: Serve the released @osprey packages, published by this client into
##                 target/local-registry, over HTTP on 127.0.0.1:8787. Ctrl-C stops it.
target/local-registry.stamp: target/osprey-pkg scripts/packages/stage-local-registry.sh
	scripts/packages/stage-local-registry.sh target/osprey-pkg target/local-registry
	@touch $@
registry-serve: target/osprey-registry target/local-registry.stamp
	@$(MKDIR) target/local-registry-server
	@printf '{ "root": "%s", "address": "127.0.0.1", "port": 8787 }\n' "$(abspath target/local-registry)" \
	  > target/local-registry-server/registry-server.json
	cd target/local-registry-server && $(abspath target/osprey-registry)

# _registry-serve-sample: Serve src/manager/sample-registry (the @demo packages the e2e consumer
#                        uses) on 127.0.0.1:8787 (settings in src/manager/api/registry-server.json).
_registry-serve-sample: $(TOOLCHAIN)
	cd src/manager/api && $(OSPREY) . --run

# _registry-blockers: Probe the host capabilities the package-manager plan still needs (argv, exit status,
#                    binary-safe reads, ...). Expected to FAIL until each capability lands; never
#                    part of `test`. A probe turning green is the signal to delete its entry from
#                    src/manager/core/src/capabilities.osp.
_registry-blockers: $(TOOLCHAIN)
	@echo "==> Registry blocked-capability probes (expected red until each lands)..."
	$(OSPREY) src/manager/blockers --run

REGISTRY_WEB = src/manager/web
REGISTRY_TERRAFORM = src/manager/ops/terraform
REGISTRY_MIGRATOR_REV = 3b4e356522affc61b466d8e87ef5232319c9d7a0
REGISTRY_MIGRATOR_SHA256 = 87192312ca3a313fa0c786705c2fa2cbafebe76a0afb522b39df82f08aaa740a
REGISTRY_MIGRATOR_DIR = target/registry-tools/$(REGISTRY_MIGRATOR_REV)
REGISTRY_MIGRATOR = $(REGISTRY_MIGRATOR_DIR)/bin/DataProviderMigrate.dll

.PHONY: _registry-migration-tool _registry-migration-check
# _registry-migration-tool: Build the pinned private-schema DataProvider CLI under target/registry-tools.
_registry-migration-tool: $(REGISTRY_MIGRATOR)
	@echo "$(abspath $(REGISTRY_MIGRATOR))"

$(REGISTRY_MIGRATOR):
	@mkdir -p $(REGISTRY_MIGRATOR_DIR)
	@set -eu; scratch=$$(mktemp -d "$(REGISTRY_MIGRATOR_DIR)/build.XXXXXX"); \
	  trap 'rm -rf "$$scratch"' EXIT; \
	  curl -fsSL --retry 2 --max-time 120 "https://codeload.github.com/Nimblesite/DataProvider/tar.gz/$(REGISTRY_MIGRATOR_REV)" -o "$$scratch/source.tgz"; \
	  echo "$(REGISTRY_MIGRATOR_SHA256)  $$scratch/source.tgz" | shasum -a 256 -c -; \
	  tar -xzf "$$scratch/source.tgz" --strip-components=1 -C "$$scratch"; \
	  dotnet publish "$$scratch/Migration/DataProviderMigrate" -c Release -f net10.0 -o "$(abspath $(REGISTRY_MIGRATOR_DIR))/bin"

# _registry-migration-check: Apply the registry schema twice on disposable socket-only PostgreSQL.
_registry-migration-check: $(REGISTRY_MIGRATOR) $(TOOLCHAIN)
	$(MAKE) _registry-migration-verify

.PHONY: _registry-migration-verify
_registry-migration-verify:
	@test -x "$(OSPREY)" && test -s "$(REGISTRY_MIGRATOR)"
	@set -eu; pg=$$(pg_config --bindir); \
	  if [ ! -x "$$pg/postgres" ]; then pg=$$(dirname "$$(realpath "$$(command -v postgres)")"); fi; \
	  db=$$(mktemp -d /tmp/osprey-registry.XXXXXX); \
	  cleanup() { if [ -f "$$db/data/postmaster.pid" ]; then "$$pg/pg_ctl" -D "$$db/data" -m fast -w stop; fi; rm -rf "$$db"; }; \
	  trap cleanup EXIT; export PGHOST="$$db" PGPORT=18873 PGUSER=registry_check PGDATABASE=postgres; \
	  "$$pg/initdb" -D "$$db/data" -U "$$PGUSER" --auth-local=trust --auth-host=reject --no-locale >/dev/null; \
	  "$$pg/pg_ctl" -D "$$db/data" -l "$$db/server.log" -o "-k $$db -p $$PGPORT -c listen_addresses=''" -w start; \
	  "$$pg/psql" -X -v ON_ERROR_STOP=1 -c 'CREATE SCHEMA registry'; \
	  migrate() { dotnet "$(REGISTRY_MIGRATOR)" migrate --provider postgres --schema src/manager/supabase/migrations/schema.yaml --output "Host=$$PGHOST;Port=$$PGPORT;Username=$$PGUSER;Database=$$PGDATABASE"; }; \
	  migrate; migrate >"$$db/replay.log" || { cat "$$db/replay.log"; exit 1; }; cat "$$db/replay.log"; \
	  grep -Fq 'No operations to apply' "$$db/replay.log"; \
	  test "$$("$$pg/psql" -XAtc "SELECT count(*) = 14 AND bool_and(relrowsecurity AND relforcerowsecurity) FROM pg_class WHERE relnamespace = 'registry'::regnamespace AND relkind = 'r'")" = t; \
	  $(if $(REGISTRY_COVERAGE),mkdir -p $(REGISTRY_COVERAGE);) $(OSPREY) test src/manager/database-tests/live $(call registry_coverage,database-live)

.PHONY: _registry-integration-check _registry-integration-verify
# _registry-integration-check: Browse a real PostgreSQL-backed hosted API with the packaged website in Chromium.
_registry-integration-check: _registry-website-fixture $(REGISTRY_MIGRATOR)
	$(MAKE) _registry-integration-verify

# _registry-integration-verify: Exercise prebuilt Pages and migration artifacts without rebuilding them.
_registry-integration-verify:
	node scripts/packages/test-registry-preview.cjs --built-hosted-account
	REGISTRY_BROWSER_CHECK=1 $(MAKE) _registry-migration-verify

.PHONY: _registry-infra-check
# _registry-infra-check: Validate pinned registry infrastructure without contacting a state backend.
_registry-infra-check: export TF_DATA_DIR = $(CURDIR)/target/registry-infra/data
_registry-infra-check:
	shellcheck -S warning src/manager/ops/deploy.sh
	terraform -chdir=$(REGISTRY_TERRAFORM) fmt -check
	terraform -chdir=$(REGISTRY_TERRAFORM) init -backend=false -lockfile=readonly -input=false
	terraform -chdir=$(REGISTRY_TERRAFORM) validate

.PHONY: deploy
## deploy: Stand up or converge a hosted environment: Cloudflare → Cloud Run → Supabase (docs/DEPLOY.md).
##         make deploy ENV=staging|production [STEP=supabase|infra|github|database|release|smoke]
ENV ?= staging
STEP ?= all
deploy:
	src/manager/ops/deploy.sh $(ENV) $(STEP)

.PHONY: _registry-hosted-api
REGISTRY_HOSTED_BINARY ?= target/osprey-registry-hosted
# _registry-hosted-api: Compile the native Cloud Run API listener for the current platform.
_registry-hosted-api: $(REGISTRY_HOSTED_BINARY)

$(REGISTRY_HOSTED_BINARY): $(TOOLCHAIN) $(REGISTRY_CLIENT_SOURCES)
	$(OSPREY) build src/manager/api/hosted --quiet --warnings-as-errors -o $@

REGISTRY_HOSTED_IMAGE ?= osprey-registry-hosted:local
REGISTRY_HOSTED_DOCKERFILE = src/manager/ops/Dockerfile
REGISTRY_HOSTED_CONTEXT = Makefile scripts/osprey-toolchain.sh src/manager/api src/manager/core \
	src/manager/host $(REGISTRY_HOSTED_DOCKERFILE)

.PHONY: _registry-hosted-image _registry-hosted-image-check
# _registry-hosted-image: Build the Cloud Run linux/amd64 image from the checked-out commit.
_registry-hosted-image:
	@set -eu; mkdir -p target; context=$$(mktemp target/registry-hosted-context.XXXXXX); \
	  trap 'rm -f -- "$$context"' EXIT; revision=$$(git rev-parse HEAD); \
	  git archive --format=tar --output="$$context" "$$revision" $(REGISTRY_HOSTED_CONTEXT); \
	  docker buildx build --platform linux/amd64 --load --file $(REGISTRY_HOSTED_DOCKERFILE) \
	    --label "org.opencontainers.image.revision=$$revision" --tag "$(REGISTRY_HOSTED_IMAGE)" - < "$$context"

# _registry-hosted-image-check: Smoke-test the Linux image with mounted config and both listener ports.
_registry-hosted-image-check: _registry-hosted-image
	node scripts/packages/check-registry-hosted-image.mjs "$(REGISTRY_HOSTED_IMAGE)"

.PHONY: _registry-website _registry-website-fixture _registry-website-check
# _registry-website-check: Build an isolated Pages artifact and exercise its publisher flow in Chromium.
_registry-website-check: _registry-website-fixture
	node scripts/packages/test-registry-preview.cjs --built-hosted-account

_registry-website-fixture: export REGISTRY_API_ORIGIN = https://api.example.test
_registry-website-fixture: export REGISTRY_CONTENT_ORIGIN = https://content.example.test

# _registry-website: Compile the registry website to WASM and render its Cloudflare Pages directory.
_registry-website _registry-website-fixture _registry-website-archive: $(TOOLCHAIN)
	@mkdir -p target/registry-site-build
	$(OSPREY) build $(REGISTRY_WEB)/site --target=wasm32 --quiet --warnings-as-errors -o target/registry-site-build/site.wasm
	@set -eu; out=$$(mktemp -d target/registry-site-build/pages.XXXXXX); \
	  trap 'rm -rf "$$out"' EXIT; \
	  render() { printf '%s\n' "$$1" | wasmtime target/registry-site-build/site.wasm; }; \
	  render missing > "$$out/404.html"; \
	  for page in guide publishing; do \
	    mkdir "$$out/$$page"; render "$$page" > "$$out/$$page/index.html"; \
	  done; \
	  mkdir "$$out/upload"; origin="$${REGISTRY_API_ORIGIN:-}"; content="$${REGISTRY_CONTENT_ORIGIN:-}"; \
	  if [ "$@" = _registry-website-archive ] && { [ -z "$$origin" ] || [ -z "$$content" ]; }; then echo "Set REGISTRY_API_ORIGIN and REGISTRY_CONTENT_ORIGIN." >&2; exit 1; fi; \
	  node -e 'const [api, content] = process.argv.slice(1); if (content && (!api || api === content)) process.exit(1); for (const origin of [api, content].filter(Boolean)) { const u = new URL(origin); if (u.protocol !== "https:" || u.origin !== origin || !/^[a-z0-9.-]+$$/.test(u.hostname)) process.exit(1); }' "$$origin" "$$content"; \
	  script=src/manager/web/assets/registry-form.mjs; adapter="form.$$(shasum -a 256 "$$script" | cut -c1-12).mjs"; \
	  cp "$$script" "$$out/$$adapter"; \
	  asset() { file="$$1"; name="$$2.$$(shasum -a 256 "$$file" | cut -c1-12).$$3"; cp "$$file" "$$out/$$name"; echo "$$name"; }; \
	  catalog=$$(asset src/manager/web/assets/registry-catalog.mjs catalog mjs); host=$$(asset target/osprey/wasi-shim.mjs wasi mjs); guest=$$(asset target/registry-site-build/site.wasm site wasm); \
	  printf "%s\n" home "$$origin" "$$catalog" "$$host" "$$guest" "$$content" | wasmtime target/registry-site-build/site.wasm > "$$out/index.html"; \
	  printf "%s\n" hosted-package "$$origin" "$$catalog" "$$host" "$$guest" "$$content" | wasmtime target/registry-site-build/site.wasm > "$$out/package.html"; \
	  printf '/packages/* /package.html 200\n/publishers/* /package.html 200\n/tags/* /package.html 200\n' > "$$out/_redirects"; \
	  printf "%s\n" upload "$$origin" "$$adapter" | wasmtime target/registry-site-build/site.wasm > "$$out/upload/index.html"; \
	  digest=$$(shasum -a 256 $(REGISTRY_WEB)/assets/registry.css | cut -c1-12); \
	  asset="registry.$$digest.css"; grep -Fq "href=\"/$$asset\"" "$$out/index.html"; \
	  cp $(REGISTRY_WEB)/assets/registry.css "$$out/$$asset"; \
	  cp $(REGISTRY_WEB)/assets/registry-mark.svg $(REGISTRY_WEB)/assets/osprey-mark.svg "$$out/"; \
	  sed "s@form-action@script-src 'self' 'wasm-unsafe-eval'; connect-src 'self' $$origin; form-action@;s@form-action 'none'@form-action 'self'@" $(REGISTRY_WEB)/assets/_headers > "$$out/_headers"; \
	  if [ "$@" = _registry-website-archive ]; then python3 scripts/packages/archive-registry-site.py "$$out" target/registry-artifacts; \
	  else rsync -a --delete "$$out/" $(if $(filter _registry-website-fixture,$@),target/registry-site-build/hosted-fixture,target/registry-site)/; fi

.PHONY: _registry-website-archive
# _registry-website-archive: Build and archive the configured Pages site by SHA-256 for deployment.
_registry-website-archive:

.PHONY: _registry-pages
# _registry-pages: The registry website as a GitHub Pages project site in target/registry-pages: every
#                 root-relative URL gains PAGES_BASE, so the home, guide and publishing pages work there.
PAGES_BASE ?= /osprey-packages/
_registry-pages: _registry-website
	rm -rf target/registry-pages
	cp -R target/registry-site target/registry-pages
	find target/registry-pages -name '*.html' -exec sed -i.orig -E 's#(href|src|action)="/#\1="$(PAGES_BASE)#g' {} +
	find target/registry-pages -name '*.orig' -delete
	! grep -R -E '(href|src|action)="/[^/]' target/registry-pages --include='*.html' | grep -v -F '="$(PAGES_BASE)'

.PHONY: _registry-website-serve _registry-website-preview
# _registry-website-serve: Serve the built preview and live folder catalog together on localhost:4187.
_registry-website-serve:
	python3 scripts/packages/serve-registry-preview.py

# _registry-website-preview: Render searchable local packages from registry-serve into target/registry-site-preview.
_registry-website-preview: _registry-website target/osprey-pkg
	bash scripts/packages/registry-preview.sh
