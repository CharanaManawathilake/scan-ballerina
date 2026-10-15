#!/usr/bin/env bash
# Step 9: gathers the reports the artifacts input names into one directory, which the next step
# uploads as a workflow artifact. Runs even when an earlier step failed, so that the reports that
# were written are still saved.
#
# The artifact holds <category>.sarif, the merged SARIF file, for sarif, and
# <package path>/scan_results.json, the report bal scan wrote for each package or workspace, for
# ballerina.
#
# Inputs (environment): SCAN_WORK_DIR, ARTIFACTS, SARIF_FILE, CATEGORY.
# Outputs: path, the directory to upload, empty when there is nothing to upload.

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK="${SCAN_WORK_DIR:?SCAN_WORK_DIR is not set}"
OUT="$WORK/artifact"
rm -rf "$OUT"
mkdir -p "$OUT"

wanted() { [[ ",${ARTIFACTS:-}," == *,"$1",* ]]; }

if wanted sarif && [ -n "${SARIF_FILE:-}" ]; then
  SARIF="$(to_unix_path "$SARIF_FILE")"
  [ -f "$SARIF" ] && cp "$SARIF" "$OUT/"
fi

if wanted ballerina && [ -d "$WORK/ballerina" ]; then
  cp -R "$WORK/ballerina/." "$OUT/"
fi

FILES="$(find "$OUT" -type f | wc -l | tr -d ' ')"
if [ "$FILES" -eq 0 ]; then
  echo "No report to save as an artifact."
  set_output path ""
  exit 0
fi

echo "Reports to save as an artifact:"
(cd "$OUT" && find . -type f | sed 's|^\./|  |' | sort)
OUT_NATIVE="$OUT"
command -v cygpath > /dev/null 2>&1 && OUT_NATIVE="$(cygpath -w "$OUT")"
set_output path "$OUT_NATIVE"
