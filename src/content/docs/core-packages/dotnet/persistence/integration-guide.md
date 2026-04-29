---
title: Integration Guide
description: Step-by-step guide to integrating NFramework Persistence into a generated .NET service, covering DbContext setup, repository registration, DI configuration, and full request flow from API to database.
---

## Introduction

This guide walks through integrating `NFramework.Persistence` into an NFramework-generated .NET service. When you run `nfw add service <name>`, the workspace already includes the correct project structure. This document explains what each piece does and how the layers connect.

## Prerequisites

- A workspace created with `nfw new <workspace-name>`
- A service added with `nfw add service <service-name> --template dotnet-service`
- The service project template version includes persistence infrastructure scaffolding

The generated service structure:

```
MyWorkspace/
├── nfw.yaml
└── src/
    └── MyService/
        ├── MyService.slnx
        ├── Makefile
        ├── README.md
        ├── .editorconfig
        ├── .csharpierrc
        ├── .gitignore
        ├── core/
        │   ├── MyService.Domain/
        │   │   ├── MyService.Domain.csproj
        │   │   ├── Features/
        │   │   │   └── Products/
        │   │   │       ├── Product.cs            ← Entity inherits from Entity<Guid>
        │   │   │       └── ProductId.cs          ← Strongly-typed ID (optional)
        │   │   └── Shared/
        │   └── MyService.Application/
        │       ├── MyService.Application.csproj
        │       ├── ApplicationServiceRegistration.cs
        │       ├── Features/
        │       │   └── Products/
        │       │       ├── Commands/
        │       │       │   └── CreateProduct/
        │       │       │       ├── CreateProductCommand.cs
        │       │       │       ├── CreateProductCommandHandler.cs
        │       │       │       └── CreateProductCommandValidator.cs
        │       │       └── Queries/
        │       │           └── GetProduct/
        │       │               ├── GetProductQuery.cs
        │       │               └── GetProductQueryHandler.cs
        │       └── Shared/
        ├── infrastructure/
        │   └── MyService.Infrastructure.Persistence/
        │       ├── MyService.Infrastructure.Persistence.csproj
        │       ├── InfrastructureServiceRegistrationExtensions.cs   ← DI registration
        │       ├── Features/
        │       │   └── Products/
        │       │       └── ProductConfiguration.cs               ← EF Core fluent API
        │       └── Shared/
        │           └── Database/
        │               ├── Contexts/
        │               │   └── BaseDbContext.cs                   ← DbContext definition
        │               └── Models/
        │                   └── DatabaseConfiguration.cs           ← Connection string binding
        └── presentation/
            └── MyService.WebApi/
                ├── MyService.WebApi.csproj
                ├── Program.cs                                    ← Application composition root
                ├── appsettings.json
                ├── Features/
                │   └── Products/
                │       └── ProductEndpoints.cs                   ← Minimal API routes
                └── Shared/
                    ├── HealthCheck/
                    └── OpenApi/
```

## Step 1: Define Entities in the Domain Layer

Entities live in `core/<Service>.Domain/Features/<Aggregate>/`. They inherit from framework base classes:

**Domain Entity with Identity and Soft Delete (optional):**

```csharp
using NFramework.Persistence.Abstractions.Entities;

namespace MyService.Domain.Features.Products;

public sealed class Product : SoftDeletableEntity<ProductId>
{
    // Required by EF Core — DO NOT USE in domain logic
    [Obsolete("Only for ORM use", true)]
#pragma warning disable CS0618
    private Product() { }
#pragma warning restore CS0618

    // Primary constructor — application code uses this
    public Product(ProductId id, string name, decimal price)
        : base(id)
    {
        Name = name;
        Price = price;
    }

    public string Name { get; private set; }
    public decimal Price { get; private set; }
    public string? Description { get; private set; }

    // Domain behavior
    public void Rename(string newName) => Name = newName;
    public void UpdatePrice(decimal newPrice) => Price = newPrice;
}
```

If you need full audit trail (created/updated timestamps), inherit from `AuditableEntity<TId>` instead of `Entity<TId>`. For soft-deletion, inherit from `SoftDeletableEntity<TId>` (which includes auditable behavior).

