---
title: API Reference
description: Complete API reference for NFramework.Persistence, covering all entity base classes, repository interfaces, query options, pagination types, dynamic query infrastructure, EF Core extensions, and interceptors.
---

## Package Summary

| Package | Purpose | Dependencies |
|---------|---------|--------------|
| `NFramework.Persistence.Abstractions` | Contracts and base types (zero external dependencies) | None |
| `NFramework.Persistence.EFCore` | EF Core concrete implementations | `Microsoft.EntityFrameworkCore` |

Add package references in your infrastructure project:

```xml
<PackageReference Include="NFramework.Persistence.Abstractions" Version="1.0.0" />
<PackageReference Include="NFramework.Persistence.EFCore" Version="1.0.0" />
```

## Entity Base Classes

### Entity<TId>

Base class for all persistent entities with identity and optimistic concurrency token.

```csharp
public abstract class Entity<TId> where TId : IEquatable<TId>
```

**Implements:** `IEquatable<Entity<TId>>`

**Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `Id` | `TId` | Immutable primary key; set via constructor. |
| `RowVersion` | `byte[]` | Optimistic concurrency token; auto-managed by database. |

**Constructors:**

```csharp
// Application code: requires non-default ID
protected Entity(TId id);

// ORM-only: parameterless (marked obsolete)
[Obsolete("Use constructor with ID instead. This is only for ORM use.")]
protected Entity();
```

**Remarks:**
- The `[Obsolete]` constructor is required by EF Core for materialization during queries. Use `#pragma warning disable CS0618` in entity classes to suppress warnings.
- `RowVersion` is configured with `.IsRowVersion()` in EF Core fluent API; it's a `timestamp/rowversion` column in SQL Server or `BLOB` in SQLite.
- Equality is based on `Id` identity (value equality via `IEquatable<TId>`).

### AuditableEntity<TId>

Entity with automatic timestamp tracking. Implements `IAuditableEntity`.

```csharp
public abstract class AuditableEntity<TId> : Entity<TId>, IAuditableEntity
    where TId : IEquatable<TId>
```

**Additional Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `CreatedAt` | `DateTime` | Timestamp set when entity is first inserted (UTC). |
| `UpdatedAt` | `DateTime?` | Timestamp updated on every modification (UTC). |

**Methods:**

```csharp
public virtual IEnumerable<string> Validate()
```

Validates entity state. Returns `IEnumerable<string>` of validation errors.

**Example:**

```csharp
var entity = new MyAuditableEntity(id);
var errors = entity.Validate();  // Ensures CreatedAt is set
```

**Remarks:**
- Do not set `CreatedAt` or `UpdatedAt` manually — `AuditableInterceptor` handles this automatically.
- Validation ensures `CreatedAt != default` and `UpdatedAt >= CreatedAt` (if set).

### SoftDeletableEntity<TId>

Entity with soft-delete (logical delete) support. Implements `ISoftDeletableEntity`. Inherits from `AuditableEntity<TId>`.

```csharp
public abstract class SoftDeletableEntity<TId> : AuditableEntity<TId>, ISoftDeletableEntity
    where TId : IEquatable<TId>
```

**Additional Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `IsDeleted` | `bool` | Boolean flag; setting to `true` sets `DeletedAt = DateTime.UtcNow`. |
| `DeletedAt` | `DateTime?` | Deletion timestamp; setting to non-null sets `IsDeleted = true`. |

**Thread-safety:**
Both setters use `Interlocked.CompareExchange` to prevent recursion when one property sets the other.

**Example:**

```csharp
var entity = repository.GetByIdAsync(id).Result;
await repository.DeleteAsync(entity);      // Soft delete (sets IsDeleted = true)
await repository.SaveChangesAsync();
```

**Remarks:**
- `DeleteAsync()` in `EFCoreRepository` marks the entity as `EntityState.Deleted`. `SoftDeletionInterceptor` catches this during `SavingChanges` and converts it to `Modified`, setting `IsDeleted = true` and `DeletedAt = now`.
- Soft-deleted entities are automatically excluded from queries via a global query filter.
- To include deleted entities, pass `IncludeDeleted: true` in `QueryOptionWithSoftDelete`.

## Repository Interfaces

### IReadRepository<TEntity, TId>

Read-only repository contract.

```csharp
public interface IReadRepository<TEntity, TId> : IQueryRepository<TEntity, TId>
    where TEntity : Entity<TId>
    where TId : IEquatable<TId>
```

**Methods:**

