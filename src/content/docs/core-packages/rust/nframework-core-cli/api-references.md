---
title: nframework-core-cli Reference
description: API and behavior reference for the nframework-core-cli Rust package.
---

This page is a quick lookup for the core public contracts in `nframework-core-cli`.

## Crates

- `nframework-core-cli-abstractions`
- `nframework-core-cli-clap`
- `nframework-core-cli-inquire`

## Models

### CliSpec

Root CLI definition.

- fields: `name`, `about`, `banner`, `commands`, `require_command`
- builder methods:
  - `new(name)`
  - `with_about(about)`
  - `with_banner(banner)`
  - `with_command(command)`
  - `require_command()`

### CliCommandSpec

Command/subcommand definition.

- fields: `name`, `about`, `options`, `subcommands`, `require_subcommand`
- builder methods:
  - `new(name)`
  - `with_about(about)`
  - `with_option(option)`
  - `with_subcommand(subcommand)`
  - `require_subcommand()`

### CliOptionSpec

Option definition.

- fields: `id`, `long`, `help`, `required`
- builder methods:
  - `new(id, long)`
  - `with_help(help)`
  - `required()`

### `CliAppConfig`

Top-level config used by runtime builders.

- constructor: `new(spec: CliSpec)`
- field: `spec`

### `SelectOption`

Option for interactive selection prompts.

- fields: `label`, `value`, `description` (optional)
- constructor: `new(label, value)`
- builder: `with_description(description)`
- accessors: `label()`, `value()`, `description() -> Option<&str>`
- Display implementation shows "label - description" or just "label"
- Used with `PromptService::select()` and `PromptService::select_index()`

## Runtime Contracts

### `Command`

Parsed command abstraction exposed to handlers.

- `name() -> &str`
- `arguments() -> &[String]`
- `option(name: &str) -> Option<&str>`

### CliAdapter

Parser abstraction.

- `parse(input: &[String]) -> Result<Box<dyn Command>, CliAdapterError>`

### `CliRuntime<C>`

Adapter-agnostic runtime with typed context.

- `new(adapter: Box<dyn CliAdapter>, context: C) -> Self`
- `register_handler(command_name, handler) -> Self`
- `run(input: &[String]) -> Result<(), String>`

Runtime behavior:

- parses input through the adapter
- prints help and returns `Ok(())` when adapter returns help error
- dispatches by canonical command name (for example `templates/add`)
- returns error for unregistered commands

### `CliRuntimeHandler<C>`

Handler contract used by `CliRuntime`.

- `handle(command: &dyn Command, context: &C) -> Result<(), String>`
- function/closure handlers are supported through trait implementation

### `PromptService`

Abstract interface for interactive CLI prompts. Implementations must be thread-safe (`Send + Sync`).

- `is_interactive() -> bool`: Returns true only when running in a TTY environment
- `text(message: &str, default: Option<&str>) -> Result<String, PromptError>`
- `confirm(message: &str, default: bool) -> Result<bool, PromptError>`
- `select(message: &str, options: &[SelectOption], default_index: Option<usize>) -> Result<SelectOption, PromptError>`
- `select_index(message: &str, options: &[SelectOption], default_index: Option<usize>) -> Result<usize, PromptError>`

Return `PromptError::cancelled()` when users explicitly cancel (e.g., Ctrl+C) or when the operation is interrupted.

## Clap Implementation

### `ClapAdapter`

Adapter implementation backed by `clap`.

- `new(definition: clap::Command) -> Self`
- `from_spec(spec: &CliSpec) -> Self`

### `ClapCliRuntimeBuilder<C>`

Builds `CliRuntime<C>` with `ClapAdapter`.

- `new(config: CliAppConfig, context: C) -> Self`
- `register_handler(command_name, handler) -> Self`
- `build() -> CliRuntime<C>`

## Inquire Implementation

### `InquirerPromptService`

Prompt service implementation backed by `inquire`.

- `new() -> Self`
- Implements `PromptService` trait
- Checks `stdin` and `stdout` for TTY detection via `is_interactive()`
- Displays help message ("↑↓ to move, enter to select, type to filter") for selection prompts

## Command Naming

Use slash-separated canonical command names for handler keys:

- `templates/list`
- `templates/add`
- `templates/remove`
- `templates/refresh`

The key must match parsed command names generated from the command tree.

## Error Surface

### `CliAdapterError`

Adapter-level parse/help error type.

- `help(message: String) -> Self`
- `parse(message: String) -> Self`
- `is_help() -> bool`
- `message() -> &str`

In runtime flow:

- help errors are printed and treated as successful execution
- parse errors are returned as `Err(String)`

### `PromptError`

Prompt service error type.

- kinds: `Cancelled`, `Io`, `Validation`, `Internal`
- constructors:
  - `cancelled(message) -> Self`
  - `io(message) -> Self`
  - `validation(message) -> Self`
  - `internal(message) -> Self`
- methods:
  - `kind() -> &PromptErrorKind`
  - `is_cancelled() -> bool`
  - `message() -> &str`

Error handling:

- Use `cancelled()` for user interruptions (Ctrl+C, signals)
- Use `io()` for I/O failures with context
- Use `validation()` for invalid input (e.g., empty option list)
- Use `internal()` for unexpected errors
