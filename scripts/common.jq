# jq definitions shared by the scan-ballerina scripts. Load with: jq -L <scripts dir> 'include "common"; ...'

# Converts an exclude-paths glob into an anchored regex. "*" and "?" stay within one directory,
# "**" crosses directories, and a match also covers everything below it.
def glob_regex:
  sub("^\\./"; "") | sub("/+$"; "")
  | gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)")
  | gsub("\\*\\*/"; "\u0001") | gsub("\\*\\*"; "\u0002")
  | gsub("\\*"; "[^/]*") | gsub("\\?"; "[^/]")
  | gsub("\u0001"; "(.*/)?") | gsub("\u0002"; ".*")
  | "^\(.)(/.*)?$";

# True when the repository-relative path matches any of the globs.
def excluded($globs):
  . as $path | any($globs[]; . as $glob | $path | test($glob | glob_regex));

# Joins a directory relative to the repository root, where "." is the root, with a relative path.
def join_path($dir; $path):
  if $dir == "." or $dir == "" then $path else "\($dir)/\($path)" end;

# Escapes a string for use inside a regex.
def regex_escape:
  gsub("(?<c>[.+*?^$(){}|\\[\\]\\\\])"; "\\\(.c)");

# The action severity of a SARIF result: high, medium, low, or none when it is not counted.
# A result without a level takes its rule's default level, and warning when there is none.
def severity($rules):
  (.ruleId as $id | ($rules | map(select(.id == $id)) | first // {}) | .defaultConfiguration.level) as $default
  | {"error": "high", "warning": "medium", "note": "low"}[.level // $default // "warning"] // "none";