| Method | Signature | Description |
|--------|-----------|-------------|
| `GetByIdAsync` | `Task<TEntity?> GetByIdAsync(TId id, CancellationToken ct = default)` | Primary key lookup using `DbSet.FindAsync()`. |
| `GetAsync` | `Task<TEntity?> GetAsync(Expression<Func<TEntity, bool>>? predicate = null, CancellationToken ct = default)` | Single entity, optionally filtered (`FirstOrDefaultAsync`). |
| `GetAllAsync` | `Task<IReadOnlyList<TEntity>> GetAllAsync(QueryOption<TEntity>? options = null, CancellationToken ct = default)` | Multiple entities with optional filtering/ordering/tracking. Respects `MaxResultSetSize`. |
| `GetListAsync` | `Task<PaginatedList<TEntity>> GetListAsync(PageableQueryOption<TEntity>? options = null, CancellationToken ct = default)` | Paginated query; returns items + pagination metadata. |
| `AnyAsync` | `Task<bool> AnyAsync(Expression<Func<TEntity, bool>>? predicate = null, CancellationToken ct = default)` | Existence check. |
| `CountAsync` | `Task<int> CountAsync(Expression<Func<TEntity, bool>>? predicate = null, CancellationToken ct = default)` | Count matching records. |

**Default behaviors:**

- Non-paginated queries (`GetAllAsync`) are limited to 10,000 records by default (configurable via `MaxResultSetSize`).
- Soft-deleted records are excluded automatically for `ISoftDeletableEntity` entities. Override with `IncludeDeleted: true` in query options.
- `AnyAsync()` without predicate checks `DbSet.AnyAsync()` (fast existence check).
- `CountAsync()` without predicate counts all rows (expensive on large tables).

### IWriteRepository<TEntity, TId>

Write repository contract for data modification.

```csharp
public interface IWriteRepository<TEntity, TId>
    where TEntity : Entity<TId>
    where TId : IEquatable<TId>
```

**Methods:**

| Method | Signature | Description |
|--------|-----------|-------------|
| `AddAsync` | `Task<TEntity> AddAsync(TEntity entity, CancellationToken ct = default)` | Inserts new entity; tracks as `Added`. |
| `UpdateAsync` | `Task<TEntity> UpdateAsync(TEntity entity, CancellationToken ct = default)` | Attaches entity with concurrency check; updates tracked entity's values; does NOT call `SaveChangesAsync()` yet. |
| `UpsertAsync` | `Task<TEntity> UpsertAsync(TEntity entity, CancellationToken ct = default)` | Insert if `Id` not found; otherwise update with concurrency check. |
| `DeleteAsync` | `Task<TEntity> DeleteAsync(TEntity entity, CancellationToken ct = default)` | Marks entity as `Deleted`. Soft-delete interceptors convert to update for `ISoftDeletableEntity`. |
| `BulkAddAsync` | `Task<ICollection<TEntity>> BulkAddAsync(ICollection<TEntity> entities, CancellationToken ct = default)` | Inserts in chunks of `MaxBatchSize` (default 1,000), calling `SaveChangesAsync()` after each chunk. |
| `BulkUpdateAsync` | `Task<ICollection<TEntity>> BulkUpdateAsync(ICollection<TEntity> entities, CancellationToken ct = default)` | Updates in chunks; marks all as `Modified`. |
| `BulkDeleteAsync` | `Task<ICollection<TEntity>> BulkDeleteAsync(ICollection<TEntity> entities, CancellationToken ct = default)` | Deletes in chunks; soft-delete interceptors apply. |

**Important:**
- `UpdateAsync()` does not attach the caller's entity instance directly. It fetches the existing tracked entity, copies values with `DbContext.Entry(existing).CurrentValues.SetValues(callerEntity)`, and sets original `RowVersion` to the caller's value for concurrency checking.
- Bulk operations use `SaveChangesAsync()` after each chunk. Consider wrapping in an explicit transaction if you need atomicity across all batches.

### IDynamicReadRepository<TEntity, TId>

Runtime-dynamic query interface backed by System.Linq.Dynamic.Core.

```csharp
public interface IDynamicReadRepository<TEntity, TId>
    where TEntity : Entity<TId>
    where TId : IEquatable<TId>
```

**Methods (all marked `[RequiresUnreferencedCode]`):**

| Method | Signature | Returns |
|--------|-----------|---------|
| `GetByDynamicAsync` | `Task<TEntity?> GetByDynamicAsync(DynamicQueryOption options, CancellationToken ct = default)` | First matching entity or `null`. |
| `GetAllByDynamicAsync` | `Task<IReadOnlyList<TEntity>> GetAllByDynamicAsync(DynamicQueryOption options, CancellationToken ct = default)` | All matching (limited to `MaxResultSetSize`). |
| `GetListByDynamicAsync` | `Task<PaginatedList<TEntity>> GetListByDynamicAsync(PageableDynamicQueryOption options, CancellationToken ct = default)` | Paginated result. |
| `AnyByDynamicAsync` | `Task<bool> AnyByDynamicAsync(DynamicQueryOption options, CancellationToken ct = default)` | Existence check. |
| `CountByDynamicAsync` | `Task<int> CountByDynamicAsync(DynamicQueryOption options, CancellationToken ct = default)` | Count of matches. |

