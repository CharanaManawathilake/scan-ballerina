#!/usr/bin/env bash
# Steps 11 and 12: writes annotations and the job summary, then applies the gate. Runs even when an
# earlier step failed, so that the result output and the summary are always set.
#
# Inputs (environment): SCAN_WORK_DIR, CATEGORY, ANNOTATIONS, JOB_SUMMARY, FAIL_ON_SEVERITY,
# MAX_FINDINGS, FAILED_STEP (the first step that failed, empty when none did), UNIT_COUNT,
# PACKAGES_SCANNED, SARIF_FILE, HIGH, MEDIUM, LOW, SARIF_ID, ARTIFACT_NAME, ARTIFACT_ID,
# ARTIFACT_URL, GCS_SKIPPED, SONARQUBE_SKIPPED.
# Outputs: result, uploads.

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK="${SCAN_WORK_DIR:-}"
CATEGORY="$(trim "${CATEGORY:-bal-scan}")"
FAIL_ON="$(tr '[:upper:]' '[:lower:]' <<< "$(trim "${FAIL_ON_SEVERITY:-none}")")"
MAX="$(trim "${MAX_FINDINGS:-0}")"
[[ "$MAX" =~ ^[0-9]+$ ]] || MAX=0
# The merge step sets the counts whenever it succeeds, so missing counts mean it never finished,
# such as when the run was cancelled or timed out, which FAILED_STEP does not catch.
COUNTED=false
[ -n "${HIGH:-}" ] && [ -n "${MEDIUM:-}" ] && [ -n "${LOW:-}" ] && COUNTED=true
HIGH="${HIGH:-0}" MEDIUM="${MEDIUM:-0}" LOW="${LOW:-0}"

# Uploads: one entry per platform the findings were sent to.
UPLOADS='{}'
if [ -n "${SARIF_ID:-}" ]; then
  UPLOADS="$(jq -c --arg id "$SARIF_ID" '. + {"github-code-scanning": {"sarif-id": $id}}' <<< "$UPLOADS")"
fi
if [ -n "$WORK" ] && [ -f "$WORK/sonarqube-uploads.jsonl" ]; then
  SONAR_UPLOADS="$(jq -sc '.' "$WORK/sonarqube-uploads.jsonl")"
  if [ "$(jq 'length' <<< "$SONAR_UPLOADS")" -gt 0 ]; then
    UPLOADS="$(jq -c --argjson s "$SONAR_UPLOADS" '. + {sonarqube: $s}' <<< "$UPLOADS")"
  fi
fi
if [ -n "${ARTIFACT_ID:-}" ]; then
  UPLOADS="$(jq -c --arg name "${ARTIFACT_NAME:-}" --arg id "$ARTIFACT_ID" --arg url "${ARTIFACT_URL:-}" \
    '. + {artifact: {name: $name, id: $id, url: $url}}' <<< "$UPLOADS")"
fi
set_output uploads "$UPLOADS"

REASONS=()
if [ -n "${FAILED_STEP:-}" ]; then
  RESULT=error
  REASONS+=("The step failed while it was trying to ${FAILED_STEP}. See the step log for the errors.")
elif [ "${UNIT_COUNT:-0}" = "0" ]; then
  RESULT=skipped
  REASONS+=("No Ballerina package was found.")
elif [ "$COUNTED" != "true" ]; then
  RESULT=error
  REASONS+=("The findings were not counted, so the scan did not finish. The run may have been cancelled or timed out.")
else
  case "$FAIL_ON" in
    high) SELECTED=$HIGH ;;
    medium) SELECTED=$((HIGH + MEDIUM)) ;;
    low) SELECTED=$((HIGH + MEDIUM + LOW)) ;;
    *) SELECTED=0 ;;
  esac
  RESULT=passed
  if [ "$FAIL_ON" != "none" ] && [ "$SELECTED" -gt "$MAX" ]; then
    RESULT=failed
    if [ "$MAX" -eq 0 ]; then
      REASONS+=("Found $SELECTED finding(s) at or above $FAIL_ON severity; none are allowed.")
    else
      REASONS+=("Found $SELECTED finding(s) at or above $FAIL_ON severity; at most $MAX are allowed.")
    fi
  fi
