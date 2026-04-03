---
title: nframework-core-cli Reference
description: API and behavior reference for the nframework-core-cli Rust package.
---

This page is a quick lookup for the core public contracts in `nframework-core-cli`.

## Crates

- `nframework-core-cli-abstraction`
- `nframework-core-cli-clap`

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