**Strongly-typed ID (optional but recommended):**

```csharp
using NFramework.Persistence.Abstractions.Entities;

namespace MyService.Domain.Features.Products;

public readonly record struct ProductId(Guid Value)
{
    public static ProductId New() => new(Guid.NewGuid());
    public static explicit operator Guid(ProductId id) => id.Value;
    public static explicit operator ProductId(Guid id) => new(id);
}
```

Using a value object for identity prevents accidentally mixing IDs from different aggregates.

## Step 2: Configure EF Core Mappings in Infrastructure

Entity Framework configurations live in the Infrastructure layer under `Features/<Aggregate>/`.

**Entity Configuration:**

```csharp
using MyService.Domain.Features.Products;
using NFramework.Persistence.EFCore.Extensions;
using NFramework.Persistence.Abstractions.Entities;

namespace MyService.Infrastructure.Persistence.Features.Products;

public sealed class ProductConfiguration : IEntityTypeConfiguration<Product>
{
    public void Configure(EntityTypeBuilder<Product> builder)
    {
        // Primary key
        builder.HasKey(p => p.Id);

        // Convert strongly-typed ID to Guid for EF Core
        builder.Property(p => p.Id)
            .HasConversion(
                v => (Guid)v.Value,
                v => new ProductId(v))
            .ValueGeneratedNever();  // Application-generated IDs

        // Concurrency token (RowVersion from base Entity)
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

        // Soft-delete global query filter is auto-applied for ISoftDeletableEntity
        // No manual configuration needed — SoftDeletionInterceptor handles it

        // Indexes
        builder.HasIndex(p => p.Name).HasDatabaseName("IX_Product_Name");
    }
}
```

**For soft-deletable entities**, the global query filter is automatically applied by `ModelBuilderExtensions.ConfigureSoftDeleteFilter()` (called from the base `DbContext`). You can apply it manually if needed:

```csharp
builder.HasQueryFilter(p => !p.IsDeleted);
```

## Step 3: Define the DbContext

The generated `BaseDbContext` lives in `infrastructure/Shared/Database/Contexts/BaseDbContext.cs`:

```csharp
using Microsoft.EntityFrameworkCore;
using NFramework.Persistence.EFCore.Extensions;
using NFramework.Persistence.Abstractions.Entities;

namespace MyService.Infrastructure.Persistence.Shared.Database.Contexts;

public abstract class BaseDbContext : DbContext
{
    protected BaseDbContext(DbContextOptions<BaseDbContext> options)
        : base(options) { }

    // Override OnModelCreating to apply configurations and conventions
    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);

        // Apply all IEntityTypeConfiguration<T> from this assembly
        modelBuilder.ApplyConfigurationsFromAssembly(
            typeof(BaseDbContext).Assembly
        );

        // Apply NFramework conventions (default value generators, etc.)
        modelBuilder.ConfigureEntityConventions();

        // Apply soft delete global query filters to all ISoftDeletableEntity types
        modelBuilder.ConfigureSoftDeleteFilter();
    }

    // Optional: override SaveBehavior for cascading soft deletes
    protected override void OnConfiguring(DbContextOptionsBuilder optionsBuilder)
    {
        // No configuration here — done via IServiceCollection extensions
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

    // If you have owned value objects or custom queries, add DbSet properties
    // public DbSet<ProductVariant> ProductVariants => Set<ProductVariant>();
}
```

## Step 4: Configure Connection Strings

The generated `DatabaseConfiguration` class binds to `appsettings.json`:

```csharp
namespace MyService.Infrastructure.Persistence.Shared.Database.Models;

public sealed class DatabaseConfiguration
{
    public string ConnectionString { get; init; } = "Data Source=local.db";
    public bool ApplyMigrationsOnStartup { get; init; } = true;
    public int? SoftDeleteCascadeDepth { get; init; } = 50;  // Optional: override default
}
```

In `appsettings.json`:

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

In `Program.cs` (WebApi):

