#!/usr/bin/env bash
# Prints the annotations of a job in the current workflow run as a JSON array.
#
# Annotations reach the check run only after the job has finished, so run this from a job that
# needs it.
#
# Usage: annotations.sh <job name>
# Environment: GH_TOKEN, with actions: read and checks: read.

set -euo pipefail

JOB_NAME="$1"

JOBS="repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT/jobs"
CHECK_RUN_URL="$(gh api --paginate "$JOBS" \
  | jq -r --arg name "$JOB_NAME" '.jobs[] | select(.name == $name) | .check_run_url' | head -n1)"
if [ -z "$CHECK_RUN_URL" ]; then
  echo "::error::Could not find the check run of the '$JOB_NAME' job." >&2
  exit 1
fi

gh api --paginate "${CHECK_RUN_URL#https://api.github.com/}/annotations" | jq -sc 'add // []'
