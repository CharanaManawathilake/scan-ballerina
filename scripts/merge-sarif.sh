#!/usr/bin/env bash
# Step 7: normalizes the package reports, merges them into one SARIF file and counts the findings.
#
# Inputs (environment): SCAN_WORK_DIR, EXCLUDE_TESTS, EXCLUDE_PATHS, CATEGORY.
# Writes: the merged SARIF file and $SCAN_WORK_DIR/findings.json, the counted findings.
# Outputs: sarif-file, high-count, medium-count, low-count, total-count.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
EXCLUDES="$(split_list "${EXCLUDE_PATHS:-}" | jq -R . | jq -sc .)"
EXCLUDE_TESTS_JSON="$([ "$(trim "${EXCLUDE_TESTS:-true}")" = "true" ] && echo true || echo false)"

mkdir -p "$WORK/normalized"
INDEX=0
while IFS= read -r unit; do
  report="$WORK/reports/$INDEX.sarif"
  [ -f "$report" ] || die "The report of '$(jq -r '.path' <<< "$unit")' is missing from the work directory."
  jq -L "$SCRIPT_DIR" -f "$SCRIPT_DIR/normalize-sarif.jq" \
    --arg prefix "$(jq -r '.path' <<< "$unit")" \
    --argjson packages "$(jq -c 'if .kind == "workspace" then .members else [""] end' <<< "$unit")" \
    --argjson exclude_tests "$EXCLUDE_TESTS_JSON" \
    --argjson excludes "$EXCLUDES" \
    "$report" > "$WORK/normalized/$INDEX.sarif"
  INDEX=$((INDEX + 1))
done < <(jq -c '.[]' "$WORK/units.json")

SAFE_CATEGORY="$(tr -c 'A-Za-z0-9._-' '_' <<< "$(trim "${CATEGORY:-bal-scan}")" | sed 's/_$//')"
SARIF="$WORK/$SAFE_CATEGORY.sarif"
FILES=()
for ((i = 0; i < INDEX; i++)); do FILES+=("$WORK/normalized/$i.sarif"); done
jq -s -f "$SCRIPT_DIR/merge-sarif.jq" "${FILES[@]}" > "$SARIF"

jq -L "$SCRIPT_DIR" '
  include "common";
  .runs[0].tool.driver.rules as $rules
  | [.runs[0].results[] | {
      severity: severity($rules),
      rule: .ruleId,
      message: (.message.text // ""),
      file: (.locations[0].physicalLocation.artifactLocation.uri // ""),
      line: (.locations[0].physicalLocation.region.startLine // 1),
      "end-line": (.locations[0].physicalLocation.region.endLine // null),
      column: (.locations[0].physicalLocation.region.startColumn // null),
      "end-column": (.locations[0].physicalLocation.region.endColumn // null)
    } | select(.severity != "none")]
' "$SARIF" > "$WORK/findings.json"

count() { jq --arg s "$1" '[.[] | select(.severity == $s)] | length' "$WORK/findings.json"; }
HIGH="$(count high)"
MEDIUM="$(count medium)"
LOW="$(count low)"
TOTAL=$((HIGH + MEDIUM + LOW))

# Paths in outputs use the runner's native form, so later steps on Windows can read them.
SARIF_OUT="$SARIF"
command -v cygpath > /dev/null 2>&1 && SARIF_OUT="$(cygpath -w "$SARIF")"

echo "bal scan '${CATEGORY:-bal-scan}': $HIGH high, $MEDIUM medium, $LOW low severity finding(s)"
echo "SARIF file: $SARIF_OUT"
set_output sarif-file "$SARIF_OUT"
set_output high-count "$HIGH"
set_output medium-count "$MEDIUM"
set_output low-count "$LOW"
set_output total-count "$TOTAL"
