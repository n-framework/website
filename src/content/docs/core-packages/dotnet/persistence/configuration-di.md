---
title: Configuration & DI
description: Complete guide to dependency injection registration, DbContext configuration, EF Core model building, migrations, and extension methods in NFramework Persistence.
---

## Introduction

Configuration happens in the **Infrastructure.Persistence** project. The key steps:

1. Define `DatabaseConfiguration` (binds to `appsettings.json`)
2. Create `InfrastructureServiceRegistrationExtensions.AddInfrastructureServices()` — registrations for `DbContext`, repositories, interceptors
3. Configure `BaseDbContext` — global query filters, conventions, entity configurations
4. Wire in `Presentation/Program.cs` — call `AddApplicationLayer()` and `AddInfrastructureServices()`

This document covers each of these in detail.

## DatabaseConfiguration

Simple POCO that binds to configuration section `Infrastructure:Persistence`.

```csharp
namespace MyService.Infrastructure.Persistence.Shared.Database.Models;

public sealed class DatabaseConfiguration
{
    /// <summary>
    /// Database connection string (e.g., "Data Source=myservice.db" for SQLite,
    /// "Server=...;Database=...;Trusted_Connection=true;" for SQL Server)
    /// </summary>
    public string ConnectionString { get; init; } = "Data Source=local.db";

    /// <summary>
    /// If true, the application automatically applies pending migrations on startup.
    /// Defaults to true for simplicity. Set to false in production if migrations
    /// are managed externally (CI/CD, DBA, etc.).
    /// </summary>
    public bool ApplyMigrationsOnStartup { get; init; } = true;

    /// <summary>
    /// Maximum depth for cascade soft-delete traversal. Default 50.
    /// Set lower to protect against extremely deep graphs, higher if needed.
    /// </summary>
    public int? SoftDeleteCascadeDepth { get; init; } = 50;
}
```

**appsettings.json example (SQLite):**

```json
{
  "Infrastructure": {
    "Persistence": {
      "ConnectionString": "Data Source=myservice.db",
      "ApplyMigrationsOnStartup": true,
      "SoftDeleteCascadeDepth": 50
    }
  }
}
```

**appsettings.json example (SQL Server):**

```json
{
  "Infrastructure": {
    "Persistence": {
      "ConnectionString": "Server=localhost;Database=MyService;Trusted_Connection=true;MultipleActiveResultSets=true;",
      "ApplyMigrationsOnStartup": true,
      "SoftDeleteCascadeDepth": 50
    }
  }
}
```

**Binding in Program.cs (WebApi):**

```csharp
builder.Services.Configure<DatabaseConfiguration>(
    builder.Configuration.GetSection("Infrastructure:Persistence")
);
```

The options pattern gives you strongly-typed access throughout the app via `IOptions<DatabaseConfiguration>`.

## Infrastructure Service Registration

Create `InfrastructureServiceRegistrationExtensions.cs` in your Infrastructure.Persistence project:

```csharp
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using NFramework.Persistence.EFCore.Extensions;
using MyService.Infrastructure.Persistence;
using MyService.Infrastructure.Persistence.Shared.Database.Models;
using MyService.Domain.Features.Products;   // Aggregate entry points

namespace MyService.Infrastructure.Persistence;

public static class InfrastructureServiceRegistrationExtensions
{
    public static IServiceCollection AddInfrastructureServices(
        this IServiceCollection services,
        IConfiguration configuration
    )
    {
        // 1. Bind configuration
        var dbConfig = new DatabaseConfiguration();
        configuration.GetSection("Infrastructure:Persistence").Bind(dbConfig);

        // 2. Register DbContext with interceptors
        services.AddDbContext<MyServiceDbContext>(options =>
        {
            options.UseSqlite(dbConfig.ConnectionString);

            // NFramework interceptor chain
            options.AddAuditableInterceptor();
            options.AddSoftDeleteInterceptor(
                maxCascadeDepth: dbConfig.SoftDeleteCascadeDepth ?? 50
            );
            // options.AddAuditLoggerInterceptor();  // Optional
        });

        // 3. Register repositories — explicit per-aggregate
        services.AddScoped<IProductRepository, ProductRepository>();
        services.AddScoped<IOrderRepository, OrderRepository>();
        services.AddScoped<ICustomerRepository, CustomerRepository>();

        // 4. Optional: register generic repository fallback
        // services.AddScoped(typeof(IRepository<>), typeof(EFCoreRepository<,,>));

        // 5. Apply migrations on startup if configured
        if (dbConfig.ApplyMigrationsOnStartup)
        {
            services.AddHostedService<MigrationApplier>();
        }

        return services;
    }
}
```

