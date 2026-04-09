---
title: nframework-core-template References
description: API references for the nframework-core-template workspace.
---

This page provides a comprehensive API reference for the `nframework-core-template` workspace.

## nframework-core-template-abstractions

### TemplateContext

Context for template rendering, containing key-value pairs substituted into templates.

#### Methods

##### `empty()`

Creates an empty template context.

```rust
let context = TemplateContext::empty();
```

##### `insert(&mut self, key: &str, value: &str)`

Inserts a string value into the context.

```rust
context.insert("name", "World");
```

##### `insert_number(&mut self, key: &str, value: f64)`

Inserts a numeric value into the context.

```rust
context.insert_number("count", 42.0);
```

##### `insert_bool(&mut self, key: &str, value: bool)`

Inserts a boolean value into the context.

```rust
context.insert_bool("active", true);
```

##### `insert_array(&mut self, key: &str, values: Vec<Value>)`

Inserts an array into the context.

```rust
use serde_json::json;
context.insert_array("items", vec![json!("item1"), json!("item2")]);
```

##### `insert_object(&mut self, key: &str, value: Value)`

Inserts an object into the context.

```rust
use serde_json::json;
context.insert_object("config", json!({"key": "value"}));
```

##### `get_str(&self, key: &str) -> Option<&str>`

Retrieves a string value from the context.

```rust
if let Some(name) = context.get_str("name") {
    println!("Hello, {}!", name);
}
```

##### `get(&self, key: &str) -> Option<&Value>`

Retrieves any value from the context.

```rust
if let Some(value) = context.get("count") {
    println!("Count: {}", value);
}
```

##### `contains_key(&self, key: &str) -> bool`

Checks if a key exists in the context.

```rust
if context.contains_key("name") {
    // ...
}
```

##### `keys(&self) -> impl Iterator<Item = &String>`

Returns an iterator over all keys in the context.

```rust
for key in context.keys() {
    println!("Key: {}", key);
}
```

##### `len(&self) -> usize`

Returns the number of key-value pairs in the context.

```rust
println!("Context has {} entries", context.len());
```

##### `is_empty(&self) -> bool`

Checks if the context is empty.

```rust
if context.is_empty() {
    println!("No context variables");
}
```

##### `to_json_value(&self) -> Result<Value, TemplateError>`

Converts the context to a JSON value.

```rust
let json = context.to_json_value()?;
```

##### `clone(&self) -> TemplateContext`

Creates a clone of the context.

```rust
let cloned = context.clone();
```

### TemplateRenderer

Trait for rendering template content with a context.

#### Required Methods

##### `render_content(&self, template_content: &str, context: &TemplateContext) -> Result<String, TemplateError>`

Renders the given template content with the provided context.

**Parameters:**
- `template_content`: The raw template string to render
- `context`: The template context containing variable values

**Returns:**
- `Ok(String)`: The rendered content with variables substituted
- `Err(TemplateError)`: If rendering fails

**Example:**
```rust
let renderer = MustacheTemplateRenderer::new();
let rendered = renderer.render_content("Hello, {{name}}!", &context)?;
```

### FileGenerator

Trait for generating files from templates.

#### Required Methods

##### `generate(&self, template_root: &Path, output_root: &Path, context: &TemplateContext) -> Result<(), TemplateError>`

Generates files from templates in the template_root directory to output_root.

**Parameters:**
- `template_root`: The root directory containing template files
- `output_root`: The root directory where rendered files will be written
- `context`: The template context containing variable values

**Returns:**
- `Ok(())`: All files generated successfully
- `Err(TemplateError)`: If generation fails

**Overwrite Policy:** By default, existing output files are overwritten. Use `AtomicFileGenerator` for transactional behavior with rollback on failure.

**Example:**
```rust
let generator = MustacheFileGenerator::new();
generator.generate(
    Path::new("./templates"),
    Path::new("./output"),
    &context,
)?;
```

### TemplateError

Error type for template rendering and file generation operations.

#### Methods

##### `new(kind: TemplateErrorKind) -> Self`

Creates a new template error.

```rust
let error = TemplateError::new(TemplateErrorKind::Parse("invalid template".to_string()));
```

##### `kind(&self) -> &TemplateErrorKind`

Returns the error kind.

```rust
match error.kind() {
    TemplateErrorKind::Parse(msg) => println!("Parse error: {}", msg),
    _ => println!("Other error"),
}
```

##### `message(&self) -> &str`

Returns the error message.

```rust
eprintln!("Template error: {}", error.message());
```

##### `io(message: String) -> Self`

Creates an IO error.

