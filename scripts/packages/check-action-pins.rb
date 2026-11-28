# [PACKAGE-HOSTED-RELEASE] Inspect workflow steps, reusable workflows and local composites.
require "yaml"

def check(node, file)
  case node
  when Hash
    node.each do |key, value|
      if key == "uses"
        next if value.is_a?(String) && (value.start_with?("./") ||
          value.match?(%r{\A[\w.-]+/[\w./-]+@[0-9a-f]{40}\z}))
        abort "#{file}: pin #{value.inspect} to a full commit SHA"
      end
      check(value, file)
    end
  when Array
    node.each { |child| check(child, file) }
  end
end

Dir[".github/{workflows/*,actions/**/action}.{yml,yaml}"].each do |file|
  check(YAML.safe_load_file(file, aliases: true), file)
end
