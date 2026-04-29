---
title: NFramework Persistence for .NET Overview
description: Comprehensive guide to NFramework's .NET persistence layer, covering repository patterns, EF Core integration, entity models, and data access abstractions.
---

## Introduction

The `NFramework.Persistence` family of packages provides a production-grade data access abstraction layer built on Entity Framework Core. It implements repository and unit-of-work patterns with strict Clean Architecture boundaries, enabling developers to build testable, maintainable data layers without sacrificing EF Core's power.

This package suite consists of two core libraries:

- `NFramework.Persistence.Abstractions` — Zero-dependency contracts and base types
  - Entity base classes (`Entity<TId>`, `AuditableEntity<TId>`, `SoftDeletableEntity<TId>`)
  - Repository interfaces (`IReadRepository<TEntity, TId>`, `IWriteRepository<TEntity, TId>`, `IDynamicReadRepository<TEntity, TId>`, `IUnitOfWork`)
  - Pagination types (`PaginatedList<T>`, `Paging`, `PageableQueryOption<TEntity>`)
  - Dynamic query infrastructure (`Filter`, `Order`, `DynamicQueryOption`, `FilterOperator`, `OrderDirection`)
  - Domain exceptions (`ConcurrencyConflictException`)

- `NFramework.Persistence.EFCore` — EF Core implementation
  - `EFCoreRepository<TEntity, TId, TContext>` base class implementing all repository contracts
  - Extension methods for `DbContext` configuration (`AddSoftDeleteInterceptor()`, `AddAuditableInterceptor()`)
  - Query translation extensions (`ApplyFilters()`, `ApplyOrders()`, `ToPaginatedListAsync()`)
  - Interceptors (`SoftDeletionInterceptor`, `AuditableInterceptor`, `AuditLoggerInterceptor`)
  - Host extensions for migrations (`ApplyMigrationsAsync<TContext>()`)

## Workspace Architecture

When you generate a service with `nfw add service <name>`, the tooling creates a 4-layer solution:

```
MyService.slnx
├── core/
│   ├── MyService.Domain/              ← Entity models inherit from Entity<Guid>
│   └── MyService.Application/         ← Commands/Queries depend on IRepository<T>
├── infrastructure/
│   └── MyService.Infrastructure.Persistence/
│       ├── InfrastructureServiceRegistrationExtensions.cs  ← DI registration
│       ├── Features/
│       │   └── Entities/             ← EF Core entity configurations
│       └── Shared/
│           └── Database/
│               ├── Contexts/
│               │   └── BaseDbContext.cs   ← DbContext base
│               └── Models/
│                   └── DatabaseConfiguration.cs  ← Connection string handling
└── presentation/
    └── MyService.WebApi/
        ├── Program.cs                 ← Calls AddApplicationLayer() + AddInfrastructureServices()
        └── Features/                 ← Minimal API endpoints
```

The **layer dependency rule** is strictly enforced:

```
Api → Application, Infrastructure
Infrastructure → Application, Domain
Application → Domain
Domain → (nothing)
```

Application code (commands, queries, handlers) depends **only** on the Abstractions package — never on EF Core directly. Infrastructure references the Abstractions package and implements the interfaces using EF Core.

## Core Concepts

### 1) Entity Base Classes

All persistent entities inherit from `Entity<TId>`, which defines the identity contract and optimistic concurrency token:

```csharp
public abstract class Entity<TId> where TId : IEquatable<TId>
{
    public TId Id { get; init; } = default!;
    public byte[] RowVersion { get; set; } = [];
}
```

**Key properties:**

- `Id` — Immutable primary key. The constructor requires a non-default value to enforce identity assignment at creation time.
- `RowVersion` — Optimistic concurrency token. EF Core maps this to a database `rowversion`/`timestamp` column automatically.

**Constructors:**

```csharp
// Application code: use this constructor
public MyEntity(Guid id) : base(id) { ... }

// ORM-only: DO NOT USE in application code
[Obsolete("Use constructor with ID instead. This is only for ORM use.")]
protected Entity() { }
```

EF Core requires a parameterless constructor for materialization. Mark it `[Obsolete]` to prevent accidental use in business logic.

#### AuditableEntity<TId>

For entities requiring creation/modification tracking:

```csharp
public abstract class AuditableEntity<TId> : Entity<TId>, IAuditableEntity
{
    public DateTime CreatedAt { get; set; }
    public DateTime? UpdatedAt { get; set; }
}
```

- `CreatedAt` — Set automatically to `DateTime.UtcNow` when the entity is first persisted (Added state).
- `UpdatedAt` — Set automatically to `DateTime.UtcNow` on every modification (Modified state).

Management is handled by `AuditableInterceptor`, so you never set these properties manually.