```csharp
builder.Services.Configure<DatabaseConfiguration>(
    builder.Configuration.GetSection("Infrastructure:Persistence")
);
```

## Step 5: Register Services in Infrastructure Layer

Create `InfrastructureServiceRegistrationExtensions.cs` in the Infrastructure.Persistence project:

```csharp
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using NFramework.Persistence.EFCore.Extensions;
using MyService.Infrastructure.Persistence;
using MyService.Infrastructure.Persistence.Shared.Database.Models;
using MyService.Domain.Features.Products;

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

        // 2. Register DbContext
        services.AddDbContext<MyServiceDbContext>(options =>
        {
            options.UseSqlite(dbConfig.ConnectionString);

            // NFramework interceptor registration
            options.AddSoftDeleteInterceptor(
                maxCascadeDepth: dbConfig.SoftDeleteCascadeDepth ?? 50
            );
            options.AddAuditableInterceptor();
            // options.AddAuditLoggerInterceptor();  // Optional
        });

        // 3. Register repositories — explicit registration
        services.AddScoped<IProductRepository, ProductRepository>();
        // services.AddScoped<IOrderRepository, OrderRepository>();
        // services.AddScoped<ICustomerRepository, CustomerRepository>();

        // 4. Optional: register generic repository fallback (not recommended for compile-time safety)
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

**Migration Applier (Background Service):**

```csharp
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using NFramework.Persistence.EFCore.Extensions;

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

Alternatively, use the built-in `IHost` extension (if hosting a generic host):

```csharp
using var host = Host.CreateApplicationBuilder(args).Build();
await host.ApplyMigrationsAsync<MyServiceDbContext>();
```

But for ASP.NET Core Web API, the `IHostedService` approach is cleaner.

## Step 6: Implement Repository Interfaces

Each aggregate gets its own repository interface in the **Application layer** (or Infrastructure if you prefer):

```csharp
using NFramework.Persistence.Abstractions.Repositories;
using MyService.Domain.Features.Products;

namespace MyService.Application.Features.Products.Repositories;

public interface IProductRepository
    : IReadRepository<Product, ProductId>,
      IWriteRepository<Product, ProductId>,
      IDynamicReadRepository<Product, ProductId>,
      IUnitOfWork { }
```

Implementation in Infrastructure.Persistence:

```csharp
using NFramework.Persistence.EFCore.Repositories;
using MyService.Domain.Features.Products;
using MyService.Infrastructure.Persistence.Shared.Database.Contexts;

namespace MyService.Infrastructure.Persistence.Features.Products;

internal sealed class ProductRepository(
    MyServiceDbContext context
) : EFCoreRepository<Product, ProductId, MyServiceDbContext>(context),
    IProductRepository
{
    // Custom query methods
    public async Task<IReadOnlyList<Product>> GetActiveAsync(CancellationToken ct = default)
    {
        return await DbSet
            .Where(p => !p.IsDeleted && p.IsActive)
            .OrderBy(p => p.Name)
            .ToListAsync(ct);
    }

    public async Task<IReadOnlyList<Product>> SearchByNameAsync(
        string searchTerm,
        CancellationToken ct = default
    )
    {
        var options = new DynamicQueryOption(
            Filters: [new Filter("Name", FilterOperator.Contains, searchTerm)],
            Orders: [new Order("Name")]
        );
        return await GetAllByDynamicAsync(options, ct);
    }
}
```

All base repository methods (`AddAsync`, `GetByIdAsync`, `GetAllByDynamicAsync`, `SaveChangesAsync`, etc.) are already implemented in `EFCoreRepository`. Only add custom methods specific to your aggregate.

## Step 7: Wire Everything in Presentation Layer (Program.cs)

`src/presentation/MyService.WebApi/Program.cs`:

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

// 2. Register Application layer (MediatR, validators, custom services)
builder.Services.AddApplicationLayer();

// 3. Register Infrastructure layer (DbContext, repositories)
builder.Services.AddInfrastructureServices(builder.Configuration);

