---
title: CLI Commands
description: Complete reference for every nfw CLI command, option, and flag.
---

The `nfw` CLI is the primary entry point for workspace and service lifecycle operations. Every command supports both interactive and non-interactive modes.

## Global Behavior

- **Interactive mode**: When run in a terminal with stdin and stdout connected, the CLI prompts for missing required input.
- **Non-interactive mode**: Use `--no-input` to disable all prompts. The command fails if required input is missing.
- **Exit codes**: The CLI returns structured exit codes for scripting and CI integration.

## Exit Codes

| Code | Meaning                                |
| ---- | -------------------------------------- |
| 0    | Success                                |
| 1    | Runtime failure or validation findings |
| 2    | Usage error                            |
| 130  | Interrupted (SIGINT)                   |

Error messages follow the format `[exit:<code>] <message>` so scripts can parse the exit code from stderr.

## Commands

### `nfw new`

Create a new workspace from a template.

```bash
nfw new [workspace-name] [options]
```

| Option       | Description                                    |
| ------------ | ---------------------------------------------- |
| `--template` | Template identifier (qualified or unqualified) |
| `--no-input` | Disable all interactive prompts                |

**Examples:**

```bash
# Interactive — prompts for missing information
nfw new my-workspace

# Non-interactive — explicit template
nfw new my-workspace --template blank-workspace --no-input

# With a qualified template identifier
nfw new my-workspace --template official/blank-workspace --no-input
```

On success, the CLI prints the workspace name, output path, selected template, and base namespace.

---

### `nfw templates`

Manage template sources and discovery. Requires a subcommand.

#### `nfw templates list`

List all discovered templates with their identifiers, versions, and descriptions.

```bash
nfw templates list
```

Output format:

```
<source>/<id> <name> (<version>)
  <description>
```

Warnings are printed to stderr before the template list.

#### `nfw templates add`

Register a new template source.

```bash
nfw templates add --name <source-name> --url <git-url>
```

| Option   | Description             | Required |
| -------- | ----------------------- | -------- |
| `--name` | Template source name    | Yes      |
| `--url`  | Template source Git URL | Yes      |

**Example:**

```bash
nfw templates add --name my-org --url https://github.com/my-org/nfw-templates.git
```

#### `nfw templates remove`

Unregister a template source.

```bash
nfw templates remove --name <source-name>
```

| Option   | Description          | Required |
| -------- | -------------------- | -------- |
| `--name` | Template source name | Yes      |

#### `nfw templates refresh`

Refresh all template catalogs from their registered sources.

```bash
nfw templates refresh
```

This re-fetches template metadata from all registered sources and updates the local catalog.

---

### `nfw add`

Create workspace artifacts. Requires a subcommand.

#### `nfw add service`

Generate a service from a service template.

```bash
nfw add service [name] [options]
```

| Option       | Description                     |
| ------------ | ------------------------------- |
| `--template` | Service template identifier     |
| `--no-input` | Disable all interactive prompts |

**Examples:**

```bash
# Interactive service creation
nfw add service my-api

# Non-interactive with explicit template
nfw add service my-api --template dotnet-minimal-api --no-input
```

On success, the CLI prints the service name, output path, template identifier, and template version.

---

### `nfw check`

Validate workspace architecture against defined rules. This command scans all project manifests and source files in the current workspace and reports violations of forbidden project references, namespace usage, direct package dependencies, lint issues, and test failures.

```bash
nfw check
```

`nfw check` is non-interactive and operates on the workspace rooted at the nearest `nfw.yaml` file above the current directory.

#### What It Validates

| Check Layer          | What It Scans                                           | Finding Type          |
| -------------------- | ------------------------------------------------------- | --------------------- |
| Project References   | Workspace dependency graph against forbidden rules      | `project_reference`   |
| Namespace Usage      | Source files for forbidden namespace imports            | `namespace_usage`     |
| Package Usage        | Direct package references declared by each project      | `package_usage`       |
| Unreadable Artifacts | Manifests or source files that cannot be parsed or read | `unreadable_artifact` |
| Lint Checks          | Runs `make lint` in each service defined in `nfw.yaml`  | `lint_issue`          |
| Service Test Checks  | Runs `make test` in each service defined in `nfw.yaml`  | `test_issue`          |

#### Supported Project Types

`nfw check` automatically detects and validates:

- **C#** (`.csproj` files) — extracts `<ProjectReference>` and `<PackageReference>` entries
- **Rust** (`Cargo.toml` files) — extracts path dependencies and `[dependencies]` entries
- **Go** (`go.mod` files) — extracts module dependencies and replace directives

#### Exit Codes

| Code | Meaning                                   |
| ---- | ----------------------------------------- |
| 0    | No findings — workspace passes all checks |
| 1    | One or more validation findings detected  |
| 130  | Interrupted by SIGINT                     |

#### Output Format

**Success:**

```
architecture validation passed in '/path/to/workspace': no forbidden project references, namespaces, direct packages, lint issues, or service test issues found
```

**Failure:**

```
architecture validation found 3 issue(s)
- type=project_reference location=/path/to/service/Service.csproj offending_value=../forbidden/Forbidden.csproj hint=remove forbidden project reference and use interface instead
- type=namespace_usage location=/path/to/service/Handler.cs offending_value=Forbidden.Domain hint=remove forbidden namespace usage
- type=lint_issue location=/path/to/service hint=run `make lint`, fix reported lint violations, then rerun `nfw check`
summary: project_reference=1, namespace_usage=1, package_usage=0, unreadable_artifact=0, lint_issue=1, test_issue=0
```

Each finding includes:

- **type** — The category of violation
- **location** — The file or directory where the issue was found
- **offending** — The forbidden value or context
- **hint** — An actionable remediation suggestion

#### Examples

```bash
# Run architecture validation from any directory inside the workspace
nfw check

# Use in CI — exit code indicates pass/fail
nfw check || echo "Architecture validation failed"
```

#### Configuration

Rules are defined in the workspace's `nfw.yaml` file. The check command reads rule sets that define forbidden project references, namespaces, and packages per architecture layer.

---

## Configuration

The CLI reads optional configuration from `nfw.yaml` in the current working directory. Environment variables with the `NFW_` prefix override file keys. Invalid YAML produces a warning and the CLI continues with defaults.

## Template Sources

- **Debug builds**: Use `packages/nfw-templates` when the submodule exists. Falls back to release behavior if missing.
- **Release builds**: Fetch templates from `github.com/n-framework/nfw-templates` at tag `v{cliVersion}`.