#### SoftDeletableEntity<TId>

For entities supporting soft deletion (logical delete):

```csharp
public abstract class SoftDeletableEntity<TId> : AuditableEntity<TId>, ISoftDeletableEntity
{
    public bool IsDeleted { get; set; }
    public DateTime? DeletedAt { get; set; }
}
```

- `IsDeleted` — Boolean flag for fast query filtering. Setting to `true` automatically sets `DeletedAt` to UTC now.
- `DeletedAt` — Nullable timestamp. Setting to non-null automatically sets `IsDeleted` to true.

Both properties are synchronized with thread-safe setters using `Interlocked.CompareExchange()` to prevent recursion.

**Soft-delete behavior is managed by `SoftDeletionInterceptor`**, which:

- Converts `EntityState.Deleted` into an update setting `IsDeleted = true` and `DeletedAt = now`
- Performs **cascade soft-delete** through navigations (collections and references) up to a configurable depth (default 50)
- Automatically loads unloaded navigations required for cascade traversal
- Prevents infinite loops using a visited entity set

### 2) Repository Pattern

The persistence layer provides four repository interfaces:

#### IReadRepository<TEntity, TId>

Read-only operations:

```csharp
public interface IReadRepository<TEntity, TId> where TEntity : Entity<TId>
{
    Task<TEntity?> GetByIdAsync(TId id, CancellationToken cancellationToken = default);
    Task<TEntity?> GetAsync(Expression<Func<TEntity, bool>>? predicate = null, ...);
    Task<IReadOnlyList<TEntity>> GetAllAsync(QueryOption<TEntity>? options = null, ...);
    Task<PaginatedList<TEntity>> GetListAsync(PageableQueryOption<TEntity>? options = null, ...);
    Task<bool> AnyAsync(Expression<Func<TEntity, bool>>? predicate = null, ...);
    Task<int> CountAsync(Expression<Func<TEntity, bool>>? predicate = null, ...);
}
```

Methods accept optional `QueryOption<TEntity>` parameters for filtering, ordering, and tracking control without exploding method signatures.

#### IWriteRepository<TEntity, TId>

Write operations with optimistic concurrency:

```csharp
public interface IWriteRepository<TEntity, TId> where TEntity : Entity<TId>
{
    Task<TEntity> AddAsync(TEntity entity, CancellationToken cancellationToken = default);
    Task<TEntity> UpdateAsync(TEntity entity, CancellationToken cancellationToken = default);
    Task<TEntity> UpsertAsync(TEntity entity, CancellationToken cancellationToken = default);
    Task<TEntity> DeleteAsync(TEntity entity, CancellationToken cancellationToken = default);
    Task<ICollection<TEntity>> BulkAddAsync(ICollection<TEntity> entities, ...);
    Task<ICollection<TEntity>> BulkUpdateAsync(ICollection<TEntity> entities, ...);
    Task<ICollection<TEntity>> BulkDeleteAsync(ICollection<TEntity> entities, ...);
}
```

**Important:** `UpdateAsync` performs **optimistic concurrency checking**. If the entity's `RowVersion` in the database differs from what you submitted, the operation throws `ConcurrencyConflictException`. You must re-fetch the entity, merge changes, and retry.

#### IDynamicReadRepository<TEntity, TId>

Runtime-dynamic queries using string-based expressions (backed by System.Linq.Dynamic.Core):

```csharp
public interface IDynamicReadRepository<TEntity, TId> where TEntity : Entity<TId>
{
    [RequiresUnreferencedCode("Dynamic query translation uses reflection-based System.Linq.Dynamic.Core...")]
    Task<TEntity?> GetByDynamicAsync(DynamicQueryOption options, CancellationToken cancellationToken = default);

    [RequiresUnreferencedCode("Dynamic query translation uses reflection-based System.Linq.Dynamic.Core...")]
    Task<IReadOnlyList<TEntity>> GetAllByDynamicAsync(DynamicQueryOption options, ...);

    [RequiresUnreferencedCode("Dynamic query translation uses reflection-based System.Linq.Dynamic.Core...")]
    Task<PaginatedList<TEntity>> GetListByDynamicAsync(PageableDynamicQueryOption options, ...);

    [RequiresUnreferencedCode("Dynamic query translation uses reflection-based System.Linq.Dynamic.Core...")]
    Task<bool> AnyByDynamicAsync(DynamicQueryOption options, ...);

    [RequiresUnreferencedCode("Dynamic query translation uses reflection-based System.Linq.Dynamic.Core...")]
    Task<int> CountByDynamicAsync(DynamicQueryOption options, ...);
}
```

These methods are marked `[RequiresUnreferencedCode]` because Dynamic LINQ uses reflection and is **not AOT-safe**. If you publish with Native AOT (`PublishAot=true`), avoid calling these methods or wrap them in `#if !AOT` guards.

