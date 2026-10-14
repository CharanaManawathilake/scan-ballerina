#!/usr/bin/env bash
# Prints the annotations of a job in the current workflow run as a JSON array.
#
# Annotations can take a moment to reach the check run, so it waits up to a minute for the array
# to match a jq condition.
#
# Usage: annotations.sh <job name> <jq condition on the array of annotations>
# Environment: GH_TOKEN, with actions: read and checks: read.

set -euo pipefail

JOB_NAME="$1"
CONDITION="$2"

JOBS="repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT/jobs"
CHECK_RUN_URL="$(gh api --paginate "$JOBS" \
  | jq -r --arg name "$JOB_NAME" '.jobs[] | select(.name == $name) | .check_run_url' | head -n1)"
if [ -z "$CHECK_RUN_URL" ]; then
  echo "::error::Could not find the check run of the '$JOB_NAME' job." >&2
  exit 1
fi

for _ in $(seq 1 12); do
  ANNOTATIONS="$(gh api --paginate "${CHECK_RUN_URL#https://api.github.com/}/annotations" | jq -sc 'add // []')"
  jq -e "$CONDITION" <<< "$ANNOTATIONS" > /dev/null && break
  sleep 5
done
printf '%s\n' "$ANNOTATIONS"