**Alternatives:**

- If you don't use `IConfiguration` binding, construct `DatabaseConfiguration` inline.
- For multiple database providers, conditionally call `UseSqlite` / `UseSqlServer` / `UseNpgsql` based on config.

## DbContext Configuration

### BaseDbContext

The generated `BaseDbContext` provides shared conventions and soft-delete filter:

```csharp
using Microsoft.EntityFrameworkCore;
using NFramework.Persistence.EFCore.Extensions;
using NFramework.Persistence.Abstractions.Entities;

namespace MyService.Infrastructure.Persistence.Shared.Database.Contexts;

public abstract class BaseDbContext : DbContext
{
    protected BaseDbContext(DbContextOptions<BaseDbContext> options)
        : base(options) { }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);

        // Apply all IEntityTypeConfiguration<T> in this assembly
        modelBuilder.ApplyConfigurationsFromAssembly(typeof(BaseDbContext).Assembly);

        // Framework conventions (precision, default value generators)
        modelBuilder.ConfigureEntityConventions();

        // Global query filter for ISoftDeletableEntity
        modelBuilder.ConfigureSoftDeleteFilter<BaseDbContext>();
    }
}
```

Your service-specific `DbContext` inherits from `BaseDbContext`:

```csharp
namespace MyService.Infrastructure.Persistence;

public sealed class MyServiceDbContext : BaseDbContext
{
    public MyServiceDbContext(DbContextOptions<MyServiceDbContext> options)
        : base(options) { }

    // DbSets for each aggregate root
    public DbSet<Product> Products => Set<Product>();
    public DbSet<Order> Orders => Set<Order>();
    public DbSet<Customer> Customers => Set<Customer>();
}
```

**Scoped lifetime:** `DbContext` is registered as scoped via `AddDbContext<T>()`. In web apps, this means one context per HTTP request.

## Entity Configuration

Each aggregate's EF Core mapping lives in `Infrastructure/Features/<Aggregate>/<Entity>Configuration.cs`.

```csharp
using MyService.Domain.Features.Products;
using NFramework.Persistence.EFCore.Extensions;

namespace MyService.Infrastructure.Persistence.Features.Products;

public sealed class ProductConfiguration : IEntityTypeConfiguration<Product>
{
    public void Configure(EntityTypeBuilder<Product> builder)
    {
        // Primary key: Guid
        builder.HasKey(p => p.Id);

        // Convert strongly-typed ID to Guid (if using value objects)
        builder.Property(p => p.Id)
            .HasConversion(
                v => (Guid)v.Value,
                v => new ProductId(v))
            .ValueGeneratedNever();  // Application generates IDs (UUID v4)

        // RowVersion for optimistic concurrency
        builder.Property(p => p.RowVersion)
            .IsRowVersion()
            .IsConcurrencyToken();

        // Column constraints
        builder.Property(p => p.Name)
            .HasMaxLength(200)
            .IsRequired();

        builder.Property(p => p.Price)
            .HasPrecision(18, 2)
            .IsRequired();

        builder.Property(p => p.Description)
            .HasMaxLength(1000);

        // Indexes
        builder.HasIndex(p => p.Name)
            .HasDatabaseName("IX_Product_Name");

        // Relationships (example - Order → OrderItems)
        // builder.HasMany(p => p.Items)
        //     .WithOne(i => i.Product)
        //     .HasForeignKey(i => i.ProductId)
        //     .OnDelete(DeleteBehavior.Restrict);
    }
}
```

**Soft-delete filter:** No manual `HasQueryFilter` needed — `BaseDbContext.OnModelCreating` calls `ConfigureSoftDeleteFilter()` which applies globally to all `ISoftDeletableEntity` types.

**Conventions:** `ModelBuilder.ConfigureEntityConventions()` (from `ModelBuilderExtensions`) sets common defaults like decimal precision (18, 2) across the model. Override per-property if needed.

## EF Core Extension Methods

### For `DbContextOptionsBuilder`

All defined in `NFramework.Persistence.EFCore.Extensions.DbContextOptionsBuilderExtensions`.

