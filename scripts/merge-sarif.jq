# Merges normalized bal scan SARIF reports (slurped) into one run, and fills in what GitHub code
# scanning renders. GitHub accepts one run per category, so all packages share a run: rules are
# deduplicated by ID and each result's ruleIndex is recomputed. The run.artifacts of the reports
# are concatenated, so each artifactLocation.index is moved by the number of artifacts of the
# runs before its own.

def owasp_2025: {
  "A01": "Broken Access Control",
  "A02": "Security Misconfiguration",
  "A03": "Software Supply Chain Failures",
  "A04": "Cryptographic Failures",
  "A05": "Injection",
  "A06": "Insecure Design",
  "A07": "Authentication Failures",
  "A08": "Software or Data Integrity Failures",
  "A09": "Security Logging and Alerting Failures",
  "A10": "Mishandling of Exceptional Conditions"
};

def rule_kinds: {"VULNERABILITY": "Vulnerability", "CODE_SMELL": "Code smell", "BUG": "Bug"};

def cwe_links:
  [.properties.tags[]? | capture("^external/cwe/cwe-0*(?<id>[0-9]+)$")
    | "[CWE-\(.id)](https://cwe.mitre.org/data/definitions/\(.id).html)"];

def owasp_links:
  [.properties.tags[]? | capture("^external/owasp/owasp-(?<cat>a[0-9]{2})-(?<year>[0-9]{4})$")
    | (.cat | ascii_upcase) as $cat
    | if .year == "2025" and owasp_2025[$cat] then
        "[\($cat):2025 – \(owasp_2025[$cat])](https://top10.owasp.org/2025/\($cat)_2025-\(owasp_2025[$cat] | gsub(" "; "_"))/)"
      else "\($cat):\(.year)" end];

def plain_tags:
  [.properties.tags[]? | select(startswith("external/") or . == "security" or . == "maintainability" | not) | "`\(.)`"];

def help_markdown($desc):
  [
    $desc,
    "",
    "- **Rule:** `\(.id)`",
    (rule_kinds[.properties.ruleKind // ""] // empty | "- **Type:** \(.)"),
    (cwe_links | select(length > 0) | "- **CWE:** \(join(", "))"),
    (owasp_links | select(length > 0) | "- **OWASP Top 10:** \(join(", "))"),
    (plain_tags | select(length > 0) | "- **Tags:** \(join(" "))"),
    (.helpUri // empty | "", "[Rule documentation](\(.))")
  ] | join("\n");

# bal scan up to 0.12.x reports the rule's title as every result's message, not one about the finding.
def generic_messages:
  (.semanticVersion // "" | capture("^(?<major>[0-9]+)\\.(?<minor>[0-9]+)") | [(.major | tonumber), (.minor | tonumber)] <= [0, 12])
  // false;

def enrich:
  (.fullDescription.text // .shortDescription.text // .id) as $desc
  | .help //= {text: $desc, markdown: help_markdown($desc)}
  | .fullDescription //= {text: $desc}
  | if .properties.ruleKind == "VULNERABILITY" then .properties.tags = (((.properties.tags // []) + ["security"]) | unique)
    elif .properties.ruleKind == "CODE_SMELL" then .properties.tags = (((.properties.tags // []) + ["maintainability"]) | unique)
    else . end;

def shift_index($offset):
  if (.physicalLocation.artifactLocation.index | type) == "number"
  then .physicalLocation.artifactLocation.index += $offset else . end;

def shift_indexes($offset):
  (if .locations then .locations |= map(shift_index($offset)) else . end)
  | (if .relatedLocations then .relatedLocations |= map(shift_index($offset)) else . end);

. as $all
| ($all | map(.runs[]?)) as $runs
| ($runs | map(.artifacts // [] | length)) as $artifact_counts
| ($runs | map(.artifacts[]?)) as $artifacts
| ($runs[0].tool.driver | generic_messages) as $generic
| ($runs | map(.tool.driver.rules[]?) | unique_by(.id)) as $tool_rules
| ($tool_rules | map(select(.fullDescription.text) | {key: .id, value: .fullDescription.text}) | from_entries) as $descriptions
| ($tool_rules | map(enrich)) as $rules
| ($rules | to_entries | map({key: .value.id, value: .key}) | from_entries) as $index
| {
    "$schema": ($all[0]["$schema"] // "https://json.schemastore.org/sarif-2.1.0.json"),
    version: "2.1.0",
    runs: [{
      tool: (($runs[0].tool // {driver: {name: "Ballerina Scan Tool"}}) | .driver.rules = $rules)
    }
    + (if ($artifacts | length) > 0 then {artifacts: $artifacts} else {} end)
    + {
      results: ([range(0; $runs | length) as $i
          | ($artifact_counts[:$i] | add // 0) as $offset
          | $runs[$i].results[]? | shift_indexes($offset)] | map(
        .ruleId as $id
        | .ruleIndex = $index[$id]
        | if .ruleIndex == null then del(.ruleIndex) else . end
        | if $generic and $descriptions[$id] then .message.text = $descriptions[$id] else . end
      ))
    }]
  }