#### IQueryRepository<TEntity, TId>

Exposes the underlying queryable for advanced scenarios:

```csharp
public interface IQueryRepository<TEntity, TId> where TEntity : Entity<TId>
{
    IQueryable<TEntity> Query();
}
```

Use this when you need to compose queries beyond what the standard options support (complex joins, custom projections, raw SQL).

#### IUnitOfWork

Coordinates multiple repository operations within a single transaction:

```csharp
public interface IUnitOfWork
{
    Task<int> SaveChangesAsync(CancellationToken cancellationToken = default);
    Task BeginTransactionAsync(CancellationToken cancellationToken = default);
    Task CommitTransactionAsync(CancellationToken cancellationToken = default);
    Task RollbackTransactionAsync(CancellationToken cancellationToken = default);
}
```

Every `EFCoreRepository` implements `IUnitOfWork` and shares the same underlying `DbContext`. When multiple repositories are constructed with the **same context instance**, they participate in the same unit of work.

### 3) Query Options and Dynamic Queries

#### QueryOption<TEntity> Hierarchy

```csharp
// Base: no pagination
public record QueryOption<TEntity>(
    Expression<Func<TEntity, bool>>? Predicate = null,
    Func<IQueryable<TEntity>, IOrderedQueryable<TEntity>>? OrderBy = null,
    QueryTrackingMode Tracking = QueryTrackingMode.Default
) : IFilterableQuery<TEntity>, IOrderableQuery<TEntity>, IQueryTracking;

// Derived: includes pagination
public record PageableQueryOption<TEntity> : QueryOption<TEntity>, IPageableQuery
{
    public Paging Page { get; init; } = new(0, 10);  // Default: page 0, 10 items
}

// Soft-delete aware variants
public record QueryOptionWithSoftDelete<TEntity> : QueryOption<TEntity>, IQueryOptionWithSoftDelete
{
    public bool IncludeDeleted { get; init; }
}

public record PageableQueryOptionWithSoftDelete<TEntity>
    : QueryOptionWithSoftDelete<TEntity>, IPageableQuery { }
```

#### Paging and PaginatedList<T>

```csharp
public record Paging(int PageIndex, int PageSize)
{
    public static Paging Default => new(0, 10);
    public int Offset => PageIndex * PageSize;
}

public record PagingMeta(int TotalCount, int PageIndex, int PageSize, int TotalPages)
{
    public bool HasPreviousPage => PageIndex > 0;
    public bool HasNextPage => PageIndex < TotalPages - 1;
}

public sealed class PaginatedList<T>
{
    public IReadOnlyList<T> Items { get; init; }
    public PagingMeta Meta { get; init; }
}
```

Pagination uses **offset-based paging** (`OFFSET @page * @size ROWS FETCH NEXT @size ROWS`). For large datasets, consider cursor-based paging with `OrderBy` on an indexed column.

#### Dynamic Filters and Orders

**Filter** encapsulates a single WHERE clause:

```csharp
public class Filter
{
    public string Field { get; set; }                 // Property name on the entity
    public FilterOperator Operator { get; set; }      // Equals, Contains, GreaterThan, etc.
    public object? Value { get; set; }                // Comparison value
    public bool IsNot { get; set; }                   // Negates condition
    public bool CaseSensitive { get; set; }           // For string comparisons
    public FilterLogic? Logic { get; set; }           // And / Or for grouping
    public ICollection<Filter>? Filters { get; init; } // Nested filter groups
}
```

Supported operators:

| Operator                               | Description              | Expected Value Type |
| -------------------------------------- | ------------------------ | ------------------- |
| `Equals` / `NotEquals`                 | Equality check           | Same as field type  |
| `Contains` / `StartsWith` / `EndsWith` | String pattern           | `string`            |
| `GreaterThan` / `GreaterThanOrEqual`   | Numeric/date comparison  | `IComparable`       |
| `LessThan` / `LessThanOrEqual`         | Numeric/date comparison  | `IComparable`       |
| `In`                                   | Membership in collection | `IEnumerable`       |
| `IsNull` / `IsNotNull`                 | Null check               | _none_              |

**Order** encapsulates an ORDER BY clause:

```csharp
public class Order
{
    public string Field { get; set; }          // Property name
    public OrderDirection Direction { get; set; } = OrderDirection.Asc;  // Asc or Desc
}
```

**DynamicQueryOption** combines filters, orders, and soft-delete options:

```csharp
public class DynamicQueryOption : IQueryOptionWithSoftDelete
{
    public IReadOnlyCollection<Filter>? Filters { get; init; }
    public IReadOnlyCollection<Order>? Orders { get; init; }
    public bool IncludeDeleted { get; init; }    // Override soft-delete filter
    public QueryTrackingMode Tracking { get; init; } = QueryTrackingMode.Default;
}
```

`PageableDynamicQueryOption` additionally includes a `Paging` property for paginated results.

### 4) EF Core Repository Implementation

`EFCoreRepository<TEntity, TId, TContext>` is an abstract partial base class that implements all repository interfaces. It inherits from `IReadRepository`, `IWriteRepository`, `IDynamicReadRepository`, `IQueryRepository`, and `IUnitOfWork`.

**Key implementation details:**

- **Tracking control**: Call `Query().AsNoTracking()` or pass `QueryTrackingMode.NoTracking` via `QueryOption`. Default is `QueryTrackingMode.Default` (EF Core default, typically tracking).
- **Result limiting**: Non-paginated queries respect `MaxResultSetSize` (10,000 records by default) and throw `InvalidOperationException` if exceeded. This prevents accidental OOM from unbounded queries.
- **Soft-delete filtering**: All queries automatically exclude soft-deleted entities via a global query filter (`QueryFilters.SoftDeletionArray`). Override with `IncludeDeleted: true` in `QueryOptionWithSoftDelete`.
- **Pagination**: Uses efficient `OFFSET-FETCH` via EF Core's `ToPaginatedListAsync()` extension. The extension builds `IQueryable<T>` → count query → page query in a single roundtrip.

#### Read Operations

```csharp
public virtual async Task<TEntity?> GetByIdAsync(TId id, ...)
{
    return await DbSet.FindAsync([id], cancellationToken);
}

public virtual async Task<TEntity?> GetAsync(Expression<Func<TEntity, bool>>? predicate = null, ...)
{
    IQueryable<TEntity> query = DbSet;
    if (predicate != null)
        query = query.Where(predicate);
    return await query.FirstOrDefaultAsync(cancellationToken);
}

public virtual async Task<IReadOnlyList<TEntity>> GetAllAsync(QueryOption<TEntity>? options = null, ...)
{
    IQueryable<TEntity> query = buildQuery(options);
    return await ExecuteWithLimitAsync(query, cancellationToken);
}
```

#### Write Operations

```csharp
public virtual async Task<TEntity> AddAsync(TEntity entity, ...)
{
    _ = await DbSet.AddAsync(entity, cancellationToken);
    return entity;
}

public virtual async Task<TEntity> UpdateAsync(TEntity entity, ...)
{
    // Fetch existing to attach concurrency token
    TEntity? existing = await DbSet.FindAsync([entity.Id], cancellationToken)
        ?? throw new InvalidOperationException($"Entity {typeof(TEntity).Name} with ID {entity.Id} not found.");

    if (!ReferenceEquals(existing, entity))
        applyConcurrencyValues(existing, entity);

    return existing;
}

private void applyConcurrencyValues(TEntity existing, TEntity callerEntity)
{
    byte[] callerRowVersion = callerEntity.RowVersion;
    Context.Entry(existing).CurrentValues.SetValues(callerEntity);
    Context.Entry(existing).Property(e => e.RowVersion).OriginalValue = callerRowVersion;
}
```

`UpdateAsync` never attaches the caller's entity directly. It retrieves the tracked entity from the context, copies values, and sets the original `RowVersion` to the caller's current version. This allows EF Core to detect concurrency conflicts during `SaveChangesAsync()`.

#### Bulk Operations

Bulk methods process entities in **chunks** (`MaxBatchSize = 1,000` by default), calling `SaveChangesAsync()` after each chunk. This limits transaction size and reduces memory pressure.

```csharp
public virtual async Task<ICollection<TEntity>> BulkAddAsync(ICollection<TEntity> entities, ...)
{
    foreach (var chunk in entities.Chunk(MaxBatchSize))
    {
        await DbSet.AddRangeAsync(chunk, cancellationToken);
        _ = await SaveChangesAsync(cancellationToken);
    }
    return entities;
}
```

#### Unit of Work

```csharp
public virtual async Task<int> SaveChangesAsync(CancellationToken cancellationToken = default)
{
    try
    {
        return await Context.SaveChangesAsync(cancellationToken);
    }
    catch (DbUpdateConcurrencyException ex)
    {
        var entry = ex.Entries[0];
        throw new ConcurrencyConflictException(
            $"A concurrency conflict was detected for {entry.Metadata.Name} with ID {entry.Property("Id").CurrentValue}...",
            entry.Metadata.Name,
            entry.Property("Id").CurrentValue?.ToString(),
            entry.Property("RowVersion").CurrentValue as byte[],
            entry.Property("RowVersion").OriginalValue as byte[],
            ex
        );
    }
}
```

