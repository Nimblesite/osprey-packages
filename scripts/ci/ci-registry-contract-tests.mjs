// The package registry's contracts: its security suites gate CI and local
// tests under GC and ARC with a real uv, nested compiler invocations keep the
// selected compiler and memory backend, suites default to GC over stale
// inherited E2E context, and an invalid REGISTRY_MEMORY fails before any
// compiler runs. Run from the repository root:
//   node --test scripts/ci/ci-registry-contract-tests.mjs
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { isAbsolute, join, relative, resolve } from 'node:path'
import { spawnSync } from 'node:child_process'

const workflow = '.github/workflows/ci.yml'
const recipes = 'Makefile'

// One job's block of the workflow, and one make target's commands, read as text.
const job = (name) => readFileSync(workflow, 'utf8').replaceAll('\r\n', '\n').split(/(?=^  [\w-]+:\s*$)/m)
  .find((block) => block.startsWith(`  ${name}:`)) ?? ''
function makeRecipe(name) {
  const commands = []
  let active = false
  for (const line of [...readFileSync(recipes, 'utf8').split('\n'), '.end-of-file:']) {
    if (line.startsWith(`${name}:`)) { active = true; continue }
    if (active && /^[^\s#][^:]*:/.test(line)) break
    if (active && line.startsWith('\t')) commands.push(line.trim())
  }
  return commands
}

function assertRealUv(registry, memory) {
  for (const requirement of [/uses: astral-sh\/setup-uv@[0-9a-f]{40}\b/,
    /version: "0\.11\.3"/, /python-version: "3\.12"/, /uv python install 3\.12/, /run: chmod \+x target\/osprey\/osprey target\/osprey-pkg/]) assert.match(registry, requirement)
  const available = registry.indexOf('uv --version')
  assert.ok(available >= 0, 'real uv must be available')
  assert.ok(available < registry.indexOf('_test_registry REGISTRY_MEMORY='), 'uv must be installed before package tests')
  const local = makeRecipe('ci')
  assert.ok(local.includes(`$(MAKE) _test_registry REGISTRY_MEMORY=${memory} REGISTRY_COVERAGE=target/coverage`))
}

const registrySuites = ['fixture-check', 'manifest/tests', 'cli/tests', 'tests', 'e2e', 'auth-tests', 'database-tests', 'governance-tests', 'hosted-tests', 'web', 'editor/tests', 'editor/wire-tests']

// A fake compiler records, for every process the Make target starts, its argv plus
// the two E2E selection variables. Only those three fields are stored — no secret
// from the inherited environment — and the contract is read from real child
// processes rather than a source-text mirror.

function registryFixture() {
  mkdirSync(resolve('target'), { recursive: true })
  const root = mkdtempSync(resolve('target/registry-selection-'))
  const compiler = join(root, 'osprey')
  writeFileSync(compiler, `#!${process.execPath}

const fs = require('node:fs');
fs.appendFileSync(process.env.REGISTRY_TEST_RECEIPT, JSON.stringify({ argv: process.argv.slice(2),
  OSPREY_E2E_COMPILER: process.env.OSPREY_E2E_COMPILER, OSPREY_E2E_MEMORY: process.env.OSPREY_E2E_MEMORY }) + '\\n');
`, { mode: 0o755 })
  nativePythonFixture(root)
  return { root, compiler, receipt: join(root, 'receipt.jsonl') }
}

function nativePythonFixture(root) {
  writeFileSync(join(root, 'python3'), `#!${process.execPath}

const fs = require('node:fs');

const scripts = ['scripts/packages/test-package-publication.py', 'scripts/packages/test-package-interruption.py'];
if (process.argv.length !== 3 || !scripts.includes(process.argv[2])) process.exitCode = 1;
else fs.appendFileSync(process.env.REGISTRY_TEST_RECEIPT + '.native', JSON.stringify({
  script: process.argv[2], compiler: process.env.OSPREY_E2E_COMPILER,
  memory: process.env.OSPREY_E2E_MEMORY, client: process.env.OSPREY_PACKAGE_CLIENT }) + '\\n');
`, { mode: 0o755 })
}

function registryEnv({ root, receipt }, overrides) {
  const env = { ...process.env, PATH: `${root}:${process.env.PATH ?? ''}`, REGISTRY_TEST_RECEIPT: receipt }
  for (const [name, value] of Object.entries(overrides)) {
    if (value === undefined) delete env[name]
    else env[name] = value
  }
  return env
}

function runRegistryMake(fixture, overrides) {
  const result = spawnSync('make', ['-s', '-f', recipes, '_test_registry',
    `BIN=${relative(process.cwd(), fixture.compiler)}`], { encoding: 'utf8', env: registryEnv(fixture, overrides) })
  return { result, invocations: registryCalls(fixture.receipt), native: registryCalls(fixture.receipt + '.native') }
}

function registryCalls(path) {
  const recorded = existsSync(path) ? readFileSync(path, 'utf8') : ''
  return recorded.split('\n').filter(Boolean).map(line => JSON.parse(line))
}

function assertNativeRegistryCalls(native, fixture, memory) {
  const selected = memory === 'arc' ? 'target/registry-tests/osprey-pkg-arc' : 'target/osprey-pkg'
  assert.deepEqual(native.map(call => call.script), ['scripts/packages/test-package-publication.py', 'scripts/packages/test-package-interruption.py'])
  for (const call of native) {
    assert.equal(call.compiler, fixture.compiler)
    assert.equal(call.memory, memory)
    assert.equal(call.client, process.env.OSPREY_PACKAGE_CLIENT || resolve(selected))
  }
}

function withRegistryFixture(body) {
  const fixture = registryFixture()
  try { body(fixture) } finally { rmSync(fixture.root, { recursive: true, force: true }) }
}

{
  test('hosted registry browser and database tests gate CI on prebuilt inputs', () => {
    const build = job('build')
    const hosted = job('test-hosted')
    assert.match(build, /_registry-website-fixture _registry-migration-tool/)
    assert.match(build, /target\/registry-site-build\/hosted-fixture\//)
    assert.match(hosted, /needs: build/)
    assert.match(hosted, /registry-integration-verify/)
    assert.doesNotMatch(hosted, /registry-website-fixture|_registry-migration-tool/)
    assert.match(job('ci'), /needs: \[build, test, hunt, test-hosted, coverage\]/)
    assert.match(job('ci'), /if: always\(\)/)
  })

  test('phase 1 gates analysis: warnings are errors, sources are formatted, duplication stays under 3%', () => {
    const build = job('build')
    assert.ok(build.indexOf('make _lint') >= 0 && build.indexOf('make _lint') < build.indexOf('make build'), 'analysis runs before the build')
    const lint = makeRecipe('_lint').join('\n')
    for (const gate of ['--check --warnings-as-errors', 'fmt --check src/manager', 'scripts/deslop.sh']) assert.ok(lint.includes(gate), gate)
    assert.match(readFileSync('.deslop.toml', 'utf8'), /max_duplication_percent = 3\.0/)
    assert.doesNotMatch(readFileSync('Makefile', 'utf8'), /--no-warnings/, 'no build silences warnings')
  })

  test('osprey hunt runs from every program entry under GC and ARC in phase 2', () => {
    const hunt = job('hunt')
    assert.match(hunt, /needs: build/)
    assert.match(hunt, /memory: \[gc, arc\]/)
    assert.ok(hunt.includes('make _hunt HUNT_MEMORY=${{ matrix.memory }}'))
    assert.match(job('ci'), /needs\.hunt\.result/)
    assert.ok(makeRecipe('_hunt').some((line) => line.includes('$(OSPREY) hunt src/manager/$$p --memory=$(HUNT_MEMORY)')))
  })

  test('every suite\'s coverage reaches the gate, and the gate reads reports only', () => {
    const registry = job('test')
    assert.ok(registry.includes('REGISTRY_COVERAGE=target/coverage'))
    assert.match(registry, /name: coverage-\$\{\{ matrix\.memory \}\}/)
    const coverage = job('coverage')
    assert.match(coverage, /needs: \[test, test-hosted\]/)
    assert.match(coverage, /node scripts\/coverage\.mjs \. target\/coverage\/\*\.json/)
    assert.doesNotMatch(coverage, /osprey test|make /, 'phase 3 runs no test')
    const commands = makeRecipe('_test_registry')
    const first = commands.findIndex((line) => line.includes('$(call registry_coverage,'))
    const made = commands.indexOf('$(if $(REGISTRY_COVERAGE),mkdir -p $(REGISTRY_COVERAGE))')
    assert.ok(made >= 0 && made < first, 'a fresh runner has no coverage directory: it is made before the first suite writes to it')
    for (const suite of registrySuites) assert.ok(commands.some((line) => line.endsWith(`$(call registry_coverage,${suite.replaceAll('/', '-')})`)), suite)
  })

  test('make ci gates coverage like CI: fresh reports from both backends, then the gate, last', () => {
    const dry = spawnSync('make', ['-n', '-f', recipes, 'ci', 'BIN=/bin/true'], { encoding: 'utf8' })
    assert.equal(dry.status, 0, dry.stdout + dry.stderr)
    const lines = dry.stdout.split('\n')
    const at = (pattern) => lines.findIndex((line) => pattern.test(line))
    const cleared = at(/rm -rf target\/coverage\b/)
    const gc = at(/_test_registry REGISTRY_MEMORY=gc REGISTRY_COVERAGE=target\/coverage/)
    const arc = at(/_test_registry REGISTRY_MEMORY=arc REGISTRY_COVERAGE=target\/coverage/)
    const gate = at(/node scripts\/coverage\.mjs \. target\/coverage\/\*\.json/)
    for (const [name, index] of Object.entries({ cleared, gc, arc, gate })) assert.ok(index >= 0, `make ci must run: ${name}`)
    assert.ok(cleared < gc && gc < arc && arc < gate, 'stale reports are cleared, both backends report, then the gate reads them')
    assert.equal(gate, Math.max(...lines.map((line, i) => (/node |\$\(MAKE\)|make /.test(line) ? i : -1))), 'the coverage gate is the last step of make ci')
  })

  test('package manager security suites gate CI and local tests under GC and ARC', () => {
    const registry = job('test')
    assert.match(registry, /needs: build/)
    assert.match(registry, /memory: \[gc, arc\]/)
    assert.ok(registry.includes('name: "Tests: package manager (${{ matrix.memory }})"'))
    assert.ok(registry.includes('_test_registry REGISTRY_MEMORY=${{ matrix.memory }}'))
    for (const memory of ['gc', 'arc']) assertRealUv(registry, memory)
    const commands = makeRecipe('_test_registry')
    for (const script of ['publication', 'interruption']) assert.match(commands.join('\n'), new RegExp(`OSPREY_PACKAGE_CLIENT=.*REGISTRY_NATIVE_CLIENT.*python3 scripts/packages/test-package-${script}\\.py`))
    for (const suite of registrySuites) {
      assert.ok(commands.includes(`$(OSPREY) test src/manager/${suite} --memory=$(REGISTRY_MEMORY) $(call registry_coverage,${suite.replaceAll('/', '-')})`), suite)
    }
  })

  test('registry nested compiler invocations retain the selected compiler and memory backend', () => {
    withRegistryFixture(fixture => {
      const { result, invocations, native } = runRegistryMake(fixture, { REGISTRY_MEMORY: 'arc' })
      assert.equal(result.status, 0, result.stdout + result.stderr)
      assertNativeRegistryCalls(native, fixture, 'arc')
      // Order proves the fail-fast fixture suite still runs first.
      const expected = registrySuites.map(suite => ['test', `src/manager/${suite}`])
      if (!process.env.OSPREY_PACKAGE_CLIENT) expected.push(['build', 'src/manager/cli'])
      assert.deepEqual(invocations.map(seen => seen.argv.slice(0, 2)), expected)
      const builds = invocations.filter(seen => seen.argv[0] === 'build')
      assert.equal(builds.length, process.env.OSPREY_PACKAGE_CLIENT ? 0 : 1)
      if (builds.length) assert.ok(['src/manager/cli', '--memory=arc', '--warnings-as-errors', resolve('target/registry-tests/osprey-pkg-arc')].every(arg => builds[0].argv.includes(arg)))
      for (const seen of invocations) {
        assert.equal(seen.OSPREY_E2E_COMPILER, fixture.compiler)
        assert.ok(isAbsolute(seen.OSPREY_E2E_COMPILER), 'selection must stay absolute')
        assert.equal(seen.OSPREY_E2E_MEMORY, 'arc')
        assert.ok(seen.argv.includes('--memory=arc'), `${seen.argv[1]} must run ARC`)
      }
    })
  })

  test('registry suites default to GC and override stale inherited E2E context', () => {
    withRegistryFixture(fixture => {
      const { result, invocations, native } = runRegistryMake(fixture, { REGISTRY_MEMORY: undefined,
        OSPREY_E2E_COMPILER: '/stale/compiler', OSPREY_E2E_MEMORY: 'default' })
      assert.equal(result.status, 0, result.stdout + result.stderr)
      assertNativeRegistryCalls(native, fixture, 'gc')
      assert.equal(invocations.length, registrySuites.length)
      for (const seen of invocations) {
        assert.equal(seen.OSPREY_E2E_COMPILER, fixture.compiler)
        assert.equal(seen.OSPREY_E2E_MEMORY, 'gc')
        assert.ok(seen.argv.includes('--memory=gc'), `${seen.argv[1]} must run GC`)
      }
    })
  })

  test('an invalid REGISTRY_MEMORY fails before any compiler executes', () => {
    withRegistryFixture(fixture => {
      const { result, invocations } = runRegistryMake(fixture, { REGISTRY_MEMORY: 'default' })
      assert.notEqual(result.status, 0, 'unsupported backends must not be tolerated')
      assert.match(result.stdout + result.stderr, /Registry tests require GC or ARC/)
      assert.deepEqual(invocations, [], 'no suite may start with an unsupported backend')
    })
  })
}
