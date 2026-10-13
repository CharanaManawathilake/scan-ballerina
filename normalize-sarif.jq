# Normalizes the SARIF report of one package or workspace.
#
# Arguments:
#   $prefix         The unit's directory relative to the repository root, "." for the root.
#   $packages       Package roots relative to the unit, "" for the unit itself, used to find tests.
#   $exclude_tests  Drop findings in tests/ and modules/*/tests/ of each package.
#   $excludes       exclude-paths globs, relative to the repository root.
#
# Makes each artifactLocation.uri relative to the repository root, then drops the findings in
# test sources and excluded files.

include "common";

def absolute: test("^(/|[A-Za-z][A-Za-z0-9+.-]*:)");

def repo_uri:
  if absolute then . else sub("^\\./"; "") as $uri | join_path($prefix; $uri) end;

def test_source:
  . as $uri
  | any($packages[]; . as $pkg
      | $uri | test("^\(if $pkg == "" then "" else ($pkg | regex_escape) + "/" end)(modules/[^/]+/)?tests/"));

def uris: [.locations[]?.physicalLocation.artifactLocation.uri | select(type == "string")];

.runs |= map(
  .results |= map(
    select(($exclude_tests | not) or (uris | any(test_source) | not))
    | (.locations[]?.physicalLocation.artifactLocation.uri | select(type == "string")) |= repo_uri
    | select(uris | any(excluded($excludes)) | not)
  )
)
