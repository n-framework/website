---
title: nframework-core-template Overview
description: Architecture and usage guide for the reusable Rust template engine workspace used by NFramework.
---

This guide documents the `nframework-core-template` package as a reusable Rust workspace for template-based code generation.

It provides abstractions for rendering templates and generating file structures, with a Mustache-based implementation included out of the box.

## Workspace overview

`nframework-core-template` currently contains two crates:

- `nframework-core-template-abstractions`
  - Pure abstractions/model crate
  - Defines `TemplateRenderer`, `FileGenerator`, and `TemplateContext` traits
  - Defines `TemplateError` for error handling
  - No template engine dependency
- `nframework-core-template-mustache`
  - Mustache-backed implementation crate
  - Provides `MustacheTemplateRenderer` with caching
  - Provides `MustacheFileGenerator` for directory-based generation

This split lets other projects reuse the abstractions crate and swap template engine implementations if needed (e.g., Handlebars, Jinja2).

## Core concepts

### 1) Template Renderer Trait

The `TemplateRenderer` trait defines the contract for rendering template strings:

```rust
pub trait TemplateRenderer {
    /// Renders the given template content with the provided context.
    fn render_content(
        &self,
        template_content: &str,
        context: &TemplateContext,
    ) -> Result<String, TemplateError>;
}
```

Implementors provide the logic to parse and render template strings using a specific template engine.

### 2) File Generator Trait

The `FileGenerator` trait defines the contract for generating files from templates:

```rust
pub trait FileGenerator {
    /// Generates files from templates in the template_root directory to output_root.
    fn generate(
        &self,
        template_root: &Path,
        output_root: &Path,
        context: &TemplateContext,
    ) -> Result<(), TemplateError>;
}
```

Implementors recursively process template directories, render template files with a context, and write output to a destination directory.

**Overwrite Policy**: By default, existing files are overwritten. Use `AtomicFileGenerator` for transactional guarantees where partial failures can be rolled back.

### 3) Template Context

`TemplateContext` holds key-value pairs for template variable substitution:

```rust
use nframework_core_template_abstractions::TemplateContext;

let mut context = TemplateContext::empty();
context.insert("name", "World");
context.insert_number("count", 42.0);
context.insert_bool("active", true);

assert_eq!(context.get_str("name"), Some("World"));
```

Supports structured data including strings, numbers, booleans, arrays, and objects via `serde_json::Value`.

### 4) Error Handling

`TemplateError` provides comprehensive error handling:

```rust
pub enum TemplateErrorKind {
    Io(String),
    Parse(String),
    Render(String),
    Validation(String),
}
```

All template operations return `Result<T, TemplateError>` for explicit error handling.

## Mustache implementation

### MustacheTemplateRenderer

The included Mustache implementation provides:

- Thread-safe template rendering with `Send + Sync`
- LRU caching of compiled templates for performance
- Support for standard Mustache syntax: `{{variable}}`, `{{#section}}`, `{{^inverse}}`, `{{.}}`

```rust
use nframework_core_template_mustache::MustacheTemplateRenderer;

let renderer = MustacheTemplateRenderer::new();
let rendered = renderer.render_content("Hello, {{name}}!", &context)?;
```

### MustacheFileGenerator

The file generator implementation:

- Recursively scans template directories
- Renders files with `.mustache` extension
- Copies non-template files as-is
- Creates output directory structure as needed

```rust
use nframework_core_template_mustache::MustacheFileGenerator;
use std::path::Path;

let generator = MustacheFileGenerator::new();
generator.generate(
    Path::new("./templates"),
    Path::new("./output"),
    &context,
)?;
```

## Template syntax

### Variables

```text
Hello, {{name}}!
You have {{count}} messages.
```

### Sections

```text
{{#active}}
  This is shown when active is true.
{{/active}}

{{^active}}
  This is shown when active is false.
{{/active}}
```

### Lists

```text
{{#items}}
  - {{name}}: {{description}}
{{/items}}
```

## Usage in nfw CLI

The `nfw` CLI uses these abstractions for:

- **Template discovery**: Scanning template catalogs and reading metadata
- **Template rendering**: Generating workspace and service files from templates
- **Context management**: Building template contexts from user input and defaults

Example from nfw's template generation:

```rust
use nframework_core_template_abstractions::{FileGenerator, TemplateContext};
use nframework_core_template_mustache::MustacheFileGenerator;

fn generate_workspace(
    template_path: &Path,
    output_path: &Path,
    workspace_name: &str,
) -> Result<(), TemplateError> {
    let mut context = TemplateContext::empty();
    context.insert("workspace_name", workspace_name);
    context.insert("year", &chrono::Utc::now().format("%Y").to_string());

    let generator = MustacheFileGenerator::new();
    generator.generate(template_path, output_path, &context)
}
```

## Creating custom template engines

To implement a custom template engine:

1. Implement `TemplateRenderer` trait for your engine
2. Optionally implement `FileGenerator` for directory-based generation
3. Use `TemplateContext` for passing variables to templates

Example Handlebars implementation:

```rust
use nframework_core_template_abstractions::{TemplateRenderer, TemplateContext, TemplateError};
use handlebars::Handlebars;

pub struct HandlebarsTemplateRenderer {
    registry: Handlebars<'static>,
}

impl TemplateRenderer for HandlebarsTemplateRenderer {
    fn render_content(
        &self,
        template_content: &str,
        context: &TemplateContext,
    ) -> Result<String, TemplateError> {
        let json = context.to_json_value()?;
        self.registry
            .render_template(template_content, &json)
            .map_err(|e| TemplateError::render(e.to_string()))
    }
}
```

## Testing guidance

Use two test levels:

- **Abstraction tests**: Test trait behaviors and error handling
  - Context insertion and retrieval
  - Error propagation and messages
- **Implementation tests**: Test engine-specific behavior
  - Template rendering with various syntaxes
  - File generation with directory structures
  - Caching behavior (if applicable)

Example test:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use nframework_core_template_abstractions::TemplateContext;

    #[test]
    fn test_render_variable() {
        let renderer = MustacheTemplateRenderer::new();
        let mut context = TemplateContext::empty();
        context.insert("name", "World");

        let result = renderer
            .render_content("Hello, {{name}}!", &context)
            .unwrap();

        assert_eq!(result, "Hello, World!");
    }
}
```

## Performance considerations

- **Template caching**: `MustacheTemplateRenderer` caches compiled templates automatically
- **File I/O**: Use `AtomicFileGenerator` for transactional guarantees when needed
- **Thread safety**: Both renderer and generator implementations are `Send + Sync`

## Notes for maintainers

- Keep public abstractions in `nframework-core-template-abstractions` stable for reuse
- Keep implementation details (`mustache`, `handlebars`, etc.) out of consumer app layers
- Add new adapter crates under `nframework-core-template` if additional template engines are needed
- Ensure thread safety for all implementations (template rendering often happens in parallel)
