---
title: nframework-core-cli Overview
description: Architecture and usage guide for the reusable Rust CLI workspace used by NFramework.
---

This guide documents the `nframework-core-cli` package as a reusable Rust workspace for building CLI applications.

It is designed so application packages can define commands and handlers without depending on `clap` directly.

## Workspace overview

`nframework-core-cli` currently contains three crates:

- `nframework-core-cli-abstractions`
  - pure abstractions/model crate
  - defines command/spec models and runtime contracts
  - defines `PromptService` trait for interactive prompts
  - no clap dependency
- `nframework-core-cli-clap`
  - clap-backed implementation crate
  - converts `CliSpec` into clap commands
  - provides runtime builder for clap adapter wiring
- `nframework-core-cli-inquire`
  - inquire-backed implementation crate
  - provides `InquirerPromptService` for interactive CLI prompts
  - implements text, confirm, and select prompts

This split lets other projects reuse the abstractions crate and swap adapter implementations if needed.

## Core concepts

### 1) CLI specification model

Use fluent builders to describe command trees:

- `CliSpec`: root command metadata (`name`, `about`, banner, commands)
- `CliCommandSpec`: subcommands and command-level options
- `CliOptionSpec`: option id, long-name, help, required flag
- `CliAppConfig`: wraps root spec for runtime construction

### 2) Runtime and handlers

`CliRuntime<C>` is a reusable parse-and-dispatch runtime:

- receives a `CliAdapter`
- owns typed application context `C`
- dispatches to handlers by canonical command key (`group/subcommand`)

Handlers implement `CliRuntimeHandler<C>` and return `Result<(), String>`.

### 3) Interactive prompts

`PromptService` trait defines abstractions for interactive CLI prompts:

- `text(message, default) -> Result<String, PromptError>`
- `confirm(message, default) -> Result<bool, PromptError>`
- `select(message, options, default_index) -> Result<SelectOption, PromptError>`
- `select_index(message, options, default_index) -> Result<usize, PromptError>`
- `is_interactive() -> bool`: checks if running in a TTY environment

`nframework-core-cli-inquire` provides `InquirerPromptService`:

- Backed by the `inquire` crate
- Thread-safe (`Send + Sync`)
- Handles user cancellation (Ctrl+C) via `PromptError::cancelled()`
- Provides consistent help messages for selection prompts

### 4) clap implementation

`nframework-core-cli-clap` provides:

- `ClapAdapter`: parse CLI input using clap from `CliSpec`
- `ClapCliRuntimeBuilder<C>`: convenience builder for `CliRuntime<C>` with clap adapter

This keeps clap-specific logic isolated in one package.

## Recommended integration pattern

For any consumer app (for example `nframework-nfw-cli`):

1. build `CliAppConfig` in one runtime module
2. create app context/services in bootstrap/startup
3. register one handler function per command key
4. keep handler logic thin and delegate to application commands/use-cases
5. call `runtime.run(&input)` from `main`

### main.rs example

```rust
mod runtime;
mod startup;

use runtime::my_cli_runtime::build_runtime;
use startup::bootstrapper::Bootstrapper;

fn main() {
    if let Err(error) = run() {
        eprintln!("error: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let input = std::env::args().skip(1).collect::<Vec<_>>();
    let services = Bootstrapper::bootstrap()?;
    let runtime = build_runtime(services);
    runtime.run(&input)
}
```

### runtime module example

```rust
use nframework_core_cli_abstractions::{
    CliAppConfig, CliCommandSpec, CliOptionSpec, CliSpec, Command,
};
use nframework_core_cli_clap::ClapCliRuntimeBuilder;

#[derive(Clone)]
struct AppServices;

fn build_runtime(context: AppServices) -> impl Fn(&[String]) -> Result<(), String> {
    let config = CliAppConfig::new(
        CliSpec::new("mycli")
            .require_command()
            .with_command(
                CliCommandSpec::new("templates")
                    .require_subcommand()
                    .with_subcommand(CliCommandSpec::new("list"))
                    .with_subcommand(
                        CliCommandSpec::new("add")
                            .with_option(CliOptionSpec::new("name", "name").required()),
                    ),
            ),
    );

    let runtime = ClapCliRuntimeBuilder::new(config, context)
        .register_handler("templates/list", handle_list)
        .register_handler("templates/add", handle_add)
        .build();

    move |input| runtime.run(input)
}

fn handle_list(_: &dyn Command, _: &AppServices) -> Result<(), String> {
    println!("list templates");
    Ok(())
}

fn handle_add(command: &dyn Command, _: &AppServices) -> Result<(), String> {
    let name = command
        .option("name")
        .ok_or_else(|| "missing required option '--name'".to_owned())?;
    println!("add source: {name}");
    Ok(())
}
```

### Interactive prompt example

```rust
use nframework_core_cli_abstractions::{PromptService, SelectOption};
use nframework_core_cli_inquire::InquirerPromptService;

fn prompt_user() -> Result<(), String> {
    let prompt = InquirerPromptService::new();

    if !prompt.is_interactive() {
        return Err("This command requires an interactive terminal".to_string());
    }

    // Text prompt with default
    let name = prompt.text("Enter your name", Some("Anonymous"))?;

    // Confirmation prompt
    let confirmed = prompt.confirm("Continue?", true)?;

    // Selection prompt
    let options = vec![
        SelectOption::new("Option 1", "1").with_description("First option"),
        SelectOption::new("Option 2", "2").with_description("Second option"),
    ];
    let selected = prompt.select("Choose an option", &options, Some(0))?;

    println!("Selected: {} (value: {})", selected.label(), selected.value());
    Ok(())
}
```

## Testing guidance

Use two test levels:

- abstractions/adapter tests in `nframework-core-cli`
  - parse behavior
  - help/error behavior
  - runtime handler dispatch
- consumer app tests
  - command registration coverage
  - required option validation
  - handler-to-use-case integration behavior

## Notes for maintainers

- Keep public abstractions in `nframework-core-cli-abstractions` stable for reuse.
- Keep implementation details (`clap`, `inquire`) out of consumer app layers when possible.
- Add new adapter crates under `nframework-core-cli` if additional parser backends are needed.

## Usage in nfw CLI

The `nfw` CLI uses these abstractions extensively:

- **Command parsing**: `ClapAdapter` parses commands like `nfw new`, `nfw add service`, `nfw templates list`
- **Interactive prompts**: `InquirerPromptService` provides interactive prompts for:
  - Template selection when creating workspaces or services
  - Confirmation prompts for destructive operations
  - Text input for configuration values
- **Handler registration**: `CliRuntime` dispatches to command handlers in `nfw_cli_runtime.rs`
- **Domain integration**: Application services wrap `PromptService` in domain-specific interfaces (e.g., `ServiceTemplatePrompt`)

Example from nfw:

```rust
// In nfw_cli_runtime.rs
ClapCliRuntimeBuilder::new(build_nfw_cli_app_config(), services)
    .register_handler("new", handle_workspace_new)
    .register_handler("add/service", handle_add_service)
    .register_handler("templates/list", handle_templates_list)
    .build();

// In cli_service_collection_factory.rs
let template_selection = TemplateSelectionForNewService::new(
    templates_service,
    InquirerPromptService::new(),
);
```
