[![Test](https://github.com/ballerina-platform/scan-ballerina/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/ballerina-platform/scan-ballerina/actions/workflows/test.yml)
[![GitHub license](https://img.shields.io/github/license/ballerina-platform/scan-ballerina)](https://github.com/ballerina-platform/scan-ballerina/blob/main/LICENSE)
[![GitHub issues](https://img.shields.io/github/issues/ballerina-platform/scan-ballerina)](https://github.com/ballerina-platform/scan-ballerina/issues)

# Scan Ballerina

GitHub Action that runs [`bal scan`](https://ballerina.io/learn/static-code-analysis/) on the Ballerina packages in a repository and sends the findings to the code scanning tool you use: GitHub code scanning, SonarQube, or any other platform that reads SARIF.

The action installs Ballerina and the scan tool, scans every package, and merges the reports into one SARIF 2.1.0 file with paths relative to the repository root. It leaves your files as they were: any file it changes during a scan is restored when that scan ends.

## Usage

### GitHub code scanning

```yaml
jobs:
  scan:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      security-events: write
      actions: read # Only needed in private repositories
    steps:
      - uses: actions/checkout@v4
      - uses: ballerina-platform/scan-ballerina@v1
        with:
          platforms: github-code-scanning
```

### SonarQube

The SonarQube server needs the Ballerina language plugin. The action installs the SonarScanner CLI, with its own Java runtime, and the scan tool's SonarQube platform plugin, and passes the server URL, token and project key to the scan:

```yaml
permissions:
  contents: read
  packages: read # The platform plugin is downloaded from GitHub Packages
steps:
  - uses: actions/checkout@v4
    with:
      fetch-depth: 0 # SonarQube needs history for blame and new-code detection
  - uses: ballerina-platform/scan-ballerina@v1
    with:
      platforms: sonarqube
      platform-config: |
        sonarqube:
          host-url: ${{ vars.SONAR_HOST_URL }}
          token: ${{ secrets.SONAR_TOKEN }}
          project-key: my-project
```

Settings left out of `platform-config` are read from the package's `sonar-project.properties`. See [Platform configuration](#platform-configuration).

### Any other SARIF consumer

```yaml
steps:
  - uses: actions/checkout@v4
  - id: scan
    uses: ballerina-platform/scan-ballerina@v1
  - run: ./upload-to-defectdojo.sh "${{ steps.scan.outputs.sarif-file }}"
```

### Save the reports as an artifact

```yaml
- uses: ballerina-platform/scan-ballerina@v1
  with:
    artifacts: sarif,ballerina
```

The action uploads one workflow artifact, named after `category`, with the reports you list:

- `sarif`: the merged SARIF file, as `<category>.sarif`.
- `ballerina`: the JSON report `bal scan` writes for each package or workspace, as `<package path>/scan_results.json`. It takes a second `bal scan` run per package. These reports are as `bal scan` wrote them, so `exclude-tests` and file globs in `exclude-paths` are not applied.

Artifact names are unique within a workflow run, so give each scan its own `category`, including each job of a matrix. Saving the artifact needs no extra permissions, so it also works in pull requests from forks.

### Gate on findings

```yaml
- uses: ballerina-platform/scan-ballerina@v1
  with:
    platforms: github-code-scanning
    fail-on-severity: medium # Fail on medium or high findings
    max-findings: 5          # ...when there are more than five of them
```

The findings are uploaded before the gate is applied, so they reach the platforms even when the gate fails.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `ballerina-version` | `latest` | Ballerina version to install when Ballerina is not already installed. Pin a version for reproducible runs. |
| `tool-version` | pinned per release | `bal scan` tool version. |
| `platforms` | empty | Comma separated platforms to send the findings to: `github-code-scanning`, `sonarqube`. Empty produces the SARIF file only. |
| `paths` | `.` | Newline or comma separated paths to scan. Every package and workspace in these paths, including their subdirectories, is scanned, and their findings are merged into one SARIF file. A path that does not exist fails the step. |
| `exclude-paths` | empty | Newline or comma separated globs, relative to the repository root, for packages and files to leave out. A directory excludes everything below it. `*` stays within one directory and `**` crosses directories. |
| `exclude-tests` | `true` | Drop findings in `tests/` and `modules/*/tests/`. |
| `category` | `bal-scan` | Name for this scan. Labels the uploaded findings, the job summary and messages. Use a different one for each scan in a job. |
| `include-rules` | empty | Comma separated rule IDs to report, such as `ballerina:1,ballerina/crypto:1`. Empty reports every rule. |
| `exclude-rules` | empty | Comma separated rule IDs to leave out, such as `ballerina:1,ballerina:10`. Cannot be combined with `include-rules`. |
| `fail-on-severity` | `none` | Fail when findings are at or above `low`, `medium` or `high`. `none` turns the gate off. |
| `max-findings` | `0` | Findings at or above `fail-on-severity` allowed before the step fails. |
| `annotations` | `false` | Show each counted finding as a file and line annotation. |
| `job-summary` | `true` | Write the result and the high, medium and low counts to the job summary. |
| `artifacts` | empty | Comma separated reports to save as a workflow artifact named after `category`: `sarif` for the merged SARIF file, `ballerina` for the JSON report `bal scan` writes for each package. Empty saves nothing. See [Save the reports as an artifact](#save-the-reports-as-an-artifact). |
| `platform-config` | empty | YAML mapping, keyed by platform, with the settings and credentials each selected platform needs. JSON is accepted. |
| `github-token` | `github.token` | Token for installing Ballerina, downloading the SonarQube platform plugin from GitHub Packages and uploading to code scanning. |

## Platform configuration

`platform-config` holds the settings of every selected platform. Each top-level key is a platform, and its value is that platform's settings. An unknown platform or field fails the step, so a typo such as `tokn` is caught.

```yaml
platform-config: |
  sonarqube:
    host-url: https://sonar.example.com
    token: ${{ secrets.SONAR_TOKEN }}
    packages:
      - path: services/orders
        project-key: orders
        project-name: Orders Service
      - path: services/payments
        host-url: https://sonar.payments.example.com
        token: ${{ secrets.PAYMENTS_SONAR_TOKEN }}
        project-key: payments
```

`github-code-scanning` takes no settings.

### `sonarqube`

The fields at the platform level are the defaults for every scanned package. An item under `packages` can set any of them for one package, including its own `host-url` and `token`, so packages in one repository can report to different SonarQube servers or organizations.

| Field | Required | Description |
| --- | --- | --- |
| `plugin-path` | No | Platform plugin JAR, as a path relative to the repository root or an `https` URL. Overrides `path` in `Scan.toml`. Cannot be used with `plugin-version`. |
| `plugin-version` | No | Platform plugin version to download, or `latest`. Overrides `path` in `Scan.toml`. `latest` warns, since it may not match the pinned scan tool. |
| `properties-file` | No | Properties file, relative to the repository root. Overrides `sonarProjectPropertiesPath` in `Scan.toml`. |
| `host-url` | Yes, unless set under `packages` or in the properties file | SonarQube server URL. Must be `https`. Overrides `sonar.host.url`. |
| `token` | Yes, unless set under `packages` | Token for submitting analyses. Pass it from a secret. |
| `project-key` | Yes, unless set under `packages` or in the properties file | Project key. Overrides `sonar.projectKey`. At the platform level, only when one package has no `project-key` of its own. |
| `project-name` | No | Project name. Overrides `sonar.projectName`. At the platform level, only when one package has no `project-key` of its own. |
| `packages` | No | Per-package settings. Each item has a `path`, relative to the repository root, and any of the fields above. Platform level only. |

Each setting of a package is resolved field by field: its `packages` item, then the platform level, then the package's `Scan.toml` and properties file. Paths in `platform-config` are relative to the repository root, and paths in `Scan.toml` are relative to the package.

- **Platform plugin:** `plugin-path` or `plugin-version`, otherwise the `path` of the `sonarqube` `[[platform]]` entry in `Scan.toml` (a relative path or an `https` URL), otherwise the version this release pins. An absolute path fails, since it points to one machine. A `plugin-path` or `plugin-version` in an item replaces both platform-level fields.
- **Properties file:** `properties-file`, otherwise `sonarProjectPropertiesPath` in `Scan.toml`, otherwise `sonar-project.properties` in the package root, if it exists.
- **Server and token:** an item that sets `host-url` must also set `token`, so a token is never sent to a server it was not configured for. Every URL must be `https`, including one from the properties file.
- **Project:** each package is a separate SonarQube analysis, so packages on the same server need different project keys.

The platform plugin is published to GitHub Packages, which needs a token with `read:packages` even for public packages. Give the job `packages: read`, or set `plugin-path` to a JAR in the repository or an `https` URL.

The action passes the settings to SonarScanner through the `SONAR_HOST_URL`, `SONAR_TOKEN` and `SONAR_SCANNER_JSON_PARAMS` environment variables of each package's `bal scan` process, never on the command line. SonarScanner gives them precedence over the properties file, and keeps the file's other settings.

Pull requests from forks or Dependabot get no secrets and a read-only `GITHUB_TOKEN`. In such a run, the action skips SonarQube with a warning when a token is empty, skips the upload to code scanning with a warning, and still produces the SARIF file. Save it with `artifacts: sarif` and upload it from a trusted `workflow_run` workflow.

SonarQube receives each package's findings before the `exclude-tests` and `exclude-paths` filters are applied. Use `sonar.exclusions` and `sonar.test.inclusions` to keep the same files out of SonarQube.

## Outputs

| Output | Description |
| --- | --- |
| `result` | `passed` or `failed` from the gate, `skipped` when no package was found, or `error` when the step failed before the gate. |
| `sarif-file` | The merged, normalized SARIF file. Empty when no package was found or a scan failed. |
| `high-count`, `medium-count`, `low-count`, `total-count` | Counted findings, after the test and path filters. `total-count` does not include `INFO` findings. |
| `packages-scanned` | Number of packages scanned. |
| `uploads` | JSON object with one entry per platform the findings were sent to, and an `artifact` entry when reports were saved as an artifact, such as `{"github-code-scanning": {"sarif-id": "…"}, "sonarqube": [{"package": "…", "project-key": "…", "dashboard-url": "…", "task-id": "…"}], "artifact": {"name": "…", "id": "…", "url": "…"}}`. `{}` when nothing was uploaded. |

Read a value from `uploads` with `fromJSON(steps.scan.outputs.uploads)['github-code-scanning']['sarif-id']`.

## Severity

| Ballerina severity | SARIF `level` | Action severity |
| --- | --- | --- |
| `BLOCKER`, `HIGH` | `error` | `high` |
| `MEDIUM` | `warning` | `medium` |
| `LOW` | `note` | `low` |
| `INFO` | `none` | Not counted |

A result without a `level` takes its rule's default level, and `warning` when the rule has none either.

## Failure behaviour

Findings never fail the step unless you set `fail-on-severity`. Problems with the setup or the scan do.

| Situation | Result |
| --- | --- |
| Invalid input, or a path that does not exist | Fails before packages are searched or anything is downloaded |
| Missing or invalid SonarQube settings, missing or duplicate project keys, or a `packages` item that matches no package or repeats a path | Fails after packages are found, before anything is downloaded |
| No package found | Passes with a warning, result `skipped` |
| `bal scan` fails for a package, including when SonarQube is unreachable or rejects the analysis | The other packages are still scanned, then the step fails without a SARIF file |
| Upload to code scanning fails | Fails, after the SARIF file is written |
| Saving the artifact fails, such as when another scan in the run used the same `category` | Fails, after the findings are uploaded |
| Findings over the gate | Fails, after the SARIF file is written and uploaded |
| Fork or Dependabot pull request with an empty SonarQube token | Skips SonarQube with a warning, and still produces the SARIF file |
| Fork or Dependabot pull request with `github-code-scanning` | Skips the upload with a warning, and keeps the SARIF file as the `sarif-file` output and in the artifact, when `artifacts` has `sarif` |

## How it works

The action is a composite action. Its logic is in the shell and `jq` scripts in [`scripts/`](scripts), which read their inputs from environment variables and can be run locally:

1. `validate.sh` checks the inputs.
2. `find-packages.sh` finds the packages and workspaces in `paths`, skipping `target`, `build` and `.git`. A workspace is scanned once from its root.
3. `check-sonarqube.sh` resolves each package's SonarQube settings.
4. [`setup-ballerina`](https://github.com/ballerina-platform/setup-ballerina) installs Ballerina, unless `bal` is already on the path.
5. `install-scan-tool.sh` installs the scan tool, unless that version is already active. With SonarQube, `install-sonarqube.sh` downloads the platform plugin and the SonarScanner CLI, once per job.
6. `scan.sh` runs `bal scan --format=sarif` on each package, with `artifacts: ballerina` also `bal scan --format=json`, and with SonarQube `bal scan --platforms=sonarqube`.
7. `merge-sarif.sh` normalizes the paths, drops filtered findings and merges the reports into one run.
8. `github/codeql-action/upload-sarif` uploads the SARIF file to code scanning.
9. `collect-artifacts.sh` gathers the reports listed in `artifacts`, and `actions/upload-artifact` saves them, also when an earlier step failed.
10. `report.sh` writes the annotations and the job summary, and applies the gate.

The scan tool does not write a SARIF report while any `[[platform]]` entry in `Scan.toml` is active. When a package's `Scan.toml` has such entries, `scan.sh` hides them during the SARIF and JSON scans only, and restores the file byte for byte as soon as that scan ends, including when it fails.

The scan tool reads the platform plugin only from `Scan.toml`. For the SonarQube scan, `scan.sh` points the package's `sonarqube` `[[platform]]` entry to the resolved plugin, keeping the rest of the file, or creates a `Scan.toml` when the package has none. The file is restored, or deleted, as soon as that scan ends. A remote `Scan.toml`, set with `[scan] configPath` in `Ballerina.toml`, cannot be changed, so its `sonarqube` entry is used as is.

The action needs `jq` and `yq` (v4), which GitHub-hosted runners provide. It runs on Ubuntu, macOS and Windows runners.

## Security

- `setup-ballerina`, `upload-sarif` and `upload-artifact` are pinned by commit SHA, and the scan tool and the SonarQube platform plugin by version. The SonarScanner CLI is downloaded from SonarSource at a pinned version, and its SHA-256 is verified.
- Inputs reach the scripts as environment variables and are never interpolated into scripts.
- Every `token` in `platform-config`, at the platform level and under each `packages` item, is masked, and `platform-config` is never printed. Each package's token goes to that package's scan only.
- The action needs only `contents: read`. With `github-code-scanning`, it also needs `security-events: write`, and `actions: read` in private repositories. With `sonarqube` and the default plugin, it also needs `packages: read`.

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE).
