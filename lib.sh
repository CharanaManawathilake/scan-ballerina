# shellcheck shell=bash disable=SC2034
# Shared helpers for the scan-ballerina scripts. Sourced, not executed.
#
# The scripts read their inputs from environment variables and keep their state in the work
# directory, so they can be run locally as well as from action.yml:
#   SCAN_WORK_DIR       Work directory of this run (created by validate.sh).
#   GITHUB_WORKSPACE    Repository root. Defaults to the current directory.
#   GITHUB_OUTPUT       File the step outputs are written to. Defaults to stdout.

set -euo pipefail

# The scan tool version an action release pins, and the oldest Ballerina distribution it runs on.
PINNED_TOOL_VERSION="0.12.0"
MIN_BALLERINA_VERSION="2201.13.2"

# The SonarQube platform plugin of the scan tool, published to GitHub Packages, which needs a token
# with read:packages even for public packages.
PINNED_SONAR_PLUGIN_VERSION="0.3.0"
SONAR_PLUGIN_URL="https://maven.pkg.github.com/ballerina-platform/sonar-ballerina/io/ballerina/sonar/sonar-platform-plugin/{version}/sonar-platform-plugin-{version}.jar"

# The SonarScanner CLI an action release pins, with the SHA-256 of each distribution. Each one
# bundles its own Java runtime.
PINNED_SONAR_SCANNER_VERSION="8.1.0.6389"
sonar_scanner_sha256() {
  case "$1" in
    linux-x64) echo bb8f709f9cb73352f8d1260a3b3c506c0f41146754bc630762c126d795499d0b ;;
    linux-aarch64) echo 5e1c9328f4e261838de778c9e586ee608cca45ff7f0538108642219214628ba5 ;;
    windows-x64) echo 73f0e71928673d5b2f39bb86213342a30e51a14c8eec345164016bb29c8df8ee ;;
    macosx-x64) echo 8afc8bbff9008434e53b31cb681333ff643b999f84ca537db573d0fae8883cdc ;;
    macosx-aarch64) echo 20d12be4081896b337cd873d98ebd3d554be666086a45e31dd84a12ef51c3688 ;;
    *) return 1 ;;
  esac
}

KNOWN_PLATFORMS=(github-code-scanning sonarqube)

# jq on Windows ends lines with CRLF, which 'read' keeps. JSON escapes CRs inside strings, so
# dropping every CR is safe; pipefail keeps jq's exit code.
if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
  jq() { command jq "$@" | tr -d '\r'; }
fi

# GitHub workflow commands. Values are escaped so that they cannot inject other commands.
escape_data() {
  local s="$1"
  s="${s//'%'/'%25'}"
  s="${s//$'\r'/'%0D'}"
  s="${s//$'\n'/'%0A'}"
  printf '%s' "$s"
}

escape_property() {
  local s
  s="$(escape_data "$1")"
  s="${s//':'/'%3A'}"
  s="${s//','/'%2C'}"
  printf '%s' "$s"
}

log_error() { echo "::error title=bal scan ($(escape_property "${CATEGORY:-bal-scan}"))::$(escape_data "$1")"; }
log_warning() { echo "::warning title=bal scan ($(escape_property "${CATEGORY:-bal-scan}"))::$(escape_data "$1")"; }
log_notice() { echo "::notice title=bal scan ($(escape_property "${CATEGORY:-bal-scan}"))::$(escape_data "$1")"; }

die() {
  log_error "$1"
  exit 1
}