Concurrency exceptions are translated from EF Core's `DbUpdateConcurrencyException` into the framework's `ConcurrencyConflictException`, which includes structured data (entity type, ID, current/original versions) for error handling and logging.

Transactions are explicit:

```csharp
await repository.BeginTransactionAsync(cancellationToken);
try
{
    await repo1.SaveChangesAsync(cancellationToken);
    await repo2.SaveChangesAsync(cancellationToken);
    await repo.CommitTransactionAsync(cancellationToken);
}
catch
{
    await repo.RollbackTransactionAsync(cancellationToken);
    throw;
}
```

All repositories sharing the same `DbContext` instance participate in the active transaction.

### 5) EF Core Extensions

#### SoftDeleteInterceptor

Automatically converts `DeleteAsync(entity)` into a soft-delete update for `ISoftDeletableEntity` types:

```csharp
public sealed class SoftDeletionInterceptor : SaveChangesInterceptor
{
    public int? MaxCascadeDepth { get; init; } = 50;

    public override InterceptionResult<int> SavingChanges(DbContextEventData eventData, ...)
    {
        DateTime now = DateTime.UtcNow;
        HashSet<object> visited = [];
        foreach (EntityEntry entry in GetEntriesToSoftDelete(eventData.Context))
            CascadeSoftDelete(eventData.Context!, entry, now, visited, 0, MaxCascadeDepth);
        return base.SavingChanges(eventData, result);
    }
}
```

**Cascade soft-delete** traverses navigation properties with `DeleteBehavior.Cascade` or `DeleteBehavior.ClientCascade`, marking related soft-deletable children as deleted before the parent save. It:

- Loads unloaded navigations on-demand
- Tracks visited entities to prevent infinite loops
- Respects the `MaxCascadeDepth` limit (throws if exceeded, indicating a potential cycle)

**Global query filter**: Entities marked `[SoftDelete]` or implementing `ISoftDeletableEntity` automatically receive a global filter (`WHERE IsDeleted = false`). Use `IncludeDeleted: true` in query options to bypass (e.g., administrative views).

#### AuditableInterceptor

Automatically sets `CreatedAt` and `UpdatedAt`:

```csharp
private static void UpdateTimestamps(DbContext? context)
{
    DateTime now = DateTime.UtcNow;
    foreach (EntityEntry entry in context.ChangeTracker.Entries())
    {
        if (entry.Entity is IAuditableEntity auditable)
        {
            if (entry.State == EntityState.Added && auditable.CreatedAt == default)
                auditable.CreatedAt = now;
            else if (entry.State == EntityState.Modified)
                auditable.UpdatedAt = now;
        }
    }
}
```

No manual timestamp management needed — simply implement `IAuditableEntity` and add the interceptor.

#### AuditLoggerInterceptor (optional)

Logs change details to `ILogger<TContext>` at `LogLevel.Information`. This is a separate optional interceptor for audit logging (e.g., who changed what and when). Check implementation for exact logged fields.

#### Configuring Interceptors

In your `InfrastructureServiceRegistrationExtensions.cs`:

```csharp
public static IServiceCollection AddInfrastructureServices(
    this IServiceCollection services,
    InfrastructureConfiguration config
)
{
    services.AddDbContext<BaseDbContext>(options =>
    {
        options.UseSqlite(config.ConnectionString);
        options.AddSoftDeleteInterceptor(maxCascadeDepth: 50);
        options.AddAuditableInterceptor();
        // options.AddAuditLoggerInterceptor();  // Optional
    });

    // Register repositories
    services.AddScoped(typeof(IRepository<>), typeof(EFCoreRepository<,,>));

    return services;
}
```

`EFCoreRepository` partial classes already implement the `AddInfrastructureServices` extension method that registers all generic repositories.

### 6) Dependency Injection Registration

The typical registration flow in a generated .NET service:

**Program.cs (WebApi layer):**

```csharp
var builder = WebApplication.CreateBuilder(args);

// Register Application layer (MediatR, validators, custom services)
builder.Services.AddApplicationLayer();

// Register Infrastructure layer (DbContext, repositories)
builder.Services.AddInfrastructureServices(
    builder.Configuration.GetInfrastructureConfiguration()
);

var app = builder.Build();
// Configure middleware...
app.Run();
```

`AddApplicationLayer()` comes from the application project and registers:

- `MediatR` assemblies (commands, queries, handlers)
- `FluentValidation` validators
- Custom application services

`AddInfrastructureServices()` comes from the infrastructure project and registers:

- `BaseDbContext` with configured connection string and interceptors
- Generic repository registration for each aggregate root
- Any external service adapters (email, storage, etc.)

**Infrastructure layer's registration extension:**

