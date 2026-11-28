# Compare psql -At output from registry-table-inventory.sql with the reviewed migration.
require "json"
require "yaml"

schema = File.expand_path("../../src/manager/ops/supabase/migrations/schema.yaml", __dir__)
tables = YAML.safe_load_file(schema, aliases: true).fetch("tables")
expected = tables.select { |table| table.fetch("schema") == "registry" }.map { |table| table.fetch("name") }
abort "No registry tables declared in the migration" if expected.empty?
live = STDIN.each_line.map { |line| JSON.parse(line) }
names = live.map { |row| row.fetch("name") }
issues = {
  "missing tables" => expected - names,
  "unexpected tables" => names - expected,
  "tables without forced RLS" => live.reject { |row| row.fetch("forced") == true }.map { |row| row.fetch("name") }
}
issues.delete_if { |_, entries| entries.empty? }
abort issues.map { |reason, entries| "#{reason}: #{entries.sort.join(', ')}" }.join("\n") unless issues.empty?
puts "Verified #{names.length} registry tables with forced RLS"
