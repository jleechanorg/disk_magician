# shellcheck shell=bash
# ao_worktree_config.sh — parse and project AO ownership using a YAML parser.
# Call ao_worktree_dirs <yaml>; prints P <dir> / C <dir> records on success.
ao_worktree_dirs() {
    local config="$1"
    [[ -f "$config" && -r "$config" ]] || return 1
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
        python3 - "$config" <<'PY'
import os
import sys
import yaml

class UniqueKeyLoader(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        seen = set()
        for key_node, _ in node.value:
            key = self.construct_object(key_node, deep=deep)
            if key in seen:
                raise yaml.constructor.ConstructorError("while constructing a mapping", node.start_mark, f"duplicate key {key!r}", key_node.start_mark)
            seen.add(key)
        return super().construct_mapping(node, deep=deep)

def fail():
    raise SystemExit(1)

def path_value(value):
    if not isinstance(value, str) or "\n" in value or "\r" in value:
        fail()
    return value.rstrip("/") or ("/" if value.startswith("/") else "")

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        document = yaml.load(stream, Loader=UniqueKeyLoader)
    if not isinstance(document, dict):
        fail()
    default = path_value(document["worktreeDir"]) if "worktreeDir" in document else ""
    projects = document.get("projects", {})
    if not isinstance(projects, dict):
        fail()
    if default:
        print("C " + default)
    for key, project in projects.items():
        if not isinstance(key, str) or "\n" in key or "\r" in key or not isinstance(project, dict):
            fail()
        if "path" in project and (not isinstance(project["path"], str) or "\n" in project["path"] or "\r" in project["path"]):
            fail()
        if "worktreeDir" in project:
            directory = path_value(project["worktreeDir"])
            if directory:
                print("P " + directory)
        elif default:
            print("P " + default + "/" + key)
            project_path = project.get("path", "")
            basename = os.path.basename(project_path.rstrip("/")) if project_path else ""
            if basename and basename != key:
                print("P " + default + "/" + basename)
except Exception:
    fail()
PY
    elif command -v ruby >/dev/null 2>&1; then
        ruby -ryaml -e '
          def fail_parse; exit 1; end
          def reject_duplicate_keys(node)
            return unless node.respond_to?(:children) && node.children
            if node.is_a?(Psych::Nodes::Mapping)
              keys = []
              node.children.each_slice(2) do |key_node, value_node|
                fail_parse unless key_node.is_a?(Psych::Nodes::Scalar)
                fail_parse if keys.include?(key_node.value)
                keys << key_node.value
                reject_duplicate_keys(key_node)
                reject_duplicate_keys(value_node)
              end
            else
              node.children.each { |child| reject_duplicate_keys(child) }
            end
          end
          def path_value(value)
            fail_parse unless value.is_a?(String) && !value.include?("\n") && !value.include?("\r")
            normalized = value.sub(%r{/+$}, "")
            normalized.empty? && value.start_with?("/") ? "/" : normalized
          end
          begin
            ast = YAML.parse_file(ARGV[0])
            reject_duplicate_keys(ast)
            document = YAML.safe_load(File.read(ARGV[0]), aliases: true)
            fail_parse unless document.is_a?(Hash)
            default = document.key?("worktreeDir") ? path_value(document["worktreeDir"]) : ""
            projects = document.fetch("projects", {})
            fail_parse unless projects.is_a?(Hash)
            puts "C #{default}" unless default.empty?
            projects.each do |key, project|
              fail_parse unless key.is_a?(String) && !key.include?("\n") && !key.include?("\r") && project.is_a?(Hash)
              fail_parse if project.key?("path") && (!project["path"].is_a?(String) || project["path"].include?("\n") || project["path"].include?("\r"))
              if project.key?("worktreeDir")
                directory = path_value(project["worktreeDir"])
                puts "P #{directory}" unless directory.empty?
              elsif !default.empty?
                puts "P #{default}/#{key}"
                project_path = project.fetch("path", "")
                basename = File.basename(project_path.sub(%r{/+$}, "")) unless project_path.empty?
                puts "P #{default}/#{basename}" if basename && !basename.empty? && basename != key
              end
            end
          rescue StandardError
            exit 1
          end
        ' "$config"
    else
        return 1
    fi
}