**AOT Warning:** These methods rely on reflection-based expression parsing and are **not compatible with Native AOT**. Use typed queries (`GetAllAsync(predicate)`) instead for AOT scenarios.

### IQueryRepository<TEntity, TId>

Exposes raw `IQueryable<TEntity>` for maximum flexibility.

```csharp
public interface IQueryRepository<TEntity, TId>
    where TEntity : Entity<TId>
    where TId : IEquatable<TId>
```

**Methods:**

```csharp
IQueryable<TEntity> Query();
```

**Usage:**

```csharp
var query = _repository.Query()
    .Where(p => p.Price > 100)
    .OrderBy(p => p.Name)
    .Select(p => new ProductDto(p.Id, p.Name, p.Price));
var results = await query.ToListAsync(ct);
```

**Note:** The returned queryable is `AsNoTracking()` by default (via `QueryOption.Tracking = QueryTrackingMode.NoTracking`). If you need tracking, pass `QueryTrackingMode.Tracking` in query options instead of using `Query()`.

### IUnitOfWork

Coordinates repository transactions and persistence.

```csharp
public interface IUnitOfWork
{
    Task<int> SaveChangesAsync(CancellationToken cancellationToken = default);
    Task BeginTransactionAsync(CancellationToken cancellationToken = default);
    Task CommitTransactionAsync(CancellationToken cancellationToken = default);
    Task RollbackTransactionAsync(CancellationToken cancellationToken = default);
}
```

**Key points:**
- Every `EFCoreRepository` implements `IUnitOfWork`. Any repository instance can commit changes.
- All repositories constructed with the **same `DbContext` instance** share the same transaction. The typical DI scope (web request) guarantees this.
- `SaveChangesAsync()` is where interceptors fire and database round-trips occur.
- Explicit transactions (`BeginTransactionAsync` / `CommitTransactionAsync`) span multiple `SaveChangesAsync()` calls.

## Query Option Types

### QueryOption<TEntity>

Encapsulates standard query parameters.

```csharp
public record QueryOption<TEntity>(
    Expression<Func<TEntity, bool>>? Predicate = null,
    Func<IQueryable<TEntity>, IOrderedQueryable<TEntity>>? OrderBy = null,
    QueryTrackingMode Tracking = QueryTrackingMode.Default
) : IFilterableQuery<TEntity>, IOrderableQuery<TEntity>, IQueryTracking;
```

**Properties:**

| Property | Type | Description |
|----------|------|-------------|
| `Predicate` | `Expression<Func<TEntity, bool>>?` | WHERE clause filter. |
| `OrderBy` | `Func<IQueryable<TEntity>, IOrderedQueryable<TEntity>>?` | ORDER BY delegate (e.g., `q => q.OrderBy(e => e.Name)`). |
| `Tracking` | `QueryTrackingMode` | `Tracking` (default) or `NoTracking`. |

**Example:**

```csharp
var options = new QueryOption<Product>(
    Predicate: p => p.IsActive && p.Price < 100,
    OrderBy: q => q.OrderByDescending(p => p.CreatedAt),
    Tracking: QueryTrackingMode.NoTracking
);
var results = await repo.GetAllAsync(options);
```

### PageableQueryOption<TEntity>

Adds pagination to `QueryOption<TEntity>`.

```csharp
public record PageableQueryOption<TEntity> : QueryOption<TEntity>, IPageableQuery
{
    public Paging Page { get; init; } = new(0, 10);
}
```

**Paging defaults:** page index 0 (first page), page size 10.

**Example:**

```csharp
var options = new PageableQueryOption<Product>(
    Predicate: p => p.Category == "Electronics",
    OrderBy: q => q.OrderBy(p => p.Name),
    Page: new Paging(0, 20)  // First 20 results
);
var page = await repo.GetListAsync(options);
Console.WriteLine($"Total items: {page.Meta.TotalCount}");
```

### QueryOptionWithSoftDelete<TEntity>

Includes soft-delete override.

```csharp
public record QueryOptionWithSoftDelete<TEntity> : QueryOption<TEntity>, IQueryOptionWithSoftDelete
{
    public bool IncludeDeleted { get; init; }
}
```