| Method | Purpose | Example |
|--------|---------|---------|
| `AddSoftDeleteInterceptor(int? maxCascadeDepth = 50)` | Registers `SoftDeletionInterceptor` | `options.AddSoftDeleteInterceptor(100)` |
| `AddAuditableInterceptor()` | Registers singleton `AuditableInterceptor` | `options.AddAuditableInterceptor()` |
| `AddAuditLoggerInterceptor()` | Registers singleton `AuditLoggerInterceptor` | `options.AddAuditLoggerInterceptor()` |

These methods chain onto `DbContextOptionsBuilder` (both raw and generic versions).

**Usage checklist:**

```csharp
services.AddDbContext<MyDbContext>(options =>
{
    // 1. Provider
    options.UseSqlite(connectionString);

    // 2. Interceptors (order matters)
    options.AddAuditableInterceptor();     // timestamps first
    options.AddSoftDeleteInterceptor(50); // then soft-delete
    // options.AddAuditLoggerInterceptor(); // finally audit log
});
```

### For `ModelBuilder`

| Method | Purpose |
|--------|---------|
| `ConfigureEntityConventions()` | Applies framework-wide conventions (value generators, decimal precision). Call once in `OnModelCreating`. |
| `ConfigureSoftDeleteFilter<TContext>()` | Adds global query filter `IsDeleted == false` for all `ISoftDeletableEntity` types. |

**Example:**

```csharp
protected override void OnModelCreating(ModelBuilder modelBuilder)
{
    modelBuilder.ApplyConfigurationsFromAssembly(typeof(BaseDbContext).Assembly);
    modelBuilder.ConfigureEntityConventions();
    modelBuilder.ConfigureSoftDeleteFilter<BaseDbContext>();
}
```

### For `IQueryable<T>`

Internal-use extension methods called by repository implementation:

| Method | Purpose |
|--------|---------|
| `ApplyTracking(QueryTrackingMode?)` | Applies `AsNoTracking()` if mode is `NoTracking`. |
| `ApplyFilters(IReadOnlyCollection<Filter>?)` | Translates dynamic `Filter` collection to Dynamic LINQ `Where` expression. |
| `ApplyOrders(IReadOnlyCollection<Order>?)` | Translates dynamic `Order` collection to Dynamic LINQ `OrderBy`. |
| `ToPaginatedListAsync(Paging, CancellationToken)` | Executes COUNT + paginated SELECT, returns `PaginatedList<T>`. |

You can use these in custom repository methods if building dynamic queries manually.

### For `IHost`

`NFramework.Persistence.EFCore.Extensions.HostExtensions` provides:

```csharp
public static async Task<IHost> ApplyMigrationsAsync<TContext>(this IHost host)
    where TContext : DbContext
```

**Purpose:** Automatically applies any pending EF Core migrations at service startup.

**Example:**

```csharp
internal static async Task Main(string[] args)
{
    var builder = Host.CreateApplicationBuilder(args);

    // Register services...
    builder.Services.AddInfrastructureServices(configuration);

    using var host = builder.Build();

    // Apply migrations (blocking call at startup)
    await host.ApplyMigrationsAsync<MyServiceDbContext>();

    await host.RunAsync();
}
```

**AOT warning:** This method is marked `[RequiresDynamicCode]` because EF Core needs to build the design-time model to compute pending migrations. It will not work with Native AOT. Use pre-generated SQL scripts or migration bundles instead.

**Alternative for AOT / Production:**

```csharp
// Background service that applies migrations
public sealed class MigrationApplier : IHostedService
{
    public async Task StartAsync(CancellationToken ct)
    {
        using var scope = _serviceProvider.CreateScope();
        var context = scope.ServiceProvider.GetRequiredService<MyDbContext>();
        await context.Database.MigrateAsync(ct);  // same EF Core method but without dynamic code check
    }

    public Task StopAsync(CancellationToken ct) => Task.CompletedTask;
}
```

Even `context.Database.MigrateAsync()` requires design-time model building and is not AOT-compatible. For AOT, **use migration scripts executed outside the application** (see Advanced Topics).

## Repository Registration Patterns

### Pattern 1: Explicit Repository Interfaces (Recommended)

Define a per-aggregate interface that inherits the base contracts:

```csharp
namespace MyService.Application.Features.Products.Repositories;

public interface IProductRepository
    : IReadRepository<Product, ProductId>,
      IWriteRepository<Product, ProductId>,
      IDynamicReadRepository<Product, ProductId>,
      IUnitOfWork { }
```

