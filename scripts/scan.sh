#!/usr/bin/env bash
# Step 6: runs bal scan on each package or workspace found by find-packages.sh.
#
# Each unit gets a SARIF pass, and with SONARQUBE=true a SonarQube pass:
#   - SARIF pass: bal scan --format=sarif. The scan tool writes no report file while any
#     [[platform]] entry is active, and every entry in Scan.toml is always active. So when the
#     package's Scan.toml has [[platform]] entries, they are hidden for this pass only: the file is
#     copied to the work directory and restored as soon as the pass ends, also when it fails.
#   - SonarQube pass: bal scan --platforms=sonarqube, with the package's resolved settings passed
#     to SonarScanner as environment variables of that process only, and the installed
#     SonarScanner on its path. The scan tool reads the platform plugin only from Scan.toml, so
#     its sonarqube [[platform]] entry points to the resolved plugin for this pass only: the file
#     is restored, or deleted when the action created it, as soon as the pass ends.
# A failing unit does not stop the others, so every failure is reported; the step then fails.
#
# Inputs (environment): SCAN_WORK_DIR, SONARQUBE, PLATFORM_CONFIG, SCANNER_BIN, INCLUDE_RULES,
# EXCLUDE_RULES, CATEGORY.
# Writes: $SCAN_WORK_DIR/reports/<index>.sarif per unit, in the order of units.json, and
# $SCAN_WORK_DIR/sonarqube-uploads.json.

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
ROOT="$(workspace_root)"
cd "$ROOT"

RULE_ARGS=()
INCLUDE="$(split_list "${INCLUDE_RULES:-}" | paste -sd, -)"
EXCLUDE="$(split_list "${EXCLUDE_RULES:-}" | paste -sd, -)"
[ -n "$INCLUDE" ] && RULE_ARGS+=("--include-rules=$INCLUDE")
[ -n "$EXCLUDE" ] && RULE_ARGS+=("--exclude-rules=$EXCLUDE")

SONAR=""
if [ "${SONARQUBE:-false}" = "true" ]; then
  SONAR="$(platform_config_json)" || die "$INVALID_PLATFORM_CONFIG"
  SONAR="$(jq -c '.sonarqube // {}' <<< "$SONAR")"
fi

# The token of a package: from its item under packages, then from the platform level. Each token
# goes to its own package's scan only.
sonar_token() {
  jq -r --arg p "$1" '
    ([.packages // [] | .[] | select((.path | tostring | sub("^\\./"; "") | sub("/+$"; "")
      | if . == "" then "." else . end) == $p)] | first // {}) as $item
    | $item.token // .token // "" | tostring' <<< "$SONAR"
}

# Scan.toml files changed for one pass, as "original<TAB>backup" lines. An empty backup means
# the action created the file, which is deleted.
BACKUPS="$WORK/scan-toml-backups.tsv"
: > "$BACKUPS"
restore_scan_tomls() {
  local original backup
  while IFS=$'\t' read -r original backup; do
    [ -n "$original" ] || continue
    if [ -n "$backup" ]; then
      cp "$backup" "$original" && rm -f "$backup"
    else
      rm -f "$original"
    fi
  done < "$BACKUPS"
  : > "$BACKUPS"
}
trap restore_scan_tomls EXIT INT TERM