```rust
let error = TemplateError::io("Failed to read file".to_string());
```

##### `parse(message: String) -> Self`

Creates a parse error.

```rust
let error = TemplateError::parse("Invalid Mustache syntax".to_string());
```

##### `render(message: String) -> Self`

Creates a render error.

```rust
let error = TemplateError::render("Variable not found".to_string());
```

##### `validation(message: String) -> Self`

Creates a validation error.

```rust
let error = TemplateError::validation("Missing required field".to_string());
```

### TemplateErrorKind

Enum representing different kinds of template errors.

#### Variants

##### `Io(String)`

IO-related errors (file reading, writing, directory operations).

##### `Parse(String)`

Template parsing errors (invalid syntax, malformed templates).

##### `Render(String)`

Template rendering errors (missing variables, type mismatches).

##### `Validation(String)`

Validation errors (invalid context, missing required fields).

## nframework-core-template-mustache

### MustacheTemplateRenderer

Mustache-based template renderer with caching for performance.

#### Methods

##### `new() -> Self`

Creates a new Mustache template renderer with an empty cache.

```rust
let renderer = MustacheTemplateRenderer::new();
```

##### `with_cache_capacity(capacity: usize) -> Self`

Creates a new Mustache template renderer with a specific cache capacity.

```rust
let renderer = MustacheTemplateRenderer::with_cache_capacity(100);
```

**Implements:** `TemplateRenderer`

### MustacheFileGenerator

File generator implementation for Mustache templates.

#### Methods

##### `new() -> Self`

Creates a new Mustache file generator.

```rust
let generator = MustacheFileGenerator::new();
```

##### `with_renderer(renderer: Arc<dyn TemplateRenderer>) -> Self`

Creates a new Mustache file generator with a custom renderer.

```rust
use std::sync::Arc;
let custom_renderer = Arc::new(MyCustomRenderer::new());
let generator = MustacheFileGenerator::with_renderer(custom_renderer);
```

**Implements:** `FileGenerator`

## Template Syntax Reference

### Variables

Output the value of a variable:

```text
{{name}}
```

### Sections

Render a block if a value is truthy:

```text
{{#active}}
  This is shown when active is true.
{{/active}}
```

Render a block if a value is falsy:

```text
{{^active}}
  This is shown when active is false.
{{/active}}
```

### Lists

Iterate over a list:

```text
{{#items}}
  - {{name}}: {{description}}
{{/items}}
```

### Comments

Comments that don't appear in the output:

```text
{{! This is a comment }}
```

### Delimiters

Change delimiters (useful for working with other templating languages):

```text
{{=<% %>=}}
<% name %>
<%= {{ }} %>
```

## Integration Examples

### Basic usage

```rust
use nframework_core_template_abstractions::TemplateContext;
use nframework_core_template_mustache::MustacheTemplateRenderer;

let mut context = TemplateContext::empty();
context.insert("name", "World");

let renderer = MustacheTemplateRenderer::new();
let rendered = renderer.render_content("Hello, {{name}}!", &context)?;

assert_eq!(rendered, "Hello, World!");
```

### File generation

```rust
use nframework_core_template_abstractions::{FileGenerator, TemplateContext};
use nframework_core_template_mustache::MustacheFileGenerator;
use std::path::Path;

let mut context = TemplateContext::empty();
context.insert("project_name", "my-project");
context.insert("author", "Your Name");

let generator = MustacheFileGenerator::new();
generator.generate(
    Path::new("./templates"),
    Path::new("./output"),
    &context,
)?;
```

### Custom template engine

```rust
use nframework_core_template_abstractions::{TemplateRenderer, TemplateContext, TemplateError};

pub struct MyTemplateRenderer;

impl TemplateRenderer for MyTemplateRenderer {
    fn render_content(
        &self,
        template_content: &str,
        context: &TemplateContext,
    ) -> Result<String, TemplateError> {
        // Your custom rendering logic here
        Ok(template_content.to_string())
    }
}
```

## Error Handling

All operations return `Result<T, TemplateError>` for explicit error handling:

```rust
match renderer.render_content(template, &context) {
    Ok(rendered) => println!("{}", rendered),
    Err(e) => eprintln!("Template error: {}", e.message()),
}
```

Handle specific error kinds:

```rust
match renderer.render_content(template, &context) {
    Ok(rendered) => println!("{}", rendered),
    Err(TemplateError { kind: TemplateErrorKind::Parse(msg), .. }) => {
        eprintln!("Parse error: {}", msg);
    }
    Err(e) => eprintln!("Other error: {}", e.message()),
}
```