Use for administrative views requiring access to soft-deleted records:

```csharp
var adminOptions = new QueryOptionWithSoftDelete<Product>(IncludeDeleted: true);
var allProducts = await repo.GetAllAsync(adminOptions);
```

Derived types: `PageableQueryOptionWithSoftDelete<TEntity>` combines pagination + soft-delete override.

### DynamicQueryOption

String-based dynamic query with filter and order collections.

```csharp
public class DynamicQueryOption : IQueryOptionWithSoftDelete
{
    public IReadOnlyCollection<Filter>? Filters { get; init; }
    public IReadOnlyCollection<Order>? Orders { get; init; }
    public bool IncludeDeleted { get; init; }
    public QueryTrackingMode Tracking { get; init; } = QueryTrackingMode.Default;
}
```

**Example:**

```csharp
var options = new DynamicQueryOption
{
    Filters =
    [
        new Filter("Category", FilterOperator.Equals, "Books"),
        new Filter(
            logic: FilterLogic.Or,
            filters: new[]
            {
                new Filter("Price", FilterOperator.LessThan, 20),
                new Filter("Price", FilterOperator.GreaterThan, 100)
            })
    ],
    Orders = [new Order("CreatedAt", OrderDirection.Desc)],
    Tracking = QueryTrackingMode.NoTracking
};

var results = await repo.GetAllByDynamicAsync(options);
```

### PageableDynamicQueryOption

`DynamicQueryOption` with pagination.

```csharp
public class PageableDynamicQueryOption : DynamicQueryOption, IPageableQuery
{
    public Paging Page { get; init; } = new(0, 10);
}
```

**Example:**

```csharp
var pageOptions = new PageableDynamicQueryOption
{
    Filters = [new Filter("Status", FilterOperator.Equals, "Active")],
    Orders = [new Order("Name")],
    Page = new Paging(pageIndex: 0, pageSize: 50)
};
var paged = await repo.GetListByDynamicAsync(pageOptions);
```

## Pagination Types

### Paging

```csharp
public readonly record struct Paging(int PageIndex, int PageSize)
```

**Static members:**

- `Paging.Default` → `{ PageIndex = 0, PageSize = 10 }`

**Computed properties:**

- `Offset` → `PageIndex * PageSize`

### PagingMeta

Metadata for paginated responses.

```csharp
public record PagingMeta(
    int TotalCount,
    int PageIndex,
    int PageSize,
    int TotalPages
)
```

**Computed properties:**

- `HasPreviousPage` → `PageIndex > 0`
- `HasNextPage` → `PageIndex < TotalPages - 1`

**Example:**

```csharp
var paged = await repo.GetListAsync(new PageableQueryOption<Product>());
Console.WriteLine($"Page {paged.Meta.PageIndex + 1} of {paged.Meta.TotalPages}");
Console.WriteLine($"Total: {paged.Meta.TotalCount} items");
```

### PaginatedList<T>

Container for paginated results.

```csharp
public record PaginatedList<T>
{
    public IReadOnlyList<T> Items { get; init; }
    public PagingMeta Meta { get; init; }

    public PaginatedList(IReadOnlyList<T> items, PagingMeta meta);
}
```

**Validation:** Throws `ArgumentException` if `items.Count > meta.TotalCount`.

## Dynamic Query Types

### FilterOperator

Enum of supported operators for dynamic filters:

```csharp
public enum FilterOperator
{
    Equals,
    NotEquals,
    Contains,
    StartsWith,
    EndsWith,
    GreaterThan,
    GreaterThanOrEqual,
    LessThan,
    LessThanOrEqual,
    In,
    IsNull,
    IsNotNull
}
```

**Type safety notes:**

- `In` expects `Value` to be `IEnumerable` (collection).
- `IsNull` / `IsNotNull` ignore `Value` (should be `null`).

### FilterLogic

Enum for combining multiple filters:

```csharp
public enum FilterLogic
{
    And,
    Or
}
```

### OrderDirection

Enum for sort direction:

```csharp
public enum OrderDirection
{
    Asc,
    Desc
}
```

### Filter

Dynamic filter specification.

```csharp
public class Filter
{
    public string Field { get; set; }                    // Property name on entity
    public FilterOperator Operator { get; set; }         // Comparison operator
    public object? Value { get; set; }                   // Comparison value
    public bool IsNot { get; set; }                      // Negate condition
    public bool CaseSensitive { get; set; }              // Case-sensitivity for string ops
    public FilterLogic? Logic { get; set; }              // Logic for nested group
    public ICollection<Filter>? Filters { get; init; }  // Nested filter group
}
```

**Constructors:**