```csharp
public static class InfrastructureServiceRegistrationExtensions
{
    public static IServiceCollection AddInfrastructureServices(
        this IServiceCollection services,
        InfrastructureConfiguration config
    )
    {
        // DbContext registration
        services.AddDbContext<BaseDbContext>(options =>
            options.UseSqlite(config.ConnectionString)
                   .AddSoftDeleteInterceptor()
                   .AddAuditableInterceptor()
        );

        // Repository registration — explicit per aggregate
        services.AddScoped<IProductRepository, ProductRepository>();
        services.AddScoped<IOrderRepository, OrderRepository>();
        services.AddScoped<ICustomerRepository, CustomerRepository>();

        return services;
    }
}
```

Each repository interface inherits from multiple base contracts:

```csharp
internal interface IProductRepository
    : IReadRepository<Product, Guid>,
      IWriteRepository<Product, Guid>,
      IDynamicReadRepository<Product, Guid>,
      IUnitOfWork { }

internal sealed class ProductRepository(
    BaseDbContext context
) : EFCoreRepository<Product, Guid, BaseDbContext>(context),
    IProductRepository { }
```

This pattern:

- **Segregates read vs. write concerns** — handlers receive either read or write repositories as needed
- **Includes dynamic query support** — all repositories support dynamic filtering out of the box
- **Exposes UnitOfWork** — any repository can commit the transaction
- **Encapsulates concrete EF Core type** — the `DbContext` type is hidden behind interfaces

### 7) Data Lifecycle and Workflow

**Entity creation:**

1. Application layer constructs entity with explicit ID (`new Product(Guid.NewGuid())`)
2. Application calls `repository.AddAsync(entity)`
3. EF Core tracks entity as `Added`
4. `SaveChangesAsync()` is called
5. `AuditableInterceptor`\*\* sets `CreatedAt = DateTime.UtcNow` during `SavingChanges`
6. Database INSERT executes
7. RowVersion is populated from database
8. `SaveChangesAsync()` returns number of affected rows

**Entity update:**

1. Application fetches entity with `GetByIdAsync()` (or via query)
2. Application modifies property values
3. Application calls `UpdateAsync(modifiedEntity)` OR calls `SaveChangesAsync()` directly if entity is tracked
4. **Concurrency check**: EF Core compares original `RowVersion` (from tracked entity) with database value
5. If mismatch → `DbUpdateConcurrencyException` → caught → wrapped as `ConcurrencyConflictException`
6. If match → UPDATE executes; `AuditableInterceptor` sets `UpdatedAt = DateTime.UtcNow`

**Soft delete:**

1. Application calls `DeleteAsync(entity)`
2. EF Core marks entity as `Deleted`
3. `SoftDeletionInterceptor`\*\* intercepts `SavingChanges`, converts to `Modified` state
4. Sets `IsDeleted = true` and `DeletedAt = DateTime.UtcNow`
5. **Cascade soft-delete**: For each soft-deletable navigation, loads and marks as deleted recursively
6. Database UPDATE writes soft-delete flags

**Querying:**

```csharp
// Typed query
var product = await repo.GetByIdAsync(productId);

// Predicate query
var activeOrders = await repo.GetAllAsync(new QueryOption<Order>(
    Predicate: o => o.Status == OrderStatus.Active && o.Total > 100,
    OrderBy: o => o.OrderByDescending(o => o.CreatedAt)
));

// Dynamic query
var filters = new[]
{
    new Filter("Category", FilterOperator.Equals, "Electronics"),
    new Filter("Price", FilterOperator.GreaterThan, 100)
};
var options = new DynamicQueryOption(
    Filters: filters,
    Orders: [new Order("Price", OrderDirection.Desc)],
    Page: new Paging(0, 20)
);
var page = await repo.GetListByDynamicAsync(options);
```

## Error Handling Strategies

### Concurrency Conflicts

When `RowVersion` mismatches occur on UPDATE, `ConcurrencyConflictException` is thrown:

```csharp
try
{
    await repository.UpdateAsync(updatedProduct);
    await repository.SaveChangesAsync();
}
catch (ConcurrencyConflictException ex)
{
    // Structured error data available
    string type = ex.EntityType;     // "Product"
    string id = ex.EntityId;         // "a1b2c3..."
    byte[]? current = ex.CurrentVersion;
    byte[]? original = ex.OriginalVersion;

    // Typical resolution: refresh and retry
    var current = await repository.GetByIdAsync(id);
    // Merge changes from updatedProduct into current
    current.Name = updatedProduct.Name;
    current.Price = updatedProduct.Price;
    await repository.UpdateAsync(current);
    await repository.SaveChangesAsync();
}
```

### Validation

