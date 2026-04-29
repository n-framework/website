---
title: Query System
description: Query options, pagination, dynamic filters, ordering, and tracking control in NFramework Persistence. Learn to build typed and dynamic queries efficiently.
---

## Introduction

NFramework's query system abstracts query construction through **option objects** (`QueryOption<T>`, `PageableQueryOption<T>`, `DynamicQueryOption`) rather than method overload explosion. This keeps signatures clean while supporting filtering, ordering, pagination, soft-delete overrides, and tracking control in a single parameter.

The system supports two query styles:

1. **Typed queries** — strongly-typed LINQ expressions via `IReadRepository` — compile-time safety, AOT-friendly
2. **Dynamic queries** — string-based field names via `IDynamicReadRepository` — runtime flexibility, reflection-based, NOT AOT-safe

Both styles use the same pagination types (`Paging`, `PaginatedList<T>`) and soft-delete overrides.

## QueryOption Hierarchy

```
QueryOption<TEntity> (base: no pagination)
  └── PageableQueryOption<TEntity> (adds Paging)
       └── PageableQueryOptionWithSoftDelete<TEntity> (adds IncludeDeleted)

QueryOptionWithSoftDelete<TEntity> (sibling: adds IncludeDeleted to base)
  └── PageableQueryOptionWithSoftDelete<TEntity> (combines both)
```

### QueryOption<TEntity>

Base record encapsulating a non-paginated query.

```csharp
public record QueryOption<TEntity>(
    Expression<Func<TEntity, bool>>? Predicate = null,
    Func<IQueryable<TEntity>, IOrderedQueryable<TEntity>>? OrderBy = null,
    QueryTrackingMode Tracking = QueryTrackingMode.Default
) : IFilterableQuery<TEntity>, IOrderableQuery<TEntity>, IQueryTracking;
```

**Properties:**

| Property | Type | Purpose |
|----------|------|---------|
| `Predicate` | `Expression<Func<TEntity, bool>>?` | WHERE clause filter. Can be `null` for no filter. |
| `OrderBy` | `Func<IQueryable<TEntity>, IOrderedQueryable<TEntity>>?` | ORDER BY delegate (e.g., `q => q.OrderByDescending(e => e.CreatedAt)`). |
| `Tracking` | `QueryTrackingMode` | `Tracking` (default) to track entities, `NoTracking` for read-only. |

**Example:**

```csharp
var options = new QueryOption<Product>(
    Predicate: p => p.IsActive && p.Price < 100,
    OrderBy: q => q.OrderBy(p => p.Name).ThenBy(p => p.Id),
    Tracking: QueryTrackingMode.NoTracking
);
var results = await productRepo.GetAllAsync(options);
```

### PageableQueryOption<TEntity>

Adds pagination.

```csharp
public record PageableQueryOption<TEntity> : QueryOption<TEntity>, IPageableQuery
{
    public Paging Page { get; init; } = new(0, 10);  // Default: page 0, 10 items/page
}
```

**Paging defaults:** page index `0` (first page), page size `10`.

**Example:**

```csharp
var pageOptions = new PageableQueryOption<Order>(
    Predicate: o => o.Status == OrderStatus.Completed,
    OrderBy: q => q.OrderByDescending(o => o.CreatedAt),
    Page: new Paging(pageIndex: 2, pageSize: 50)  // Page 3 (0-indexed), 50 per page
);
PaginatedList<Order> page = await orderRepo.GetListAsync(pageOptions);
Console.WriteLine($"Total: {page.Meta.TotalCount}, Page: {page.Meta.PageIndex + 1}/{page.Meta.TotalPages}");
```

### Soft-Delete Query Options

Two parallel hierarchies exist for soft-delete control:

#### IQueryOptionWithSoftDelete

Marker interface with `IncludeDeleted` flag:

```csharp
public interface IQueryOptionWithSoftDelete
{
    bool IncludeDeleted { get; }
}
```

Implementations:
- `QueryOptionWithSoftDelete<TEntity>` — base query + `IncludeDeleted`
- `PageableQueryOptionWithSoftDelete<TEntity>` — paginated + `IncludeDeleted`

#### Using IncludeDeleted

```csharp
// Typed query variant
var adminOptions = new QueryOptionWithSoftDelete<Product>(IncludeDeleted: true);
var allProducts = await productRepo.GetAllAsync(adminOptions);

// Paginated variant
var pagedAdmin = new PageableQueryOptionWithSoftDelete<Product>(
    IncludeDeleted: true,
    Page: new Paging(0, 100)
);
var page = await productRepo.GetListAsync(pagedAdmin);
```