```csharp
// Simple filter (field + operator + value)
public Filter(string field, FilterOperator @operator, object? value = null);

// Group filter (logic + nested filters)
public Filter(FilterLogic logic, ICollection<Filter> filters);
```

**Validation:**
- `Validate()` returns `IEnumerable<string>` of validation errors.
- Simple filter requires `Field` non-empty, `Value` present for non-null-check operators.
- Group filter requires `Filters` non-empty; simple filters cannot have nested `Filters`.

**Example:**

```csharp
var filter = new Filter("Name", FilterOperator.Contains, "test")
{
    CaseSensitive = false
};

var group = new Filter(FilterLogic.And, new Filter[]
{
    new Filter("Price", FilterOperator.GreaterThan, 10),
    new Filter("Price", FilterOperator.LessThan, 100)
});
```

### Order

Dynamic order specification.

```csharp
public class Order
{
    public string Field { get; set; }          // Property name
    public OrderDirection Direction { get; set; } = OrderDirection.Asc;
}
```

**Constructor:**

```csharp
public Order(string field, OrderDirection direction = OrderDirection.Asc);
```

**Example:**

```csharp
var order = new Order("CreatedAt", OrderDirection.Desc);
```

## Query Tracking Mode

### QueryTrackingMode

Controls whether queries return tracked or untracked entities.

```csharp
public enum QueryTrackingMode
{
    Default,    // EF Core default (usually tracking)
    Tracking,   // Explicitly track entities
    NoTracking  // Do not track — better for read-only queries
}
```

**Usage:**

```csharp
var options = new QueryOption<Product>(Tracking: QueryTrackingMode.NoTracking);
var products = await repo.GetAllAsync(options);
```

When `NoTracking` is set, the repository applies `AsNoTracking()` to the query. This improves read performance and reduces memory pressure on the `DbContext`.

## EF Core Repository Base

### EFCoreRepository<TEntity, TId, TContext>

Abstract base class providing full implementation of NFramework repository contracts.

**Generic Constraints:**

```csharp
public abstract partial class EFCoreRepository<
    [DynamicallyAccessedMembers(
        DynamicallyAccessedMemberTypes.PublicConstructors
            | DynamicallyAccessedMemberTypes.NonPublicConstructors
            | DynamicallyAccessedMemberTypes.PublicFields
            | DynamicallyAccessedMemberTypes.NonPublicFields
            | DynamicallyAccessedMemberTypes.PublicProperties
            | DynamicallyAccessedMemberTypes.NonPublicProperties
            | DynamicallyAccessedMemberTypes.Interfaces)]
    TEntity,
    TId,
    TContext
>(TContext context)
    : IReadRepository<TEntity, TId>,
      IWriteRepository<TEntity, TId>,
      IDynamicReadRepository<TEntity, TId>,
      IQueryRepository<TEntity, TId>,
      IUnitOfWork
    where TEntity : Entity<TId>
    where TId : IEquatable<TId>
    where TContext : DbContext
```

**Protected members:**

| Member | Type | Description |
|--------|------|-------------|
| `Context` | `TContext` | The underlying `DbContext`. |
| `DbSet` | `DbSet<TEntity>` | The entity set for this repository. |
| `MaxResultSetSize` | `int?` | Maximum results for non-paginated queries (default 10,000). Override to customize. |
| `MaxBatchSize` | `int` | Maximum entities per bulk operation chunk (default 1,000). Override to customize. |

**Protected methods:**

```csharp
protected async Task<IReadOnlyList<TEntity>> ExecuteWithLimitAsync(
    IQueryable<TEntity> query,
    CancellationToken cancellationToken
)
```

Enforces `MaxResultSetSize`. Throws `InvalidOperationException` if limit exceeded.

**Inheriting:**

```csharp
internal sealed class ProductRepository(
    MyServiceDbContext context
) : EFCoreRepository<Product, Guid, MyServiceDbContext>(context),
    IProductRepository
{
    protected override int? MaxResultSetSize => 5000;  // Custom limit for Products
}
```

### EFCoreRepository.Read.cs partial

All read operation implementations live here. Methods:

- `GetByIdAsync(TId id, CancellationToken)`
- `GetAsync(Expression<Func<TEntity, bool>>? predicate, CancellationToken)`
- `GetAllAsync(QueryOption<TEntity>? options, CancellationToken)`
- `GetListAsync(PageableQueryOption<TEntity>? options, CancellationToken)`
- `AnyAsync(Expression<Func<TEntity, bool>>? predicate, CancellationToken)`
- `CountAsync(Expression<Func<TEntity, bool>>? predicate, CancellationToken)`