fi
set_output result "$RESULT"

# Annotations on each counted finding.
if [ "$(trim "${ANNOTATIONS:-false}")" = "true" ] && [ -n "$WORK" ] && [ -f "$WORK/findings.json" ] && [ -z "${FAILED_STEP:-}" ]; then
  jq -r '.[] | [
      ({"high": "error", "medium": "warning", "low": "notice"}[.severity]),
      .file, (.line | tostring), ((."end-line" // .line) | tostring), .rule, .message
    ] | @tsv' "$WORK/findings.json" \
    | while IFS=$'\t' read -r level file line end_line rule message; do
        echo "::$level file=$(escape_property "$file"),line=$line,endLine=$end_line,title=$(escape_property "$rule")::$(escape_data "$message")"
      done
fi

if [ "$(trim "${JOB_SUMMARY:-true}")" = "true" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  case "$RESULT" in
    passed) ICON="✅" ;;
    failed) ICON="❌" ;;
    error) ICON="⚠️" ;;
    *) ICON="⏭️" ;;
  esac
  {
    echo "### $ICON bal scan: $CATEGORY"
    echo
    echo "**Result:** $RESULT"
    for r in "${REASONS[@]+"${REASONS[@]}"}"; do echo "- $r"; done
    if [ "$RESULT" = "passed" ] || [ "$RESULT" = "failed" ]; then
      echo
      echo "| Severity | Findings |"
      echo "| --- | ---: |"
      echo "| High | $HIGH |"
      echo "| Medium | $MEDIUM |"
      echo "| Low | $LOW |"
      echo
      GATE="off"
      [ "$FAIL_ON" != "none" ] && GATE="fail on more than $MAX finding(s) at or above $FAIL_ON severity"
      echo "Packages scanned: ${PACKAGES_SCANNED:-0}. Gate: $GATE."
    fi
    if [ "$(jq 'length' <<< "$UPLOADS")" -gt 0 ]; then
      echo
      jq -r '
        (if has("github-code-scanning") then "- Uploaded to GitHub code scanning." else empty end),
        (.sonarqube[]? | "- Reported \(.package) to SonarQube project `\(."project-key")`"
          + (if ."dashboard-url" != "" then ": [dashboard](\(."dashboard-url"))" else "" end) + "."),
        (.artifact // empty | "- Saved the reports as the artifact "
          + (if .url != "" then "[`\(.name)`](\(.url))" else "`\(.name)`" end) + ".")
      ' <<< "$UPLOADS"
    fi
    if [ "${GCS_SKIPPED:-false}" = "true" ] || [ "${SONARQUBE_SKIPPED:-false}" = "true" ]; then
      echo
    fi
    if [ "${GCS_SKIPPED:-false}" = "true" ]; then
      echo "- The upload to GitHub code scanning was skipped: pull requests from forks or Dependabot get a read-only \`GITHUB_TOKEN\`. The SARIF file is kept as the \`sarif-file\` output, and \`artifacts: sarif\` saves it as an artifact."
    fi
    if [ "${SONARQUBE_SKIPPED:-false}" = "true" ]; then
      echo "- SonarQube was skipped: secrets are not available to pull requests from forks or Dependabot."
    fi
    echo
  } >> "$GITHUB_STEP_SUMMARY"
fi

case "$RESULT" in
  failed)
    for r in "${REASONS[@]}"; do log_error "$r"; done
    exit 1
    ;;
  passed) echo "bal scan '$CATEGORY' passed." ;;
  skipped) echo "bal scan '$CATEGORY' was skipped: no Ballerina package was found." ;;
esac