# Writes a step output. Multi-line values use the heredoc form.
set_output() {
  local name="$1" value="$2" out="${GITHUB_OUTPUT:-/dev/stdout}"
  if [[ "$value" == *$'\n'* ]]; then
    local delim="EOF_$RANDOM$RANDOM"
    printf '%s<<%s\n%s\n%s\n' "$name" "$delim" "$value" "$delim" >> "$out"
  else
    printf '%s=%s\n' "$name" "$value" >> "$out"
  fi
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Splits a newline or comma separated list into one trimmed, non-empty item per line.
split_list() {
  local item
  tr ',' '\n' <<< "$1" | tr -d '\r' | while IFS= read -r item || [ -n "$item" ]; do
    item="$(trim "$item")"
    [ -n "$item" ] && printf '%s\n' "$item"
  done
  return 0
}

require_command() {
  command -v "$1" > /dev/null 2>&1 || die "'$1' is required on the runner but was not found on the path. $2"
}

# Converts a Windows path to the form bash uses, so paths can be compared on every runner.
to_unix_path() {
  if [ -n "$1" ] && command -v cygpath > /dev/null 2>&1; then
    cygpath -u "$1"
  else
    printf '%s' "$1"
  fi
}

workspace_root() {
  local root
  root="$(to_unix_path "${GITHUB_WORKSPACE:-$PWD}")"
  (cd "$root" && pwd -P)
}

# Prints the path of an existing directory relative to the repository root, "." for the root
# itself. Fails when the directory is outside the repository.
repo_relative_dir() {
  local root abs
  root="$(workspace_root)"
  abs="$(cd "$root" && cd "$1" && pwd -P)" || return 1
  if [ "$abs" = "$root" ]; then
    printf '.'
  elif [[ "$abs" == "$root"/* ]]; then
    printf '%s' "${abs#"$root"/}"
  else
    return 1
  fi
}

# Runs the bal command. On Windows runners it is bal.bat, which bash does not find as "bal".
bal_cmd() {
  if command -v bal > /dev/null 2>&1; then
    bal "$@"
  else
    bal.bat "$@"
  fi
}

has_bal() {
  command -v bal > /dev/null 2>&1 || command -v bal.bat > /dev/null 2>&1
}

has_command() {
  command -v "$1" > /dev/null 2>&1 || command -v "$1.bat" > /dev/null 2>&1 || command -v "$1.cmd" > /dev/null 2>&1
}

# Succeeds when version $1 is greater than or equal to version $2. Compares the leading numeric
# dot-separated parts, so 2201.13.2-20261001 compares as 2201.13.2.
version_ge() {
  local a b i
  IFS=. read -ra a <<< "$(sed -E 's/^([0-9]+(\.[0-9]+)*).*/\1/' <<< "$1")"
  IFS=. read -ra b <<< "$(sed -E 's/^([0-9]+(\.[0-9]+)*).*/\1/' <<< "$2")"
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    local x="${a[i]:-0}" y="${b[i]:-0}"
    ((10#$x > 10#$y)) && return 0
    ((10#$x < 10#$y)) && return 1
  done
  return 0
}

# Parses the platform-config input (YAML or JSON) and prints it as compact JSON, "{}" when empty.
# Fails without printing anything when it is not valid YAML, since the parser's error can quote
# credentials.
platform_config_json() {
  if [ -z "$(trim "${PLATFORM_CONFIG:-}")" ]; then
    echo '{}'
    return
  fi
  local json
  json="$(yq -p yaml -o json -I0 '.' <<< "$PLATFORM_CONFIG" 2> /dev/null)" || return 1
  [ -z "$json" ] || [ "$json" = "null" ] && json='{}'
  printf '%s' "$json"
}

INVALID_PLATFORM_CONFIG="platform-config is not valid YAML. Give a mapping keyed by platform, such as 'sonarqube:'."

# Prints the Scan.toml file a package's scan reads, empty when there is none, or the URL when
# Ballerina.toml points [scan] configPath to a remote file. $1 is the package directory.
scan_toml_path() {
  local pkg="$1" config
  config="$(yq -p toml -o json -I0 '.scan.configPath // ""' "$pkg/Ballerina.toml" 2> /dev/null || true)"
  config="$(jq -r '.' <<< "${config:-\"\"}" 2> /dev/null || true)"
  if [ -z "$config" ]; then
    [ -f "$pkg/Scan.toml" ] && printf '%s' "$pkg/Scan.toml"
    return 0
  fi
  if [[ "$config" =~ ^https?:// ]]; then
    printf '%s' "$config"
  elif [[ "$config" = /* || "$config" =~ ^[A-Za-z]:[/\\] ]]; then
    printf '%s' "$(to_unix_path "$config")"
  else
    printf '%s' "$pkg/$config"
  fi
}

# Prints the [[platform]] entries of a Scan.toml file as a JSON array.
scan_toml_platforms() {
  local file="$1" json
  if [[ "$file" =~ ^https?:// ]]; then
    json="$(curl -fsSL "$file" | yq -p toml -o json -I0 '.platform // []' 2> /dev/null)" || return 1
  else
    json="$(yq -p toml -o json -I0 '.platform // []' "$file" 2> /dev/null)" || return 1
  fi
  printf '%s' "$json"
}

# Reads a key from a Java properties file. Handles '=' and ':' separators and surrounding spaces.
read_property() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  awk -v key="$key" '
    { sub(/\r$/, "") }
    /^[ \t]*[#!]/ { next }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (match(line, /[ \t]*[=:][ \t]*/)) {
        k = substr(line, 1, RSTART - 1)
        v = substr(line, RSTART + RLENGTH)
        if (k == key) { value = v }
      }
    }
    END { if (value != "") print value }
  ' "$file"
}

# Converts a path to the form the runner's native programs, such as bal and Java, read. On Windows
# runners that is C:/..., which TOML and JSON strings take without escaping.
to_native_path() {
  if [ -n "$1" ] && command -v cygpath > /dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}

# Succeeds when a path is absolute, on any runner.
is_absolute_path() {
  [[ "$1" = /* || "$1" =~ ^[A-Za-z]:[/\\] ]]
}

# Prints the SHA-256 of a file.
sha256_of() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Cache shared by every run of the action in a job, so tools are downloaded only once.
tool_cache_dir() {
  local dir
  dir="$(to_unix_path "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")/scan-ballerina-tools"
  mkdir -p "$dir"
  printf '%s' "$dir"
}