// 4. Configure OpenAPI/Swagger
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(c =>
{
    c.SwaggerDoc("v1", new OpenApiInfo
    {
        Title = "MyService API",
        Version = "v1",
        Description = "NFramework-generated service"
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

app.Run();
```

## Step 8: Define API Endpoints in Presentation Layer

Feature endpoints in `presentation/Features/Products/ProductEndpoints.cs`:

```csharp
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using MyService.Application.Features.Products.Commands.CreateProduct;
using MyService.Application.Features.Products.Queries.GetProduct;
using MyService.Presentation.Features.Common;

namespace MyService.Presentation.Features.Products;

public static class ProductEndpoints
{
    public static IEndpointRouteBuilder MapProductEndpoints(
        this IEndpointRouteBuilder routes
    )
    {
        var group = routes.MapGroup("/api/v1/products")
            .WithTags("Products")
            .WithOpenApi();

        // GET /api/v1/products/{id}
        group.MapGet("/{id:guid}", async Task<Results<Ok<ProductDto>, NotFound>>(
            Guid id,
            IMediator mediator,
            CancellationToken ct
        ) =>
        {
            var result = await mediator.Send(new GetProductQuery(id), ct);
            return result.IsSuccess
                ? TypedResults.Ok(result.Value)
                : TypedResults.NotFound();
        })
        .WithName("GetProduct")
        .WithOpenApi();

        // POST /api/v1/products
        group.MapPost("/", async Task<Results<CreatedAtRoute<ProductDto>, BadRequest<ValidationProblemDetail>>>(
            CreateProductCommand command,
            IMediator mediator,
            CancellationToken ct
        ) =>
        {
            var result = await mediator.Send(command, ct);
            return result.IsSuccess
                ? TypedResults.CreatedAtRoute(
                    routeName: "GetProduct",
                    routeValues: new { id = result.Value.Id },
                    value: result.Value
                )
                : TypedResults.BadRequest(new ValidationProblemDetail(result.Errors.ToDictionary()));
        })
        .WithName("CreateProduct")
        .WithOpenApi();

        // GET /api/v1/products?search=...
        group.MapGet("/", async Task<Ok<IReadOnlyList<ProductDto>>>(
            string? search,
            IMediator mediator,
            CancellationToken ct
        ) =>
        {
            var query = search is null
                ? new GetProductsQuery()
                : new GetProductsQuery(searchTerm: search);

            var result = await mediator.Send(query, ct);
            return TypedResults.Ok(result.Value);
        })
        .WithName("GetProducts");

        return routes;
    }
}
```

Endpoints are thin — they delegate to Application layer handlers via MediatR. Presentation knows nothing about repositories.

## Step 9: Handler Implementation in Application Layer

The handler receives the repository via constructor injection:

```csharp
using MediatR;
using MyService.Application.Features.Products.Commands.CreateProduct;
using MyService.Domain.Features.Products;
using MyService.Application.Features.Products.Repositories;

namespace MyService.Application.Features.Products.Commands.CreateProduct;

public sealed class CreateProductCommandHandler
    : IRequestHandler<CreateProductCommand, Result<ProductDto>>
{
    private readonly IProductRepository _repository;

    public CreateProductCommandHandler(IProductRepository repository)
    {
        _repository = repository;
    }

    public async Task<Result<ProductDto>> Handle(
        CreateProductCommand request,
        CancellationToken cancellationToken
    )
    {
        // 1. Create domain entity
        var product = new Product(
            id: ProductId.New(),
            name: request.Name,
            price: request.Price
        );

        // 2. Add to repository
        await _repository.AddAsync(product, cancellationToken);

        // 3. Persist (single transaction for this handler)
        await _repository.SaveChangesAsync(cancellationToken);

        // 4. Return DTO
        return Result<ProductDto>.Success(product.ToDto());
    }
}
```

**Transaction boundaries:**

Handlers typically own the transaction — the DI scope creates a single `DbContext` instance, and all repositories share it. When `SaveChangesAsync()` is called on any repository, it saves all pending changes across all repositories in that scope.

For operations spanning multiple aggregates in separate handlers, consider using a mediator pipeline behavior that wraps the handler in a transaction:

```csharp
public class TransactionBehavior<TRequest, TResponse> : IPipelineBehavior<TRequest, TResponse>
    where TRequest : IRequest<TResponse>
{
    private readonly IUnitOfWork _unitOfWork;

    public async Task<TResponse> Handle(
        TRequest request,
        RequestHandlerDelegate<TResponse> next,
        CancellationToken cancellationToken
    )
    {
        await _unitOfWork.BeginTransactionAsync(cancellationToken);
        try
        {
            var response = await next();
            await _unitOfWork.CommitTransactionAsync(cancellationToken);
            return response;
        }
        catch
        {
            await _unitOfWork.RollbackTransactionAsync(cancellationToken);
            throw;
        }
    }
}

// Registration in Application layer:
services.AddTransient(typeof(IPipelineBehavior<,>), typeof(TransactionBehavior<,>));
```

Pipeline behaviors run automatically around every MediatR handler, providing cross-cutting concerns like transactions, logging, and validation.

## Step 10: Error Handling Across Layers

**Concurrency exceptions:**

```csharp
try
{
    await _repository.UpdateAsync(product);
    await _repository.SaveChangesAsync(ct);
}
catch (ConcurrencyConflictException ex)
{
    // Structured data available
    _logger.LogWarning(
        "Concurrency conflict for {EntityType} ID {EntityId}. Current: {Current}, Expected: {Original}",
        ex.EntityType, ex.EntityId,
        Convert.ToBase64String(ex.CurrentVersion ?? []),
        Convert.ToBase64String(ex.OriginalVersion ?? [])
    );

    // Refresh entity from database and merge
    var current = await _repository.GetByIdAsync(product.Id, ct);
    current.Rename(product.Name);  // Apply user's changes
    await _repository.UpdateAsync(current);
    await _repository.SaveChangesAsync(ct);
}
```

**Validation failures:**

Application layer validators (FluentValidation) run before handlers:

```csharp
public class CreateProductCommandValidator : AbstractValidator<CreateProductCommand>
{
    public CreateProductCommandValidator()
    {
        RuleFor(x => x.Name)
            .NotEmpty()
            .MaximumLength(200);

        RuleFor(x => x.Price)
            .GreaterThanOrEqualTo(0);
    }
}
```

Validation errors propagate to the API as 400 Bad Request with details (if using `FluentValidation.DependencyInjectionExtensions` and `ProblemDetails`).

**Database exceptions:**

EF Core exceptions (`DbUpdateException`, `SqlException`) bubble up. Convert them to domain exceptions in the handler if needed:

```csharp
catch (DbUpdateException ex) when (ex.InnerException?.Message.Contains("UNIQUE constraint failed") == true)
{
    throw new DomainException($"Product with name '{product.Name}' already exists.");
}
```

## Data Flow Diagram: Request → Persistence

1. **HTTP Request** hits endpoint in `ProductEndpoints.cs`
2. Endpoint creates command/query and sends via `IMediator.Send()`
3. **MediatR pipeline** executes (validation, logging, transaction if configured)
4. Handler receives request, resolves `IProductRepository` from DI
5. Handler calls `repository.AddAsync(entity)` → `EFCoreRepository.AddAsync()` → `DbSet.AddAsync()`
6. Handler calls `repository.SaveChangesAsync()` → `EFCoreRepository.SaveChangesAsync()` → `DbContext.SaveChangesAsync()`
7. **EF Core interceptors** fire in order:
   - `AuditableInterceptor` sets `CreatedAt` / `UpdatedAt`
   - `SoftDeletionInterceptor` converts `Deleted` → `IsDeleted = true`
   - `AuditLoggerInterceptor` logs change set (optional)
8. **Database command** executes via EF Core provider (SQLite, PostgreSQL, SQL Server, etc.)
9. RowVersion updated on INSERT/UPDATE
10. Response propagates back up the call stack, eventually serialized to JSON

## Testing the Integration

### Unit Testing Handlers

Mock `IProductRepository`:

```csharp
[Test]
public async Task CreateProductCommandHandler_ShouldAddProduct()
{
    // Arrange
    var mockRepo = new Mock<IProductRepository>();
    var handler = new CreateProductCommandHandler(mockRepo.Object);
    var command = new CreateProductCommand("Test", 10.99m);

    // Act
    var result = await handler.Handle(command, CancellationToken.None);

    // Assert
    result.IsSuccess.Should().BeTrue();
    mockRepo.Verify(r => r.AddAsync(It.IsAny<Product>(), It.IsAny<CancellationToken>()), Times.Once);
    mockRepo.Verify(r => r.SaveChangesAsync(It.IsAny<CancellationToken>()), Times.Once);
}
```

### Integration Testing with Real Database

Use SQLite in-memory:

```csharp
[Test]
public async Task FullCreateProductFlow_ShouldPersist()
{
    // Arrange: create DbContext with real SQLite in-memory
    var options = new DbContextOptionsBuilder<MyServiceDbContext>()
        .UseSqlite("DataSource=:memory:")
        .Options;

    await using var context = new MyServiceDbContext(options);
    await context.Database.OpenConnectionAsync();
    await context.Database.EnsureCreatedAsync();

    var repository = new ProductRepository(context);
    var handler = new CreateProductCommandHandler(repository);

    var command = new CreateProductCommand(
        id: Guid.NewGuid(),
        name: "Integration Test",
        price: 42.00m
    );

    // Act
    var result = await handler.Handle(command, CancellationToken.None);

    // Assert
    result.IsSuccess.Should().BeTrue();
    var fromDb = await context.Products.FirstOrDefaultAsync(p => p.Id == result.Value.Id);
    fromDb.Should().NotBeNull();
    fromDb!.Name.Should().Be("Integration Test");
}
```

### Load Testing Considerations

- Repository methods are **async all the way** — no blocking calls
- `DbContext` is registered as scoped, not singleton — appropriate for web requests
- Connection pooling provided by database provider (SQLite = file lock; PostgreSQL/ SQL Server = connection pooling)
- Consider paginating all list endpoints — never return full table

## Common Pitfalls

| Symptom | Cause | Fix |
|---------|--------|-----|
| `InvalidOperationException: A transaction is already active` | Nested `BeginTransactionAsync()` calls on shared unit of work | Avoid starting multiple transactions; use pipeline behavior or single commit point |
| Concurrency exceptions on every update | Missing or mismatch `RowVersion` handling | Ensure entity's `RowVersion` is passed from read to update (typically via DTO roundtrip) |
| Entity not tracked after `GetAllAsync` | Default tracking is off for read queries | Pass `QueryTrackingMode.Tracking` in options if you plan to update without re-fetch |
| Dynamic query fails in AOT | Dynamic LINQ uses reflection | Use typed queries for AOT; avoid `GetByDynamicAsync` or isolate with `#if !AOT` |
| Soft-delete cascade not working | Navigation not configured with `DeleteBehavior.Cascade` | Configure relationship with `.OnDelete(DeleteBehavior.Cascade)` in entity configuration |

## Deployment Checklist

- [ ] Verify connection string for production database
- [ ] Set `ApplyMigrationsOnStartup` appropriately (true for simple deployments, false for CI/CD-managed migrations)
- [ ] Test bulk operation limits (`MaxBatchSize`, `MaxResultSetSize`) with real data volumes
- [ ] Ensure all soft-deletable entities have proper cascade configuration in EF Core model
- [ ] Confirm `ILogger` is configured for audit logging if `AuditLoggerInterceptor` is enabled
- [ ] For AOT: verify `[DynamicallyAccessedMembers]` attributes preserved on all custom generic extensions
- [ ] Review exception handling middleware to convert `ConcurrencyConflictException` into appropriate HTTP status (409 Conflict)

## Next Steps

With persistence integrated, read the [API Reference](/core-packages/dotnet/persistence/api-reference/) for complete method signatures and overloads, then explore [Advanced Topics](/core-packages/dotnet/persistence/advanced-topics/) for AOT, performance tuning, and custom repository patterns.
