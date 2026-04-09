---
title: Templates
description: How template discovery, catalog management, and source registration work in NFramework.
---

Templates define the starter structure for workspaces and services. The `nfw` CLI manages template sources, discovers available templates, and generates code from them.

## How Templates Work

Templates are stored in Git repositories with a standard catalog structure. The CLI:

1. **Registers** template sources (Git repositories)
2. **Synchronizes** template metadata from each source
3. **Discovers** available templates with versions and descriptions
4. **Generates** workspace or service code from the selected template

## Template Catalog Structure

Each template source repository contains a catalog file that defines available templates:

```yaml
templates:
  - id: blank-workspace
    name: Blank Workspace
    version: 1.0.0
    description: Minimal starter workspace
    path: templates/blank-workspace
```

The catalog includes template identifiers, versions, descriptions, and file paths within the source repository.

## Default Template Source

Out of the box, the CLI uses the official template repository:

- **Repository**: `github.com/n-framework/nfw-templates`
- **Version**: Tagged at `v{cliVersion}` for reproducible generation

Debug builds fall back to a local `packages/nfw-templates` submodule when available.

## Managing Template Sources

### List Templates

```bash
nfw templates list
```

Shows all discovered templates across all registered sources:

```
official/blank-workspace Blank Workspace (1.0.0)
  Minimal starter workspace
```

### Add a Template Source

Register a custom template source:

```bash
nfw templates add --name my-org --url https://github.com/my-org/nfw-templates.git
```

The source name is used as a prefix in template identifiers (e.g., `my-org/custom-service`).

### Remove a Template Source

```bash
nfw templates remove --name my-org
```

### Refresh Template Catalogs

Re-fetch metadata from all registered sources:

```bash
nfw templates refresh
```

Run this after updating a template source repository to pick up new templates or version changes.

## Using Templates

### Workspace Creation

```bash
# List available templates first
nfw templates list

# Create a workspace with a specific template
nfw new my-workspace --template blank-workspace --no-input
```

### Service Creation

```bash
# Add a service (interactive template selection)
nfw add service my-api

# Add a service with explicit template
nfw add service my-api --template dotnet-minimal-api --no-input
```

## Template Identifiers

Templates are identified by `<source>/<id>`:

- **Unqualified**: `blank-workspace` — matches any source
- **Qualified**: `official/blank-workspace` — matches a specific source

When multiple sources provide the same template ID, use the qualified form to avoid ambiguity.

## Template Engine

NFramework uses the `nframework-core-template` workspace for template rendering:

- **Abstraction layer**: `TemplateRenderer`, `FileGenerator`, and `TemplateContext` traits
- **Mustache implementation**: Included out of the box with caching for performance
- **Extensible**: Swap template engines if needed (Handlebars, Jinja2, etc.)

Templates use Mustache syntax for variable substitution:

```text
# Workspace name
{{workspace_name}}

# Conditional sections
{{#include_tests}}
Tests enabled!
{{/include_tests}}

# Lists
{{#dependencies}}
- {{name}}: {{version}}
{{/dependencies}}
```

For detailed documentation of the template engine API and usage, see the [nframework-core-template overview](/core-packages/rust/nframework-core-template/overview/).

## Creating Custom Templates

To create your own template source:

1. Create a Git repository with a `catalog.yaml` file at the root.
2. Define your templates in the catalog with `id`, `name`, `version`, `description`, and `path`.
3. Place template files in the paths referenced by the catalog.
4. Register the source with `nfw templates add --name <name> --url <url>`.

Template files support placeholder substitution for workspace names, namespaces, and other generated values.

## Troubleshooting

### No Templates Found

- Run `nfw templates refresh` to fetch the latest catalog.
- Verify your network connection for remote sources.
- Check that the template source repository exists and is accessible.

### Template Version Mismatch

- Release builds fetch templates at `v{cliVersion}`. Ensure the template repository has a matching tag.
- Use `nfw templates list` to see the actual versions discovered.

### Invalid Template Source

- The URL must be a valid Git URL (HTTPS, SSH, or local path).
- The repository must contain a valid `catalog.yaml` at the root.