Implementation in Infrastructure:

```csharp
internal sealed class ProductRepository(
    MyServiceDbContext context
) : EFCoreRepository<Product, ProductId, MyServiceDbContext>(context),
    IProductRepository { }
```

**DI registration:**

```csharp
services.AddScoped<IProductRepository, ProductRepository>();
```

**Inject into handler:**

```csharp
public sealed class GetProductHandler : IRequestHandler<GetProductQuery, Result<ProductDto>>
{
    private readonly IProductRepository _repository;
    public GetProductHandler(IProductRepository repository) => _repository = repository;
    // ...
}
```

**Advantages:** Compile-time type safety, explicit contract, easy to mock, clear intent.

### Pattern 2: Generic Repository Fallback (Use with Caution)

If you have dozens of aggregates and want to avoid writing dozens of repository interfaces, you can fall back to the generic base:

```csharp
services.AddScoped(typeof(IRepository<>), typeof(EFCoreRepository<,,>));
```

But this defeats the purpose of repository interfaces as an **abstraction barrier** between Application and Infrastructure. Application handlers would need to reference `EFCoreRepository` or use generic constraints that leak EF Core types. **Not recommended** for Clean Architecture.

Better to write explicit interfaces — it's a one-time cost per aggregate and pays off in clarity and testability.

## Full Program.cs Composition Root

**File:** `presentation/MyService.WebApi/Program.cs`

```csharp
using Microsoft.OpenApi.Models;
using NFramework.Persistence.EFCore.Extensions;
using MyService.Application;
using MyService.Infrastructure.Persistence;
using MyService.Infrastructure.Persistence.Shared.Database.Models;
using MyService.Presentation.Features.Products;

var builder = WebApplication.CreateBuilder(args);

// 1. Configuration
builder.Services.Configure<DatabaseConfiguration>(
    builder.Configuration.GetSection("Infrastructure:Persistence")
);

// 2. Register Application layer (MediatR, FluentValidation, custom app services)
builder.Services.AddApplicationLayer();

// 3. Register Infrastructure layer (DbContext, repositories, background services)
builder.Services.AddInfrastructureServices(builder.Configuration);

// 4. Configure OpenAPI/Swagger (optional)
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(c =>
{
    c.SwaggerDoc("v1", new OpenApiInfo
    {
        Title = "MyService API",
        Version = "v1",
        Description = "NFramework-generated service API"
    });
});

var app = builder.Build();

// 5. Middleware pipeline
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseHttpsRedirection();
app.UseAuthorization();

// 6. Register feature endpoints
app.MapProductEndpoints();
// app.MapOrderEndpoints(); // other aggregates

app.Run();
```

This single file wires together all three layers:

- **Configuration** — appsettings.json binding
- **Application** — `AddApplicationLayer()` (from `MyService.Application` project)
- **Infrastructure** — `AddInfrastructureServices()` (from `MyService.Infrastructure.Persistence` project)
- **Presentation** — endpoint registration (`MapProductEndpoints()`)

## Migration Applier (Background Service)

When `ApplyMigrationsOnStartup = true`, the infrastructure project typically includes a background service:

```csharp
namespace MyService.Infrastructure.Persistence;

internal sealed class MigrationApplier : IHostedService
{
    private readonly IServiceProvider _serviceProvider;
    private readonly ILogger<MigrationApplier> _logger;

    public MigrationApplier(IServiceProvider serviceProvider, ILogger<MigrationApplier> logger)
    {
        _serviceProvider = serviceProvider;
        _logger = logger;
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        using var scope = _serviceProvider.CreateScope();
        var context = scope.ServiceProvider.GetRequiredService<MyServiceDbContext>();

        _logger.LogInformation("Applying database migrations...");
        await context.Database.MigrateAsync(cancellationToken);
        _logger.LogInformation("Migrations applied successfully.");
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
```

Registration in `AddInfrastructureServices()`:

```csharp
if (dbConfig.ApplyMigrationsOnStartup)
{
    services.AddHostedService<MigrationApplier>();
}
```

This runs **once** at application startup, before the first request is handled. If migrations fail, the app may refuse to start or continue depending on your policy.

**Alternative:** Use `IHost` extension directly in `Program.cs` after `host.Build()` if you're not using ASP.NET Core's web host pattern.

## Testing DI Configuration

Unit test that your `AddInfrastructureServices` method correctly registers all services:

```csharp
[Test]
public void AddInfrastructureServices_RegistersAllRepositoriesAndDbContext()
{
    // Arrange
    var services = new ServiceCollection();
    var configuration = new ConfigurationBuilder()
        .AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Infrastructure:Persistence:ConnectionString"] = "Data Source=:memory:",
            ["Infrastructure:Persistence:ApplyMigrationsOnStartup"] = "false"
        })
        .Build();

    // Act
    services.AddInfrastructureServices(configuration);

    // Assert
    var provider = services.BuildServiceProvider();

    provider.GetService<MyServiceDbContext>().Should().NotBeNull();
    provider.GetService<IProductRepository>().Should().NotBeNull();
    provider.GetService<IOrderRepository>().Should().NotBeNull();
    provider.GetService<IUnitOfWork>().Should().NotBeNull(); // any repo
}
```

## Multiple DbContexts (Rare)

If your service needs more than one database (e.g., read replica, modular databases), you can register multiple `DbContext` types:

```csharp
services.AddDbContext<WriteDbContext>(...);
services.AddDbContext<ReadDbContext>(...);

// Then inject the appropriate context into each repository
services.AddScoped<IWriteProductRepository, WriteProductRepository>();
services.AddScoped<IReadProductRepository, ReadProductRepository>();
```

Each `DbContext` has its own interceptor chain and connection string.

## Environment-Specific Configuration

Use `appsettings.Development.json` for local development:

```json
{
  "Infrastructure": {
    "Persistence": {
      "ConnectionString": "Data Source=dev.db",
      "ApplyMigrationsOnStartup": true,
      "SoftDeleteCascadeDepth": 50
    }
  }
}
```

Production may use environment variables or Azure Key Vault / AWS Parameter Store:

```csharp
builder.Configuration
    .AddEnvironmentVariables()
    .AddAzureKeyVault(vaultUri, new DefaultAzureCredential());
```

Connection strings with credentials should **never** be committed to source control.

## Troubleshooting Configuration Issues

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| `InvalidOperationException: No service for type 'MyDbContext'` | `AddInfrastructureServices` not called in `Program.cs` | Add `builder.Services.AddInfrastructureServices(builder.Configuration)` |
| `SqlException: Invalid object name` | Migrations not applied | Ensure `ApplyMigrationsOnStartup=true` or run `dotnet ef database update` |
| `InvalidOperationException: A transaction is already active` | Two nested `BeginTransactionAsync` calls on same `DbContext` | Use one transaction per handler scope or ensure multiple repos share context |
| Concurrency exceptions on every update | Client not sending `RowVersion`, or `UpdateAsync` not called | Ensure DTO includes `RowVersion` (byte[] base64 or hex), and that `UpdateAsync` is invoked before `SaveChangesAsync` |
| Soft-deleted records still appear | `ISoftDeletableEntity` not implemented or global filter not configured | Verify entity inherits from `SoftDeletableEntity<TId>` and `BaseDbContext.OnModelCreating` calls `ConfigureSoftDeleteFilter()` |

## Summary Checklist

- [ ] Define `DatabaseConfiguration` in `Infrastructure.Persistence.Shared.Database.Models`
- [ ] Create `InfrastructureServiceRegistrationExtensions.AddInfrastructureServices()` in Infrastructure project
- [ ] Implement `BaseDbContext` with `OnModelCreating` calling `ConfigureSoftDeleteFilter()` and `ConfigureEntityConventions()`
- [ ] Implement service-specific `DbContext` inheriting from `BaseDbContext` with `DbSet<T>` properties
- [ ] Create per-aggregate `IEntityTypeConfiguration<TEntity>` in `Features/<Entity>/`
- [ ] Implement per-aggregate repository interfaces inheriting from base contracts
- [ ] Implement per-aggregate repository classes inheriting `EFCoreRepository<T, TId, TContext>`
- [ ] Register `DbContext` with `UseSqlite/UseSqlServer/UseNpgsql` and interceptor extensions
- [ ] Register repositories explicitly with `services.AddScoped<IEntityRepo, EntityRepo>()`
- [ ] Optionally register `MigrationApplier` background service
- [ ] In WebApi `Program.cs`, call `AddApplicationLayer()` then `AddInfrastructureServices()`
- [ ] Bind `DatabaseConfiguration` from `appsettings.json` (or other configuration source)

With this configuration in place, the persistence layer is fully integrated into the NFramework clean architecture and ready for use by Application layer handlers.
