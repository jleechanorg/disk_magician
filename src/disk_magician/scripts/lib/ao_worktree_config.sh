# shellcheck shell=bash
# ao_worktree_config.sh — validate the live AO YAML before projecting owners.
# Call ao_worktree_dirs <yaml>; prints P <dir> / C <dir> records on success.
_ao_worktree_config_valid() {
    local config="$1"
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
        python3 - "$config" >/dev/null 2>&1 <<'PY'
import sys
import yaml
with open(sys.argv[1], encoding="utf-8") as stream:
    document = yaml.safe_load(stream)
if not isinstance(document, dict):
    raise SystemExit(1)
if "worktreeDir" in document and not isinstance(document["worktreeDir"], str):
    raise SystemExit(1)
projects = document.get("projects", {})
if not isinstance(projects, dict):
    raise SystemExit(1)
for project in projects.values():
    if not isinstance(project, dict):
        raise SystemExit(1)
    for key in ("path", "worktreeDir"):
        if key in project and not isinstance(project[key], str):
            raise SystemExit(1)
PY
    elif command -v ruby >/dev/null 2>&1; then
        ruby -ryaml -e 'd = YAML.safe_load(File.read(ARGV[0]), aliases: true); exit 1 unless d.is_a?(Hash); exit 1 if d.key?("worktreeDir") && !d["worktreeDir"].is_a?(String); p = d.fetch("projects", {}); exit 1 unless p.is_a?(Hash); p.each_value { |v| exit 1 unless v.is_a?(Hash); %w[path worktreeDir].each { |k| exit 1 if v.key?(k) && !v[k].is_a?(String) } }' "$config" >/dev/null 2>&1
    else
        return 1
    fi
}

# ao_worktree_dirs <yaml>: project worktreeDir -> P <dir>; root default -> C <dir>.
# Projects without a project directory inherit <default>/<key> and optionally
# <default>/<basename of path>, matching the prior cleanup projection.
ao_worktree_dirs() {
    local config="$1" projection
    [[ -f "$config" && -r "$config" ]] || return 1
    _ao_worktree_config_valid "$config" || return 1
    projection="$(awk '
        function val(l) { sub(/^[^:]*:[[:space:]]*/, "", l); sub(/[[:space:]]+#.*$/, "", l)
                          gsub(/["\047]/, "", l); sub(/[[:space:]]+$/, "", l); return l }
        /^[^[:space:]#]/ { inproj = ($0 ~ /^projects:/); key = "" }
        /^worktreeDir:/ { def = val($0); next }
        inproj && /^  [^[:space:]#][^:]*:[[:space:]]*$/ { key = $1; sub(/:$/, "", key); keys[++n] = key; next }
        /^[[:space:]]+worktreeDir:/ { d = val($0); if (d != "") print "P " d; if (key != "") own[key] = 1; next }
        key != "" && /^    path:/ { p = val($0); sub(/\/+$/, "", p); sub(/.*\//, "", p); base[key] = p }
        END {
            if (def != "") { sub(/\/+$/, "", def); print "C " def }
            for (i = 1; i <= n; i++) if (!own[keys[i]] && def != "") {
                print "P " def "/" keys[i]
                if (base[keys[i]] != "") print "P " def "/" base[keys[i]]
            }
        }' "$config")" || return 1
    printf '%s\n' "$projection"
}