When `IncludeDeleted` is `true`, the global soft-delete query filter (`WHERE IsDeleted = 0`) is **ignored** for that query. Use sparingly (admin screens, audits, undelete workflows).

## Pagination Types

### Paging

```csharp
public readonly record struct Paging(int PageIndex, int PageSize)
```

Immutable value object describing a page request.

**Static property:**

- `Paging.Default` → `{ PageIndex = 0, PageSize = 10 }`

**Computed property:**

- `Offset` → `PageIndex * PageSize`

**Example:**

```csharp
var paging = new Paging(pageIndex: 0, pageSize: 25);
Console.WriteLine(paging.Offset);  // 0

var nextPage = new Paging(1, 25);
Console.WriteLine(nextPage.Offset);  // 25
```

### PagingMeta

Metadata returned alongside a paginated result set.

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
var page = await repo.GetListAsync(options);
var meta = page.Meta;

Console.WriteLine($"Total items: {meta.TotalCount}");
Console.WriteLine($"Page {meta.PageIndex + 1} of {meta.TotalPages}");
if (meta.HasPreviousPage)
    Console.WriteLine("Prev page exists");
if (meta.HasNextPage)
    Console.WriteLine("Next page exists");
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

**Validation:** Constructor throws `ArgumentException` if `items.Count > meta.TotalCount`. This catches mismatched data between the items query and the count query.

**Returned by:**

- `IReadRepository.GetListAsync(PageableQueryOption<TEntity>?)`
- `IDynamicReadRepository.GetListByDynamicAsync(PageableDynamicQueryOption)`

**Example:**

```csharp
var page = await repo.GetListAsync(new PageableQueryOption<Product>());
foreach (var product in page.Items)
    Console.WriteLine(product.Name);
Console.WriteLine($"Showing {page.Items.Count} of {page.Meta.TotalCount} total");
```

## Dynamic Query Types

System.Linq.Dynamic.Core requires string-based field names. NFramework's dynamic query types wrap these strings in strongly-typed descriptor objects.

### FilterOperator

Comparison operators for WHERE clauses.

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

**Type constraints per operator:**

| Operator | Expected `Value` type |
|----------|---------------------|
| `Equals`, `NotEquals` | Same as field type or `null` |
| `Contains`, `StartsWith`, `EndsWith` | `string` |
| `GreaterThan`, `GreaterThanOrEqual`, `LessThan`, `LessThanOrEqual` | `IComparable` (numeric, DateTime, etc.) |
| `In` | `IEnumerable` (collection to check membership) |
| `IsNull`, `IsNotNull` | _None — `Value` should be `null` or omitted_ |

### FilterLogic

Logical combination for grouped filters:

```csharp
public enum FilterLogic
{
    And,
    Or
}
```

### Filter

Represents a single WHERE clause or a grouped combination.

```csharp
public class Filter
{
    // Simple filter properties
    public string Field { get; set; }                    // e.g., "Category", "Price"
    public FilterOperator Operator { get; set; }         // e.g., Equals, GreaterThan
    public object? Value { get; set; }                   // Comparison value
    public bool IsNot { get; set; }                      // Negates the condition
    public bool CaseSensitive { get; set; }              // String comparisons only

    // Group filter properties
    public FilterLogic? Logic { get; set; }              // And / Or for combining nested Filters
    public ICollection<Filter>? Filters { get; init; }  // Nested filter group
}
```

#### Simple Filter

```csharp
var filter = new Filter("Price", FilterOperator.GreaterThan, 100);
```

Generates SQL: `WHERE [Price] > @p0`

#### Negated Filter

```csharp
var filter = new Filter("Status", FilterOperator.Equals, "Active")
{
    IsNot = true
};
```

Generates: `WHERE [Status] != @p0`

#### Case-Sensitive String Filter

```csharp
var filter = new Filter("Name", FilterOperator.Contains, "test")
{
    CaseSensitive = true
};
```

Generates: `WHERE [Name] LIKE '%test%' COLLATE NOCASE` (collation depends on provider).

#### Grouped Filters

Combine multiple filters with `AND` or `OR`:

```csharp
var group = new Filter(FilterLogic.And, new Filter[]
{
    new Filter("Category", FilterOperator.Equals, "Electronics"),
    new Filter("Price", FilterOperator.GreaterThan, 100),
    new Filter("Price", FilterOperator.LessThan, 1000)
});
```

Generates: `WHERE ([Category] = @p0) AND ([Price] > @p1) AND ([Price] < @p2)`

Complex nested example:

```csharp
var complex = new Filter(FilterLogic.Or, new Filter[]
{
    new Filter(FilterLogic.And, new Filter[]
    {
        new Filter("Category", FilterOperator.Equals, "Books"),
        new Filter("Price", FilterOperator.LessThan, 20)
    }),
    new Filter(FilterLogic.And, new Filter[]
    {
        new Filter("Category", FilterOperator.Equals, "Electronics"),
        new Filter("Price", FilterOperator.GreaterThan, 500)
    })
});
```

Generates:
```sql
WHERE ([Category] = 'Books' AND [Price] < 20)
   OR ([Category] = 'Electronics' AND [Price] > 500)
```

**Validation:** Call `filter.Validate()` to check required fields. Framework validates before executing.

### OrderDirection

```csharp
public enum OrderDirection
{
    Asc,
    Desc
}
```

### Order

Represents an `ORDER BY` clause.

```csharp
public class Order
{
    public string Field { get; set; }              // Column/property name
    public OrderDirection Direction { get; set; } = OrderDirection.Asc;
}
```

**Constructor:**

```csharp
public Order(string field, OrderDirection direction = OrderDirection.Asc);
```

**Single ordering:**

```csharp
var order = new Order("CreatedAt", OrderDirection.Desc);
```

**Multiple ordering:**

```csharp
var options = new DynamicQueryOption
{
    Orders =
    [
        new Order("Category", OrderDirection.Asc),
        new Order("Price", OrderDirection.Desc),
        new Order("Name", OrderDirection.Asc)
    ]
};
```

Generates: `ORDER BY Category ASC, Price DESC, Name ASC`

## QueryTrackingMode

Controls whether EF Core tracks the returned entities.

```csharp
public enum QueryTrackingMode
{
    Default,    // EF Core default (usually tracking)
    Tracking,   // Explicit tracking
    NoTracking  // Untracked — better for read-only, less memory
}
```

**Why use `NoTracking`?**

- Reduced memory footprint — tracked entities are stored in the `DbContext.ChangeTracker`
- Faster queries — EF Core skips building change-tracking metadata
- Read-only intent signals to EF Core it can skip certain operations

**Usage with typed queries:**

```csharp
var options = new QueryOption<Product>(Tracking: QueryTrackingMode.NoTracking);
var products = await repo.GetAllAsync(options);
```

**Usage with `Query()`:**

```csharp
var products = await repo.Query()
    .AsNoTracking()  // Explicit
    .Where(p => p.IsActive)
    .ToListAsync(ct);
```

## Extension Methods for Query Composition

NFramework provides extension methods to apply dynamic filters and orders to `IQueryable<T>`.

### ApplyTracking

```csharp
public static IQueryable<T> ApplyTracking<T>(
    this IQueryable<T> query,
    QueryTrackingMode? mode
)
```

- `Tracking` → no change
- `NoTracking` → `query = query.AsNoTracking()`
- `null` → no change

### ApplyFilters

```csharp
public static IQueryable<T> ApplyFilters<T>(
    this IQueryable<T> source,
    IReadOnlyCollection<Filter>? filters
)
```

Translates `Filter` collection to Dynamic LINQ expression:

```csharp
var query = repo.Query()
    .ApplyFilters(new[]
    {
        new Filter("Category", FilterOperator.Equals, "Books"),
        new Filter("Price", FilterOperator.GreaterThan, 10)
    });
```

**Generated expression tree:**

```csharp
query.Where("Category == @0 AND Price > @1", "Books", 10)
```

The method chains filters with `AND`. To use `OR`, group filters with `FilterLogic.Or`.

### ApplyOrders

```csharp
public static IOrderedQueryable<T> ApplyOrders<T>(
    this IQueryable<T> source,
    IReadOnlyCollection<Order>? orders
)
```

Applies ordering for each `Order` object:

```csharp
var query = repo.Query()
    .ApplyOrders(new[]
    {
        new Order("Category", OrderDirection.Asc),
        new Order("Price", OrderDirection.Desc)
    });
```

Equivalent to:

```csharp
query.OrderBy("Category ASC, Price DESC")
```

### ToPaginatedListAsync

```csharp
public static async Task<PaginatedList<T>> ToPaginatedListAsync<T>(
    this IQueryable<T> source,
    Paging paging,
    CancellationToken cancellationToken = default
)
```

Executes two queries in sequence:

1. `total = await source.CountAsync(ct)`
2. `items = await source.Skip(paging.Offset).Take(paging.PageSize).ToListAsync(ct)`

Returns `new PaginatedList<T>(items, new PagingMeta(total, paging.PageIndex, paging.PageSize, totalPages))`.

**Do not call `CountAsync()` or `LongCountAsync()` yourself before `ToPaginatedListAsync()`** — the method handles it. Pre-computing counts separately can lead to double work.

## Building Queries

### Typed Query (Recommended for AOT)

```csharp
public async Task<IReadOnlyList<Product>> GetActiveProductsAsync(CancellationToken ct)
{
    var options = new QueryOption<Product>(
        Predicate: p => p.IsActive && !p.IsDeleted && p.Price > 0,
        OrderBy: q => q.OrderBy(p => p.Name),
        Tracking: QueryTrackingMode.NoTracking
    );
    return await _repository.GetAllAsync(options, ct);
}
```

**Behind the scenes:**

```csharp
IQueryable<Product> query = DbSet;
if (options.Predicate is not null)
    query = query.Where(options.Predicate);
if (options.OrderBy is not null)
    query = options.OrderBy(query);
if (options.Tracking == QueryTrackingMode.NoTracking)
    query = query.AsNoTracking();
return await ExecuteWithLimitAsync(query, ct);
```

### Dynamic Query (NOT AOT-compatible)

```csharp
public async Task<IReadOnlyList<Product>> FilterProductsAsync(
    string? category,
    decimal? minPrice,
    decimal? maxPrice,
    CancellationToken ct
)
{
    var filters = new List<Filter>();

    if (!string.IsNullOrEmpty(category))
        filters.Add(new Filter("Category", FilterOperator.Equals, category));

    if (minPrice.HasValue)
        filters.Add(new Filter("Price", FilterOperator.GreaterThanOrEqual, minPrice.Value));

    if (maxPrice.HasValue)
        filters.Add(new Filter("Price", FilterOperator.LessThanOrEqual, maxPrice.Value));

    var options = new DynamicQueryOption
    {
        Filters = filters,
        Orders = [new Order("CreatedAt", OrderDirection.Desc)],
        Tracking = QueryTrackingMode.NoTracking
    };

    return await _dynamicRepo.GetAllByDynamicAsync(options, ct);
}
```

**Security note:** Field names (`Filter.Field`) are **not parameterized**. Do not accept raw field names from untrusted sources (e.g., query string `?sort=__proto__`). Validate fields against an allow-list:

```csharp
static readonly HashSet<string> AllowedSortFields = new(StringComparer.OrdinalIgnoreCase)
{
    "Name", "Price", "CreatedAt"
};

if (!AllowedSortFields.Contains(order.Field))
    throw new ArgumentException($"Invalid sort field: {order.Field}");
```

### Raw Queryable (Maximum Flexibility)

When you need anything not expressible via option objects (joins across aggregates, raw SQL, projections), use `Query()`:

```csharp
public async Task<IReadOnlyList<ProductDto>> GetProductSummariesAsync(CancellationToken ct)
{
    return await _repository.Query()
        .Where(p => p.IsActive)
        .Select(p => new ProductDto
        {
            Id = p.Id,
            Name = p.Name,
            Category = p.Category.Name,  // Navigation property
            Price = p.Price
        })
        .OrderBy(dto => dto.Name)
        .ToListAsync(ct);
}
```

**When `Query()` returns tracked entities:**

`Query()` returns `AsNoTracking()` by default. If you need tracking for a scenario like "read-modify-write in the same scope", bypass `Query()` and use repository methods with `QueryTrackingMode.Tracking`:

```csharp
var options = new QueryOption<Product>(Tracking: QueryTrackingMode.Tracking);
var trackedProducts = await repo.GetAllAsync(options);
// Now entities are tracked; changes will be detected on SaveChanges
trackedProducts[0].Price = 999;
await repo.SaveChangesAsync(ct);  // UPDATE issued
```

## Soft-Delete Filtering