The repository interfaces do **not** perform validation. Validation happens earlier in the Application layer using `FluentValidation` validators attached to commands/queries. Keep domain validation rules in the Domain layer (entity methods, domain events).

### Database Errors

EF Core exceptions (e.g., `DbUpdateException`, `SqlException`) propagate out of the repository. Wrap repository calls in application services with try-catch to translate database-specific errors into user-friendly messages or domain-specific exceptions.

## Performance Considerations

### Benchmarks and Best Practices

1. **Use pagination**: The `DefaultMaxResultSetSize` (10,000) guard prevents catastrophic memory use. Prefer `GetListAsync()` over `GetAllAsync()` for large tables.

2. **Project when possible**: Instead of fetching full entities for read-only views, use `Select()` via `IQueryRepository.Query()` to project into DTOs:

   ```csharp
   var dtos = await productRepository.Query()
       .Where(p => p.IsActive)
       .Select(p => new ProductDto(p.Id, p.Name, p.Price))
       .ToListAsync();
   ```

3. **Index your query columns**: Dynamic queries translate directly to SQL. Ensure fields used in `Filter.Field` are indexed in the database.

4. **Batch bulk operations**: `BulkAdd/Update/Delete` process in chunks (1,000 default). Configure `MaxBatchSize` by overriding in derived repository:

   ```csharp
   protected override int MaxBatchSize => 5000;  // Larger batches for bulk imports
   ```

5. **Avoid cascade soft-delete on too-deep graphs**: The default `MaxCascadeDepth = 50` is a safety valve. Deep entity graphs (>50 levels) indicate modeling issues. Consider redesigning aggregates.

### AOT Considerations

**Native AOT publishing** (`PublishAot=true`) requires meticulous generic constraints using `[DynamicallyAccessedMembers]` attributes. The framework already adds these to public generic methods. If you extend the repository base, preserve attributes on your generic type parameters to avoid trim warnings.

**Dynamic queries are NOT AOT safe**. The `[RequiresUnreferencedCode]` attribute marks these methods. Calls to `GetByDynamicAsync` and similar will cause trim warnings. For AOT scenarios, avoid dynamic queries or isolate them behind an interface that's not called in AOT builds.

**Migrations**: `ApplyMigrationsAsync<TContext>()` is marked `[RequiresDynamicCode]` because EF Core needs to build the design-time model. For AOT deployments, consider:

- Pre-generating migration SQL scripts and applying them as part of the release pipeline
- Using **EF Core Migration Bundles** (self-contained executable that applies migrations at deploy time)

## Testing Guidance

### Unit Testing

Mock repository interfaces using your preferred mocking framework (Moq, NSubstitute, FakeItEasy). Because the repository interfaces are small and well-factored, you can also write **fake implementations** using in-memory collections:

```csharp
public class InMemoryProductRepository : IProductRepository
{
    private readonly Dictionary<Guid, Product> _store = new();

    public Task<Product?> GetByIdAsync(Guid id, CancellationToken ct)
        => Task.FromResult(_store.GetValueOrDefault(id));

    public Task<Product> AddAsync(Product product, CancellationToken ct)
    {
        _store[product.Id] = product;
        return Task.FromResult(product);
    }

    // Implement other methods...
}
```

For query methods, use `IQueryable` in-memory extensions:

```csharp
var queryable = _store.Values.AsQueryable();
var result = await queryable.Where(p => p.Price > 100).ToListAsync();
```

### Integration Testing

Use SQLite in-memory mode (`DataSource=:memory:`) with real EF Core:

```csharp
[Test]
public async Task ProductRepository_Update_PersistsChanges()
{
    var options = new DbContextOptionsBuilder<TestDbContext>()
        .UseSqlite("DataSource=:memory:")
        .Options;

    await using var context = new TestDbContext(options);
    await context.Database.OpenConnectionAsync();
    await context.Database.EnsureCreatedAsync();

    var repo = new ProductRepository(context);
    var product = new Product(Guid.NewGuid()) { Name = "Test", Price = 10 };
    await repo.AddAsync(product);
    await repo.SaveChangesAsync();

    product.Price = 20;
    await repo.UpdateAsync(product);
    await repo.SaveChangesAsync();

    var fromDb = await repo.GetByIdAsync(product.Id);
    fromDb.Price.Should().Be(20);
}
```

## Advanced Topics

### Custom Repository Implementation

When default `EFCoreRepository` behavior is insufficient, inherit and override specific methods:

```csharp
public partial class ProductRepository : EFCoreRepository<Product, Guid, BaseDbContext>
{
    protected override int? MaxResultSetSize => 1000;  // Stricter limit for this entity

    public async Task<Product?> GetBySkuAsync(string sku, CancellationToken ct = default)
    {
        return await DbSet.FirstOrDefaultAsync(p => p.Sku == sku, ct);
    }

    // You can also implement custom interface methods not on the base
    public async Task<IReadOnlyList<Product>> GetTopSellingAsync(int count, CancellationToken ct)
    {
        return await DbSet
            .OrderByDescending(p => p.SalesCount)
            .Take(count)
            .ToListAsync(ct);
    }
}
```

`partial` class design allows you to put custom logic in separate files while retaining generated code in `Features/Product/`.

### Soft Delete and Cascade Behavior Configuration

By default, all `ISoftDeletableEntity` entities automatically receive a global query filter:

```csharp
protected override void OnModelCreating(ModelBuilder modelBuilder)
{
    modelBuilder.ApplySoftDeleteQueryFilters();  // Extension from the framework
}
```

The interceptors are enabled via `DbContextOptionsBuilder`:

```csharp
services.AddDbContext<BaseDbContext>(options =>
{
    options.UseSqlite(connectionString);
    options.AddSoftDeleteInterceptor(maxCascadeDepth: 50);
    options.AddAuditableInterceptor();
});
```

### Entity Configuration

Use the provided `ModelBuilderExtensions` for conventions:

```csharp
public partial class BaseDbContext : DbContext
{
    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.ApplyConfigurationsFromAssembly(typeof(BaseDbContext).Assembly);
        modelBuilder.ConfigureEntityConventions();  // Sets default value generators
    }
}
```

Each entity has a corresponding `EntityConfiguration<TEntity, TId>` class in `Features/<Entity>/` that inherits from `IEntityTypeConfiguration<TEntity>`:

```csharp
public sealed class ProductConfiguration : IEntityTypeConfiguration<Product>
{
    public void Configure(EntityTypeBuilder<Product> builder)
    {
        builder.HasKey(p => p.Id);
        builder.Property(p => p.RowVersion)
            .IsRowVersion()
            .IsConcurrencyToken();
        builder.Property(p => p.Name)
            .HasMaxLength(200)
            .IsRequired();
        builder.HasIndex(p => p.Sku).IsUnique();
    }
}
```

### Multi-Tenancy

For multi-tenant applications, implement `ITenantEntity` and add a tenant discriminator filter:

```csharp
public interface ITenantEntity
{
    Guid TenantId { get; set; }
}

// In OnModelCreating:
modelBuilder.ApplyTenantFilter<ITenantEntity>(e => e.TenantId, currentTenantId);
```

Or use a **query-level** filter: pass `tenantId` via `QueryOption` and apply through an extension method that adds `Where(e => e.TenantId == tenantId)`.

### Integration with Application Layer (MediatR)

The typical handler pattern:

```csharp
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
        var product = new Product(request.Id, request.Name, request.Price);
        await _repository.AddAsync(product);
        await _repository.SaveChangesAsync(cancellationToken);

        return Result<ProductDto>.Success(product.ToDto());
    }
}
```

All handlers receive the repository via constructor injection. The repository is scoped (`AddScoped`) to the HTTP request, and `SaveChangesAsync` is called at the end of the handler to commit.

You can also **share UnitOfWork across multiple repositories**:

```csharp
public sealed class CreateOrderWithItemsHandler
    : IRequestHandler<CreateOrderCommand, Result<Guid>>
{
    private readonly IOrderRepository _orderRepo;
    private readonly IProductRepository _productRepo;

    public async Task<Result<Guid>> Handle(CreateOrderCommand request, CancellationToken ct)
    {
        // Both repositories share the same BaseDbContext instance (scoped)
        var order = new Order(request.Id, request.CustomerId);
        await _orderRepo.AddAsync(order);

        foreach (var item in request.Items)
        {
            var product = await _productRepo.GetByIdAsync(item.ProductId, ct);
            // ... business logic
            var orderItem = new OrderItem(Guid.NewGuid(), order.Id, product.Id, item.Quantity);
            await _orderRepo.AddAsync(orderItem);
        }

        await _orderRepo.SaveChangesAsync(ct); // Single transaction across both repos
        return Result<Guid>.Success(order.Id);
    }
}
```

## References

- [Entity Framework Core documentation](https://learn.microsoft.com/ef/core/)
- [Clean Architecture by Robert C. Martin](https://www.oreilly.com/library/view/clean-architecture/9780134494272/)
- [EF Core Interceptors](https://learn.microsoft.com/ef/core/logging-events-diagnostics/interceptors)
- [Optimistic Concurrency in EF Core](https://learn.microsoft.com/ef/core/concurrency/)
- [System.Linq.Dynamic.Core](https://github.com/StephanHoyer/System.Linq.Dynamic.Core)
- [Native AOT in .NET](https://learn.microsoft.com/dotnet/core/deploying/native-aot/)
