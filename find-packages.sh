#!/usr/bin/env bash
# Step 2: finds the packages and workspaces to scan.
#
# Each entry in SCAN_PATHS is a package or a directory searched for Ballerina.toml, skipping
# target, build and .git. A workspace is scanned as one unit from its root, so its member
# packages are not scanned again on their own. Units matching EXCLUDE_PATHS are dropped.
#
# Inputs (environment): SCAN_WORK_DIR, SCAN_PATHS, EXCLUDE_PATHS, CATEGORY.
# Writes: $SCAN_WORK_DIR/units.json, a list of {path, kind, members}, with paths relative to
# the repository root.
# Outputs: count (units to scan), packages (packages they hold).

ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$ACTION_DIR/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
ROOT="$(workspace_root)"
cd "$ROOT"

FOUND=()
while IFS= read -r p; do
  while IFS= read -r toml; do
    FOUND+=("$(repo_relative_dir "$(dirname "$toml")")")
  done < <(find "$p" \( -name target -o -name build -o -name .git \) -prune -o -name Ballerina.toml -type f -print)
done < <(split_list "${SCAN_PATHS:-.}")

UNITS='[]'
if [ "${#FOUND[@]}" -gt 0 ]; then
  while IFS= read -r dir; do
    if grep -Eq '^[[:space:]]*\[workspace\][[:space:]]*(#.*)?$' "$dir/Ballerina.toml"; then
      MEMBERS="$(yq -p toml -o json -I0 '.workspace.packages // []' "$dir/Ballerina.toml" 2> /dev/null || echo '[]')"
      UNIT="$(jq -nc --arg path "$dir" --argjson members "$MEMBERS" \
        '{path: $path, kind: "workspace", members: [$members[] | tostring | sub("^\\./"; "") | sub("/+$"; "")]}')"
    else
      UNIT="$(jq -nc --arg path "$dir" '{path: $path, kind: "package", members: []}')"
    fi
    UNITS="$(jq -c --argjson unit "$UNIT" '. + [$unit]' <<< "$UNITS")"
  done < <(printf '%s\n' "${FOUND[@]}" | sort -u)
fi

EXCLUDES="$(split_list "${EXCLUDE_PATHS:-}" | jq -R . | jq -sc .)"
UNITS="$(jq -c -L "$ACTION_DIR" --argjson excludes "$EXCLUDES" '
  include "common";
  ([.[] | select(.kind == "workspace") | .path as $ws | .members[] | join_path($ws; .)]) as $covered
  | map(select(
      (.kind == "workspace" or (.path | IN($covered[]) | not))
      and (.path | excluded($excludes) | not)))
' <<< "$UNITS")"

printf '%s\n' "$UNITS" > "$WORK/units.json"
COUNT="$(jq 'length' <<< "$UNITS")"

if [ "$COUNT" -eq 0 ]; then
  log_warning "No Ballerina package was found in paths '$(split_list "${SCAN_PATHS:-.}" | paste -sd, -)'. Nothing was scanned."
else
  echo "Found $COUNT package(s) to scan:"
  jq -r '.[] | "  \(.path)\(if .kind == "workspace" then " (workspace)" else "" end)"' <<< "$UNITS"
fi
set_output count "$COUNT"
set_output packages "$(jq '[.[] | if .kind == "workspace" then (.members | length) else 1 end] | add // 0' <<< "$UNITS")"