All query methods automatically exclude soft-deleted entities globally. The filter is applied via EF Core's `HasQueryFilter` mechanism, configured in `BaseDbContext.OnModelCreating`:

```csharp
modelBuilder.ConfigureSoftDeleteFilter<BaseDbContext>();
```

This adds `WHERE IsDeleted = 0` to every query for `ISoftDeletableEntity` types.

**Override:**

```csharp
var includeDeleted = new QueryOptionWithSoftDelete<Product>(IncludeDeleted: true);
var all = await repo.GetAllAsync(includeDeleted);
```

Under the hood, the repository checks:

```csharp
if (options is IQueryOptionWithSoftDelete { IncludeDeleted: true })
    query = query.IgnoreQueryFilters(QueryFilters.SoftDeletionArray);
```

`QueryFilters.SoftDeletionArray` is a compiler-generated constant array `[false]` used to avoid closure allocation in the global filter expression.

## Default Limits and Guards

### MaxResultSetSize

Non-paginated queries (`GetAllAsync`) are capped at 10,000 entities by default. This guard prevents catastrophic OOM from accidental full-table scans.

```csharp
public virtual async Task<IReadOnlyList<TEntity>> GetAllAsync(
    QueryOption<TEntity>? options = null,
    CancellationToken cancellationToken = default
)
{
    IQueryable<TEntity> query = buildQuery(options);
    return await ExecuteWithLimitAsync(query, cancellationToken);
}
```

If the query returns more than `MaxResultSetSize + 1` rows, `ExecuteWithLimitAsync` throws:

```csharp
throw new InvalidOperationException(
    $"The result set size exceeded the configured limit of {limit} records. " +
    "Please use pagination or more restrictive filters."
);
```

**Override per repository:**

```csharp
public partial class ProductRepository : EFCoreRepository<Product, Guid, MyDbContext>
{
    protected override int? MaxResultSetSize => 50_000; // Higher limit for this entity
}
```

Set to `0` or `null` to disable the guard (not recommended).

### MaxBatchSize

Bulk operations split into chunks of `MaxBatchSize` (default 1,000). Override for large ETL workloads:

```csharp
protected override int MaxBatchSize => 5_000; // Larger batches — use with caution
```

## Performance Tips

1. **Always paginate** — `GetListAsync` for endpoints; never use `GetAllAsync` for unbounded tables.
2. **Use `NoTracking`** — read-only queries should set `Tracking: QueryTrackingMode.NoTracking`.
3. **Project to DTOs** — avoid materializing full entities for list views:

   ```csharp
   var dtos = await _repository.Query()
       .Where(p => p.IsActive)
       .Select(p => new ProductListItemDto(p.Id, p.Name, p.Price))
       .ToListAsync(ct);
   ```

4. **Index your filter/sort columns** — dynamic queries reference property names directly; the underlying SQL uses those columns in `WHERE`/`ORDER BY`. Database indexes are critical.
5. **Compiled queries** — for hot paths, use `EF.CompileAsyncQuery` to skip LINQ expression compilation overhead:

   ```csharp
   private static readonly Func<MyDbContext, Guid, Task<Product?>> _getByIdCompiled =
       EF.CompileAsyncQuery((MyDbContext ctx, Guid id) =>
           ctx.Products.FirstOrDefault(p => p.Id == id));

   public Task<Product?> GetByIdCompiledAsync(Guid id, CancellationToken ct)
       => Task.FromResult(_getByIdCompiled(Context, id));
   ```

   NFramework does not provide compiled query wrappers — you can add them in your repository partial class if needed.

6. **Avoid cascade soft-delete on deep graphs** — keep relationship depth reasonable to avoid loading thousands of related rows automatically.

## Summary

| Feature | Typed Approach | Dynamic Approach |
|---------|----------------|------------------|
| API | `GetAllAsync(QueryOption<T>)` | `GetAllByDynamicAsync(DynamicQueryOption)` |
| Type safety | ✅ Compile-time checked expressions | ❌ Runtime string field names |
| AOT compatibility | ✅ Yes | ❌ No (reflection-based) |
| Flexibility | ✋ Limited to expression trees | ✅ Arbitrary field+operator combinations |
| Use case | Known filters at compile time (most app queries) | Generic API endpoints accepting arbitrary filter arrays from UI |

**Recommendation:** Use typed queries (`IReadRepository`) for 95% of use cases. Reserve dynamic queries for admin search screens where users pick arbitrary field/operator combinations and AOT is not a concern.
