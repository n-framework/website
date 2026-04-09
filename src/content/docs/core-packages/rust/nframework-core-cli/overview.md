---
title: nframework-core-cli Overview
description: Architecture and usage guide for the reusable Rust CLI workspace used by NFramework.
---

This guide documents the `nframework-core-cli` package as a reusable Rust workspace for building CLI applications.

It is designed so application packages can define commands and handlers without depending on `clap` directly.

## Workspace overview

`nframework-core-cli` currently contains two crates:

- `nframework-core-cli-abstractions`
  - pure abstractions/model crate
  - defines command/spec models and runtime contracts
  - no clap dependency
- `nframework-core-cli-clap`
  - clap-backed implementation crate
  - converts `CliSpec` into clap commands
  - provides runtime builder for clap adapter wiring

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

### 3) clap implementation

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
- Keep implementation details (`clap`) out of consumer app layers when possible.
- Add new adapter crates under `nframework-core-cli` if additional parser backends are needed.
