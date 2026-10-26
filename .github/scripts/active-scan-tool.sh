#!/usr/bin/env bash
# Prints the active bal scan version, or nothing when none is installed.

# shellcheck source=../../scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib.sh"

active_tool_version
