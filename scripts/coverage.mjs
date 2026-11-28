// The coverage gate [REPO-SPLIT]: merges every `osprey test --coverage-json` report the test jobs
// wrote, keeps only the package manager's files (src/manager) and gates each
// project in scripts/coverage-thresholds.json on its own line coverage. A file belongs to the project whose
// path is its longest prefix; a reported file in no listed project fails, as does a threshold
// below the 95% floor. A line counts as covered when any suite, under any memory backend, ran it.
// Reads reports only; runs nothing.
// usage: node scripts/coverage.mjs <checkout> <report.json...>
import { readFileSync } from 'node:fs'
import { dirname, join, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const [checkout, ...reports] = process.argv.slice(2)
if (!checkout || reports.length === 0) {
  console.error('usage: node scripts/coverage.mjs <checkout> <report.json...>')
  process.exit(2)
}
const owned = ['src/manager']
const FLOOR = 95
const { projects } = JSON.parse(readFileSync(join(here, 'scripts', 'coverage-thresholds.json'), 'utf8'))
const failures = Object.entries(projects).filter(([, threshold]) => !(threshold >= FLOOR && threshold <= 100))
  .map(([project, threshold]) => `${project}: threshold ${threshold}% is below the ${FLOOR}% floor`)
const under = (file, path) => file === path || file.startsWith(`${path}/`)
const projectOf = (file) => Object.keys(projects).filter((path) => under(file, path)).sort((a, b) => b.length - a.length)[0]
const ours = (file) => owned.some((path) => under(file, path))

const lines = new Map()
for (const report of reports) {
  const { files } = JSON.parse(readFileSync(report, 'utf8'))
  for (const [absolute, { lines: counts }] of Object.entries(files)) {
    const file = relative(resolve(checkout), resolve(absolute)).split(sep).join('/')
    if (!ours(file)) continue
    const hits = lines.get(file) ?? new Map()
    for (const [line, count] of Object.entries(counts)) hits.set(line, (hits.get(line) ?? 0) + count)
    lines.set(file, hits)
  }
}
const tally = new Map()
for (const [file, hits] of lines) {
  const project = projectOf(file)
  if (!project) { failures.push(`${file}: in no project of scripts/coverage-thresholds.json`); continue }
  const counts = tally.get(project) ?? { files: 0, lines: 0, covered: 0 }
  counts.files += 1
  for (const count of hits.values()) { counts.lines += 1; if (count > 0) counts.covered += 1 }
  tally.set(project, counts)
}
for (const [project, threshold] of Object.entries(projects)) {
  const counts = tally.get(project)
  if (!counts || counts.lines === 0) { failures.push(`${project}: no coverage reported`); continue }
  const percent = Math.floor((counts.covered / counts.lines) * 1000) / 10
  console.log(`${percent < threshold ? 'FAIL' : 'ok  '} ${project}: ${counts.files} files, ${counts.covered}/${counts.lines} lines, ${percent}% (threshold ${threshold}%)`)
  if (percent < threshold) failures.push(`${project}: coverage ${percent}% is below ${threshold}%`)
}
for (const failure of failures) console.error(failure)
if (failures.length > 0) process.exit(1)