# Points the sonarqube [[platform]] entry of a package's Scan.toml to the resolved plugin JAR until
# restore_scan_tomls runs. The other entries and settings are kept. The properties file is passed
# to SonarScanner through the environment instead, so the entry has no sonarProjectPropertiesPath.
use_plugin() {
  local settings="$1" file kind jar backup=""
  kind="$(jq -r '."scan-toml-kind"' <<< "$settings")"
  [ "$kind" != remote ] || return 0
  jar="$(to_native_path "$(jq -r '."plugin-file"' <<< "$settings")")"
  if [ "$kind" = file ]; then
    file="$(jq -r '."scan-toml"' <<< "$settings")"
    backup="$(mktemp "$WORK/Scan.toml.XXXXXX")"
    cp "$file" "$backup"
  else
    file="$(jq -r '.package' <<< "$settings")/Scan.toml"
  fi
  printf '%s\t%s\n' "$file" "$backup" >> "$BACKUPS"
  {
    if [ -n "$backup" ]; then
      awk '
        function flush() { if (!sonar) printf "%s", buf; buf = ""; sonar = 0 }
        /^[[:space:]]*\[/ { if (inplat) flush(); inplat = ($0 ~ /^[[:space:]]*\[\[[[:space:]]*platform[[:space:]]*\]\]/) }
        inplat {
          buf = buf $0 "\n"
          if ($0 ~ /^[[:space:]]*name[[:space:]]*=[[:space:]]*["\047]sonarqube["\047]/) sonar = 1
          next
        }
        { print }
        END { if (inplat) flush() }
      ' "$backup"
      echo
    fi
    printf '[[platform]]\nname = "sonarqube"\npath = "%s"\n' "$jar"
  } > "$file"
}

# Hides the [[platform]] entries of a package's Scan.toml until restore_scan_tomls runs.
hide_platforms() {
  local pkg="$1" file
  file="$(scan_toml_path "$pkg")"
  [ -n "$file" ] || return 0
  if [[ "$file" =~ ^https?:// ]]; then
    if [ "$(scan_toml_platforms "$file" | jq 'length' 2> /dev/null || echo 0)" -gt 0 ]; then
      log_warning "Package '$pkg' reads a remote Scan.toml with [[platform]] entries, which stop bal scan from writing a SARIF report."
    fi
    return 0
  fi
  [ -f "$file" ] && grep -Eq '^[[:space:]]*\[\[[[:space:]]*platform[[:space:]]*\]\]' "$file" || return 0
  local backup
  backup="$(mktemp "$WORK/Scan.toml.XXXXXX")"
  cp "$file" "$backup"
  printf '%s\t%s\n' "$file" "$backup" >> "$BACKUPS"
  awk '
    /^[[:space:]]*\[\[[[:space:]]*platform[[:space:]]*\]\]/ { skip = 1; next }
    /^[[:space:]]*\[/ { skip = 0 }
    !skip
  ' "$backup" > "$file"
}

# Runs bal scan in a directory and keeps its output in a log file. Returns its exit code.
run_bal_scan() {
  local dir="$1" log="$2"
  shift 2
  set +e
  (cd "$dir" && bal_cmd scan "$@") 2>&1 | tee "$log"
  local status="${PIPESTATUS[0]}"
  set -e
  return "$status"
}

: > "$WORK/sonarqube-uploads.jsonl"
FAILED=()
INDEX=0
while IFS= read -r unit; do
  path="$(jq -r '.path' <<< "$unit")"
  kind="$(jq -r '.kind' <<< "$unit")"
  report="$path/target/report/scan_results.sarif"
  idx=$INDEX
  INDEX=$((INDEX + 1))
  out="$WORK/reports/$idx.sarif"

  echo "::group::bal scan $path"
  rm -f "$report" "$out"
  if [ "$kind" = "workspace" ]; then
    while IFS= read -r member; do
      [ -d "$path/$member" ] && hide_platforms "$path/$member"
    done < <(jq -r '.members[]' <<< "$unit")
  else
    hide_platforms "$path"
  fi

  status=0
  run_bal_scan "$path" "$WORK/logs/scan-$idx.log" --format=sarif "${RULE_ARGS[@]+"${RULE_ARGS[@]}"}" || status=$?
  restore_scan_tomls

  # bal scan reports some errors, such as an invalid Scan.toml, without a failing exit code.
  if [ "$status" -ne 0 ]; then
    FAILED+=("$path: bal scan exited with code $status")
  elif [ ! -f "$report" ] || ! jq -e '.runs[0]' "$report" > /dev/null 2>&1; then
    FAILED+=("$path: bal scan did not write a SARIF report. See its output above")
  else
    cp "$report" "$out"
  fi
  echo "::endgroup::"

  if [ "${SONARQUBE:-false}" = "true" ]; then
    settings="$(jq -c --arg p "$path" 'map(select(.package == $p)) | first' "$WORK/sonarqube.json")"
    echo "::group::bal scan $path (report to SonarQube project $(jq -r '."project-key"' <<< "$settings"))"
    task_file="$path/.scannerwork/report-task.txt"
    rm -f "$task_file"
    log="$WORK/logs/sonarqube-$idx.log"
    # SonarScanner gives these environment settings precedence over the properties file.
    # analyzedResultsPath is the file the platform plugin writes in the package directory. The
    # plugin also passes it on the command line, which does not reach SonarScanner on every
    # operating system, and without it the analysis runs bal scan a second time.
    user_params="$(jq -c 'objects' <<< "${SONAR_SCANNER_JSON_PARAMS:-}" 2> /dev/null || true)"
    [ -n "$user_params" ] || user_params='{}'
    params="$(jq -c \
      --arg settings "$(to_native_path "$(jq -r '."properties-file"' <<< "$settings")")" \
      --arg results "$(to_native_path "$ROOT/$path/ballerina-static-code-analysis-results.json")" \
      --argjson user "$user_params" \
      '$user + {"sonar.projectKey": ."project-key", analyzedResultsPath: $results}
        + (if ."project-name" != "" then {"sonar.projectName": ."project-name"} else {} end)
        + (if $settings != "" then {"project.settings": $settings} else {} end)' <<< "$settings")"
    use_plugin "$settings"
    status=0
    # Set on this process only, and credentials never appear on the command line.
    PATH="${SCANNER_BIN:+$SCANNER_BIN:}$PATH" \
      SONAR_HOST_URL="$(jq -r '."host-url"' <<< "$settings")" \
      SONAR_TOKEN="$(sonar_token "$path")" \
      SONAR_SCANNER_JSON_PARAMS="$params" \
      run_bal_scan "$path" "$log" --platforms=sonarqube "${RULE_ARGS[@]+"${RULE_ARGS[@]}"}" || status=$?
    restore_scan_tomls
    # The platform plugin prints the outcome of SonarScanner but does not fail bal scan.
    if [ "$status" -ne 0 ]; then
      FAILED+=("$path: reporting to SonarQube failed, bal scan exited with code $status")
    elif ! grep -q 'Reporting successful!' "$log"; then
      FAILED+=("$path: reporting to SonarQube failed. See the SonarScanner output above")
    else
      dashboard="$(read_property "$task_file" dashboardUrl | sed 's/\\:/:/g')"
      task_id="$(read_property "$task_file" ceTaskId)"
      jq -nc --argjson s "$settings" --arg url "$dashboard" --arg task "$task_id" \
        '{package: $s.package, "project-key": $s."project-key", "dashboard-url": $url, "task-id": $task}' \
        >> "$WORK/sonarqube-uploads.jsonl"
    fi
    echo "::endgroup::"
  fi
done < <(jq -c '.[]' "$WORK/units.json")

jq -sc '.' "$WORK/sonarqube-uploads.jsonl" > "$WORK/sonarqube-uploads.json"

if [ "${#FAILED[@]}" -gt 0 ]; then
  for f in "${FAILED[@]}"; do log_error "$f."; done
  die "bal scan failed for ${#FAILED[@]} of $INDEX package(s), so no SARIF file was produced."
fi