`Query()` returns `DbSet.AsNoTracking()`.

**Soft-delete handling:**

```csharp
if (options is IQueryOptionWithSoftDelete { IncludeDeleted: true })
    query = query.IgnoreQueryFilters(QueryFilters.SoftDeletionArray);
```

Soft-delete filter is defined in `QueryFilters.SoftDeletionArray` constant.

### EFCoreRepository.Write.cs partial

All write operation implementations:

- `AddAsync(TEntity entity, CancellationToken)` — Adds to `DbSet`.
- `UpdateAsync(TEntity entity, CancellationToken)` — Fetches existing, copies values, preserves original `RowVersion`.
- `UpsertAsync(TEntity entity, CancellationToken)` — Insert or update.
- `DeleteAsync(TEntity entity, CancellationToken)` — Marks as `Deleted`.
- `BulkAddAsync(ICollection<TEntity> entities, CancellationToken)`
- `BulkUpdateAsync(ICollection<TEntity> entities, CancellationToken)`
- `BulkDeleteAsync(ICollection<TEntity> entities, CancellationToken)`
- `SaveChangesAsync(CancellationToken)` — wraps `Context.SaveChangesAsync()`, catches `DbUpdateConcurrencyException` and rethrows as `ConcurrencyConflictException`.

**Concurrency handling:**

```csharp
private void applyConcurrencyValues(TEntity existing, TEntity callerEntity)
{
    byte[] callerRowVersion = callerEntity.RowVersion;
    Context.Entry(existing).CurrentValues.SetValues(callerEntity);
    Context.Entry(existing).Property(e => e.RowVersion).OriginalValue = callerRowVersion;
}
```

EF Core generates SQL with `WHERE RowVersion = @originalVersion`. If no rows affected → concurrency conflict.

### EFCoreRepository.Query.cs partial

```csharp
public IQueryable<TEntity> Query() => DbSet.AsNoTracking();
```

### EFCoreRepository.DynamicRead.cs partial

Dynamic methods using System.Linq.Dynamic.Core:

```csharp
[RequiresUnreferencedCode("Dynamic query translation uses reflection-based System.Linq.Dynamic.Core...")]
public virtual async Task<TEntity?> GetByDynamicAsync(DynamicQueryOption options, ...)
```

Translates `Filter` objects to Dynamic LINQ expressions via `DynamicQueryExtensions.ApplyFilters()` and `ApplyOrders()`.

## Query Extensions (EFCore)

### DynamicQueryExtensions

Converts `Filter`/`Order` objects to Dynamic LINQ expressions.

```csharp
public static IQueryable<T> ApplyFilters<T>(
    this IQueryable<T> source,
    IReadOnlyCollection<Filter>? filters
)
```

**Method chain:**

```
source → ApplyFilters(filters) → ApplyOrders(orders) → ApplyTracking(options)
```

**Usage (internal):**

Repository calls `buildDynamicQuery()` which composes extensions.

**For custom query composition:**

```csharp
var query = _repository.Query()
    .ApplyFilters(myFilters)
    .ApplyOrders(myOrders);
```

### PaginationExtensions

```csharp
public static async Task<PaginatedList<T>> ToPaginatedListAsync<T>(
    this IQueryable<T> source,
    Paging paging,
    CancellationToken cancellationToken = default
)
```

Executes two queries:

1. `await source.CountAsync(ct)` → `TotalCount`
2. `await source.Skip(paging.Offset).Take(paging.PageSize).ToListAsync(ct)` → `Items`

Returns `new PaginatedList<T>(items, new PagingMeta(total, paging.PageIndex, paging.PageSize, totalPages))`.

### QueryTrackingExtensions

```csharp
public static IQueryable<T> ApplyTracking<T>(
    this IQueryable<T> query,
    QueryTrackingMode? mode
)
```

Sets tracking behavior:

- `Tracking` → `query = query` (no change)
- `NoTracking` → `query = query.AsNoTracking()`
- `null` → no change

### ModelBuilderExtensions

Conventions and soft-delete filter setup.

```csharp
public static ModelBuilder ConfigureEntityConventions(this ModelBuilder modelBuilder)
```

Applies:
- Default value generation for `CreatedAt`/`UpdatedAt` (set by interceptor, not needed)
- Configures decimal precision, string lengths

```csharp
public static ModelBuilder ConfigureSoftDeleteFilter<TContext>(this ModelBuilder modelBuilder)
    where TContext : DbContext
```

Applies global query filter to all entities implementing `ISoftDeletableEntity`:

```csharp
builder.HasQueryFilter(e => !((ISoftDeletableEntity)e).IsDeleted);
```

Use in `BaseDbContext.OnModelCreating`:

```csharp
protected override void OnModelCreating(ModelBuilder modelBuilder)
{
    modelBuilder.ApplyConfigurationsFromAssembly(typeof(BaseDbContext).Assembly);
    modelBuilder.ConfigureSoftDeleteFilter<BaseDbContext>();
}
```

## Interceptors

Interceptors hook into EF Core's command pipeline. Register via `DbContextOptionsBuilder`.

### AuditableInterceptor

Automatically sets `CreatedAt` and `UpdatedAt` for `IAuditableEntity` entities.

```csharp
public sealed class AuditableInterceptor : SaveChangesInterceptor
{
    public override InterceptionResult<int> SavingChanges(
        DbContextEventData eventData,
        InterceptionResult<int> result
    )
    {
        UpdateTimestamps(eventData.Context);
        return base.SavingChanges(eventData, result);
    }

    public override async ValueTask<InterceptionResult<int>> SavingChangesAsync(
        DbContextEventData eventData,
        InterceptionResult<int> result,
        CancellationToken cancellationToken = default
    )
    {
        UpdateTimestamps(eventData.Context);
        return await base.SavingChangesAsync(eventData, result, cancellationToken);
    }

    private static void UpdateTimestamps(DbContext? context) { /* ... */ }
}
```

**Behavior:**
- `Added` state → `CreatedAt = DateTime.UtcNow` (only if current value is `default`)
- `Modified` state → `UpdatedAt = DateTime.UtcNow`

**Registration:**

```csharp
services.AddDbContext<MyDbContext>(options =>
    options.AddAuditableInterceptor()
);
```

### SoftDeletionInterceptor

Intercepts entity deletions and converts them to soft-delete updates for `ISoftDeletableEntity` entities. Also cascades soft-delete through navigations.

```csharp
public sealed class SoftDeletionInterceptor : SaveChangesInterceptor
{
    public int? MaxCascadeDepth { get; init; } = 50;

    public override InterceptionResult<int> SavingChanges(
        DbContextEventData eventData,
        InterceptionResult<int> result
    )
    {
        var entriesToSoftDelete = GetEntriesToSoftDelete(eventData.Context);
        foreach (var entry in entriesToSoftDelete)
            CascadeSoftDelete(context, entry, DateTime.UtcNow, [], 0, MaxCascadeDepth);
        return base.SavingChanges(eventData, result);
    }

    // Async overload also provided
}
```

**Cascade soft-delete:**

- Traverses navigation properties with `DeleteBehavior.Cascade` or `DeleteBehavior.ClientCascade`
- Loads unloaded navigations (`collectionEntry.Load()` or `referenceEntry.Load()`)
- Prevents cycles via `HashSet<object> visited`
- Respects `MaxCascadeDepth` limit (default 50)

**Registration:**

```csharp
services.AddDbContext<MyDbContext>(options =>
    options.AddSoftDeleteInterceptor(maxCascadeDepth: 50)
);
```

### AuditLoggerInterceptor

(Optional) Logs audit information to `ILogger<TContext>`.

Not documented in detail here — see source for exact log format and events.

### Interceptor Registration Order

Interceptors execute in **registration order**. Recommended order:

1. `AddAuditableInterceptor()` — first to set timestamps
2. `AddSoftDeleteInterceptor()` — second to process soft delete
3. `AddAuditLoggerInterceptor()` — last to log final state after other interceptors

```csharp
options
    .AddAuditableInterceptor()
    .AddSoftDeleteInterceptor()
    .AddAuditLoggerInterceptor();
```

## Exceptions

### ConcurrencyConflictException

Thrown when optimistic concurrency check fails (RowVersion mismatch).

```csharp
public sealed class ConcurrencyConflictException : Exception
{
    public string? EntityType { get; }
    public string? EntityId { get; }
    public byte[]? CurrentVersion { get; }
    public byte[]? OriginalVersion { get; }

    public ConcurrencyConflictException();
    public ConcurrencyConflictException(string message);
    public ConcurrencyConflictException(string message, Exception inner);
    public ConcurrencyConflictException(
        string message,
        string? entityType,
        string? entityId,
        byte[]? currentVersion,
        byte[]? originalVersion,
        Exception? inner = null
    );
}
```

**Usage:**

```csharp
try
{
    await repo.UpdateAsync(entity);
    await repo.SaveChangesAsync(ct);
}
catch (ConcurrencyConflictException ex)
{
    // Structured data
    string type = ex.EntityType;
    string id = ex.EntityId;
    byte[] dbVersion = ex.CurrentVersion;
    byte[] clientVersion = ex.OriginalVersion;

    // Resolve: re-fetch, apply changes, retry
    var current = await repo.GetByIdAsync(ex.EntityId, ct);
    // merge changes...
    await repo.UpdateAsync(current);
    await repo.SaveChangesAsync(ct);
}
```

## Configuration Classes

### DatabaseConfiguration

Used to bind persistence configuration from `appsettings.json`.

```csharp
public sealed class DatabaseConfiguration
{
    public string ConnectionString { get; init; } = "Data Source=local.db";
    public bool ApplyMigrationsOnStartup { get; init; } = true;
    public int? SoftDeleteCascadeDepth { get; init; } = 50;
}
```

**Example binding:**

```csharp
builder.Services.Configure<DatabaseConfiguration>(
    builder.Configuration.GetSection("Infrastructure:Persistence")
);
```

## Extension Methods Summary

### For DbContextOptionsBuilder

| Method | Description |
|--------|-------------|
| `AddSoftDeleteInterceptor(int? maxCascadeDepth = 50)` | Adds soft-delete interceptor. |
| `AddAuditableInterceptor()` | Adds timestamp management interceptor. |
| `AddAuditLoggerInterceptor()` | Adds audit logging interceptor. |

### For ModelBuilder

| Method | Description |
|--------|-------------|
| `ConfigureEntityConventions()` | Applies framework-wide conventions (value generators, precision, etc.). |
| `ConfigureSoftDeleteFilter<TContext>()` | Applies global query filter for `ISoftDeletableEntity` types. |
| `ApplyConfigurationsFromAssembly(Assembly)` | Standard EF Core — applies all `IEntityTypeConfiguration<T>` implementations. |

### For IQueryable<T>

| Method | Description |
|--------|-------------|
| `ApplyTracking(QueryTrackingMode?)` | Applies `AsNoTracking()` if mode is `NoTracking`. |
| `ApplyFilters(IReadOnlyCollection<Filter>?)` | Applies dynamic filter collection. |
| `ApplyOrders(IReadOnlyCollection<Order>?)` | Applies dynamic ordering. |
| `ToPaginatedListAsync(Paging, CancellationToken)` | Executes count + page query, returns `PaginatedList<T>`. |

### For IHost

| Method | Description |
|--------|-------------|
| `ApplyMigrationsAsync<TContext>()` | Applies pending migrations at startup. Marked `[RequiresDynamicCode]` — not AOT-compatible. |

### For IServiceCollection

Standard Microsoft.Extensions.DependencyInjection extensions — no special extensions provided. Use standard `AddDbContext<T>()`, `AddScoped<TInterface, TImplementation>()`.

## Constants and Static Data

### QueryFilters

Static class holding global query filter definitions.

```csharp
internal static class QueryFilters
{
    public static readonly object[] SoftDeletionArray = new object[] { false };
}
```

The soft deletion filter (`IsDeleted == false`) compiles this constant to avoid closure allocation.

## Attribute Reference

For AOT scenarios, these attributes are used throughout:

- `[DynamicallyAccessedMembers]` — ensures the AOT trimmer preserves members needed for EF Core reflection. Preserve on your own generic type parameters when extending `EFCoreRepository`.
- `[RequiresUnreferencedCode]` — indicates the method uses reflection (dynamic queries). Causes warnings under AOT publish.
- `[RequiresDynamicCode]` — indicates the method requires runtime code generation (migrations). Not AOT-compatible.

## Source Code Locations

| Class | File |
|-------|------|
| `Entity<TId>`, `AuditableEntity<TId>`, `SoftDeletableEntity<TId>` | `NFramework.Persistence.Abstractions/Entities/` |
| Repository interfaces (`IReadRepository`, etc.) | `NFramework.Persistence.Abstractions/Repositories/` |
| `EFCoreRepository` base + partials | `NFramework.Persistence.EFCore/Repositories/` |
| Interceptors | `NFramework.Persistence.EFCore/Interceptors/` |
| Extensions | `NFramework.Persistence.EFCore/Extensions/` |
| Dynamic query types | `NFramework.Persistence.Abstractions/Dynamic/` |
| Pagination types | `NFramework.Persistence.Abstractions/Pagination/` |
| Exceptions | `NFramework.Persistence.Abstractions/Exceptions/` |
| `ConcurrencyConflictException` | `NFramework.Persistence.Abstractions/Exceptions/` |

## Version Notes

- **v1.0.0 (current)** — First stable release with EF Core + SQLite/SQL Server/PostgreSQL support
- Breaking changes: None yet — API surface is considered stable with semantic versioning

For detailed type signatures, consult the XML documentation comments in the source code. Every public member contains XML docs for IntelliSense support in IDE.
