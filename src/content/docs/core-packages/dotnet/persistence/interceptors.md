---
title: Interceptors
description: EF Core interceptors that automatically manage audit timestamps, soft-delete state with cascading, and audit logging. Configured via DbContextOptionsBuilder.
---

## Introduction

EF Core **interceptors** are hooks into the database command pipeline. They execute before/after specific events (e.g., `SaveChanges`, command execution, connection opening). NFramework uses interceptors to implement cross-cutting persistence concerns without requiring developers to write boilerplate in every handler.

Three interceptors are provided:

| Interceptor | Purpose | Interface |
|-------------|---------|-----------|
| `AuditableInterceptor` | Auto-sets `CreatedAt` / `UpdatedAt` on `IAuditableEntity` | `SaveChangesInterceptor` |
| `SoftDeletionInterceptor` | Converts `Delete` → soft-delete update, cascades to children | `SaveChangesInterceptor` |
| `AuditLoggerInterceptor` | Logs entity changes to `ILogger<TContext>` | `SaveChangesInterceptor` |

All three inherit from `SaveChangesInterceptor`, meaning they hook into `SavingChanges` / `SavingChangesAsync` — just before EF Core's `DbContext.SaveChangesAsync()` sends the SQL to the database.

## Interceptor Registration

Register interceptors on the `DbContext` options during service configuration:

```csharp
services.AddDbContext<MyDbContext>(options =>
{
    options.UseSqlite(connectionString);
    options.AddAuditableInterceptor();     // 1. Set timestamps first
    options.AddSoftDeleteInterceptor();   // 2. Then soft-delete conversion
    // options.AddAuditLoggerInterceptor(); // 3. Finally audit logging (optional)
});
```

**Order matters.** Recommended: `Auditable` → `SoftDelete` → `AuditLogger`. The order determines the sequence in which they run during `SavingChanges`.

## AuditableInterceptor

### Purpose

Automatically populates `CreatedAt` and `UpdatedAt` for entities implementing `IAuditableEntity` (i.e., inheriting from `AuditableEntity<TId>`).

- **On INSERT** (`EntityState.Added`) → sets `CreatedAt = DateTime.UtcNow` if it's still `default`
- **On UPDATE** (`EntityState.Modified`) → sets `UpdatedAt = DateTime.UtcNow`

No developer intervention required — just implement `IAuditableEntity` and the interceptor handles timestamps.

### Implementation

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

    private static void UpdateTimestamps(DbContext? context)
    {
        if (context == null || !context.ChangeTracker.HasChanges())
            return;

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
}
```

**Key details:**

- Interceptor runs on both sync and async `SaveChanges`.
- Only sets `CreatedAt` if it's still `default` (allows manual override if needed before save).
- `UpdatedAt` is set on every `Modified` state, regardless of whether properties changed.
- `DateTime.UtcNow` is used — all timestamps are UTC. Convert to local in presentation layer.

### Thread Safety

The interceptor is registered as a singleton instance (via `AddAuditableInterceptor()`), but the `UpdateTimestamps` method operates only on the passed `DbContext`'s change tracker. Each `DbContext` instance is scoped to a single request/operation, so there's no shared mutable state across threads.

### Error Handling

If an exception occurs during timestamp updates (unlikely), it propagates as `InvalidOperationException`. This will abort `SaveChangesAsync`, rolling back the transaction.

## SoftDeletionInterceptor

### Purpose

Converts hard deletes into soft deletes for entities implementing `ISoftDeletableEntity` (i.e., inheriting from `SoftDeletableEntity<TId>`). Additionally, it performs **cascade soft-delete** through navigations to ensure child entities are also soft-deleted.

Behavior:

1. EF Core marks entity as `EntityState.Deleted` (via `DeleteAsync(entity)`)
2. Interceptor detects the `Deleted` state for `ISoftDeletableEntity` entries
3. Changes state to `Modified`
4. Sets `IsDeleted = true` and `DeletedAt = DateTime.UtcNow`
5. Traverses navigations with `DeleteBehavior.Cascade` / `ClientCascade`
6. Recursively soft-deletes eligible children (also `ISoftDeletableEntity`)
7. Prevents cycles via visited set and respects `MaxCascadeDepth`

### Configuration

```csharp
services.AddDbContext<MyDbContext>(options =>
    options.AddSoftDeleteInterceptor(maxCascadeDepth: 50)  // defaults to 50
);
```

Pass `maxCascadeDepth` to tighten or loosen the cascade limit.

### Implementation Highlights

```csharp
public sealed class SoftDeletionInterceptor : SaveChangesInterceptor
{
    public int? MaxCascadeDepth { get; init; } = 50;

    public override InterceptionResult<int> SavingChanges(
        DbContextEventData eventData,
        InterceptionResult<int> result
    )
    {
        var entries = GetEntriesToSoftDelete(eventData.Context);
        foreach (var entry in entries)
            CascadeSoftDelete(eventData.Context!, entry, DateTime.UtcNow, [], 0, MaxCascadeDepth);
        return base.SavingChanges(eventData, result);
    }

    private static List<EntityEntry> GetEntriesToSoftDelete(DbContext? context)
    {
        return context?.ChangeTracker.Entries()
            .Where(e => e.State == EntityState.Deleted && IsSoftDeletableEntry(e))
            .ToList() ?? new();
    }

    private static void MarkAsSoftDeleted(EntityEntry entry, DateTime now)
    {
        if (IsAlreadySoftDeleted(entry))
        {
            entry.State = EntityState.Modified;
            return;
        }

        entry.State = EntityState.Modified;
        if (entry.Entity is ISoftDeletableEntity softDeletable)
        {
            softDeletable.IsDeleted = true;
            softDeletable.DeletedAt = now;
        }
    }

    private static IEnumerable<INavigationBase> GetCascadeNavigations(EntityEntry entry)
    {
        // Select navigations that are:
        // - Not on the dependent side (principal-side owned types handled separately)
        // - Not owned types
        // - With DeleteBehavior.Cascade or DeleteBehavior.ClientCascade
        return entry.Metadata.GetNavigations().Where(n =>
            !n.IsOnDependent &&
            !n.TargetEntityType.IsOwned() &&
            (n.ForeignKey.DeleteBehavior == DeleteBehavior.Cascade ||
             n.ForeignKey.DeleteBehavior == DeleteBehavior.ClientCascade) &&
            n.PropertyInfo != null);  // Must be a CLR navigation property
    }

    private static void CascadeSoftDelete(
        DbContext context,
        EntityEntry entry,
        DateTime now,
        HashSet<object> visited,
        int depth,
        int? maxDepth
    )
    {
        if (maxDepth is { } limit && limit > 0 && depth > limit)
            throw new InvalidOperationException(
                $"Cascade soft-delete exceeded maximum depth of {limit}.");

        if (!visited.Add(entry.Entity))
            return;  // Already visited — prevents infinite loops on cycles

        MarkAsSoftDeleted(entry, now);

        foreach (var navigation in GetCascadeNavigations(entry))
        {
            if (navigation.IsCollection)
            {
                var collectionEntry = entry.Collection(navigation.PropertyInfo!.Name);
                if (!collectionEntry.IsLoaded)
                    collectionEntry.Load();  // Force load for cascade

                foreach (var child in GetValidChildren(context, collectionEntry.CurrentValue))
                    CascadeSoftDelete(context, child, now, visited, depth + 1, maxDepth);
            }
            else
            {
                var referenceEntry = entry.Reference(navigation.PropertyInfo!.Name);
                if (!referenceEntry.IsLoaded)
                    referenceEntry.Load();

                if (GetValidChild(context, referenceEntry.CurrentValue) is { } child)
                    CascadeSoftDelete(context, child, now, visited, depth + 1, maxDepth);
            }
        }
    }

    // Async variants also provided for SavingChangesAsync
}
```

### Soft-Delete Data Flow Example

```csharp
// Given:
// Order (ISoftDeletableEntity) has many OrderItems (ISoftDeletableEntity)
// Order → OrderItems relationship configured with OnDelete(DeleteBehavior.Cascade)

await orderRepository.DeleteAsync(order);
await orderRepository.SaveChangesAsync(ct);
```

**What happens:**

1. `EFCoreRepository.DeleteAsync` calls `DbSet.Remove(order)`
2. EF Core marks `order` as `EntityState.Deleted`
3. `SoftDeletionInterceptor.SavingChanges` fires
4. `GetEntriesToSoftDelete` finds the `Order` entry
5. `CascadeSoftDelete` marks Order as modified, sets `IsDeleted = true`, `DeletedAt = now`
6. Traverses `Order.Items` navigation:
   - Collection loads (if not already loaded)
   - Each `OrderItem` is marked modified, `IsDeleted = true`, `DeletedAt = now`
7. `SaveChangesAsync` persists UPDATE for Order + UPDATE for each OrderItem

**SQL generated:**

```sql
UPDATE [Orders] SET IsDeleted = 1, DeletedAt = '2026-04-29T14:30:00Z' WHERE Id = @id;
UPDATE [OrderItems] SET IsDeleted = 1, DeletedAt = '2026-04-29T14:30:00Z' WHERE Id = @itemId1;
UPDATE [OrderItems] SET IsDeleted = 1, DeletedAt = '2026-04-29T14:30:00Z' WHERE Id = @itemId2;
-- etc.
```

### Cascade Behavior Requirements

For cascade soft-delete to work:

1. **Navigation must be present** on the parent entity
2. **Relationship configured with `OnDelete(DeleteBehavior.Cascade)`** or `ClientCascade`
3. **Child entity implements `ISoftDeletableEntity`**
4. **Navigation property is not null** — collections should be initialized (`new List<T>()`) to avoid null checks in interceptor

**Configuration example:**

```csharp
public class OrderConfiguration : IEntityTypeConfiguration<Order>
{
    public void Configure(EntityTypeBuilder<Order> builder)
    {
        builder.HasMany(o => o.Items)
            .WithOne(i => i.Order)
            .HasForeignKey(i => i.OrderId)
            .OnDelete(DeleteBehavior.Cascade); // Required for cascade soft-delete
    }
}
```

Without `Cascade`, the child navigations are ignored during traversal; you must soft-delete children manually in your domain logic.

### MaxCascadeDepth

Default: `50`. Prevents runaway recursion on circular references or extremely deep graphs.

**Circular reference scenario:**

```csharp
// Entity A → Entity B → Entity C → Entity A (circular)
// Without visited set + depth limit → StackOverflow
```

The interceptor uses a `HashSet<object> visited` passed to recursive calls. Once an entity instance is visited, it's skipped on subsequent encounters, breaking cycles.

**If exceeded:** throws `InvalidOperationException`. This indicates a modeling issue — aggregates shouldn't be 50+ levels deep. Consider flattening or restructuring relationships.

### Global Query Filter

`BaseDbContext.OnModelCreating` calls `modelBuilder.ConfigureSoftDeleteFilter<BaseDbContext>()`. This applies a global filter:

```csharp
builder.HasQueryFilter(e => !((ISoftDeletableEntity)e).IsDeleted);
```

All queries against `ISoftDeletableEntity` types automatically include `WHERE IsDeleted = 0`. You don't need to remember to add `!IsDeleted` to every predicate.

## AuditLoggerInterceptor

### Purpose

Optionally logs all entity changes (added, modified, deleted) to `ILogger<TContext>` at `LogLevel.Information`. Useful for audit trails, debugging, or change-data-capture scenarios.

### Registration

```csharp
services.AddDbContext<MyDbContext>(options =>
    options.AddAuditLoggerInterceptor()  // Optional — enable for audit logging
);
```

### What Gets Logged

The interceptor logs per-entity state changes. See source for exact log format — typically includes:

- Entity type name
- Entity primary key value (from `Id` property)
- `EntityState` (Added, Modified, Deleted)
- Timestamp (logged by `ILogger` automatically)
- Possibly property changes (if the interceptor is configured to dump the entry)

**Example log line:**

```
INFO [AuditLogger] Entity 'Product' (Id: a1b2c3) state changed: Modified
```

Logs are sent to whatever `ILogger<TContext>` sink you've configured (console, file, Seq, Application Insights, etc.).

**Performance note:** Audit logging adds overhead proportional to the number of entities in the change tracker. High-frequency bulk operations may produce many log entries. Consider filtering at the `ILogger` level (e.g., minimum log level `Warning`) if logs become too verbose.

## Interceptor Execution Order

Interceptors execute in **registration order**. `DbContextOptionsBuilder` maintains an internal list — methods are called sequentially.

**Recommended order:**

1. `AddAuditableInterceptor()` — First to set timestamps
2. `AddSoftDeleteInterceptor()` — Second to convert deletes to soft-deletes
3. `AddAuditLoggerInterceptor()` — Last to log the final state after all modifications

**Why order matters:**

If `AuditLoggerInterceptor` runs before `SoftDeletionInterceptor`, it logs an entity as `Deleted` when you meant to soft-delete it — after soft-delete conversion the state is `Modified`. Placing audit logger last captures the final effective state.

## Custom Interceptors

You can write your own interceptor by implementing `SaveChangesInterceptor` or other EF Core interceptor base classes:

- `DbCommandInterceptor` — intercepts SQL commands (for query logging, slow-query detection, multi-tenancy via row-level security predicates)
- `ConnectionInterceptor` — intercepts connection open/close
- `TransactionInterceptor` — intercepts transaction begin/commit/rollback
- `SaveChangesInterceptor` — intercepts change detection and persistence (already used)

### Example: Tenant ID Injection

```csharp
public sealed class TenantIdInterceptor : SaveChangesInterceptor
{
    private readonly ICurrentTenantService _tenantService;

    public TenantIdInterceptor(ICurrentTenantService tenantService)
    {
        _tenantService = tenantService;
    }

    public override InterceptionResult<int> SavingChanges(
        DbContextEventData eventData,
        InterceptionResult<int> result
    )
    {
        var tenantId = _tenantService.TenantId;
        foreach (var entry in eventData.Context!.ChangeTracker.Entries<ITenantEntity>())
        {
            if (entry.State == EntityState.Added)
                entry.Entity.TenantId = tenantId;
        }
        return base.SavingChanges(eventData, result);
    }
}
```

Register with DI:

```csharp
services.AddScoped<TenantIdInterceptor>();
services.AddDbContext<MyDbContext>((sp, options) =>
{
    var interceptor = sp.GetRequiredService<TenantIdInterceptor>();
    options.UseSqlite(...).AddInterceptors(interceptor);
});
```

**Note:** `AddInterceptors()` is the low-level EF Core API. The NFramework extension methods (`AddAuditableInterceptor()`, etc.) are convenience wrappers that instantiate and register singleton interceptor instances. For custom interceptors that need DI, use `AddInterceptors` with service resolution as shown above.

## Multi-Tenancy with Interceptors

A common pattern: inject `TenantIdInterceptor` to automatically stamp tenant ID on insert:

```csharp
public interface ITenantEntity
{
    Guid TenantId { get; set; }
}

// In handler:
var order = new Order(id, customerId); // TenantId not set manually
await _orderRepo.AddAsync(order, ct);  // Interceptor sets TenantId automatically
await _orderRepo.SaveChangesAsync(ct);
```

**Interceptor ensures** that no matter which repository or handler creates the entity, `TenantId` is always populated with the current tenant from the request context.

## AOT Considerations

Interceptors themselves are AOT-compatible. The `[DynamicallyAccessedMembers]` constraints are on repository generics, not on interceptors.

No special action needed — just ensure your custom interceptors don't use reflection or dynamic code if targeting Native AOT.

## Testing Interceptors

**Unit testing interceptor logic:**

```csharp
[Test]
public async Task AuditableInterceptor_SetsTimestamps_OnAddAndUpdate()
{
    // Arrange: build DbContext with interceptor
    var options = new DbContextOptionsBuilder<TestDbContext>()
        .UseInMemoryDatabase("test-db")
        .AddInterceptors(new AuditableInterceptor())
        .Options;

    await using var context = new TestDbContext(options);
    var interceptor = new AuditableInterceptor();

    var product = new Product(ProductId.New(), "Test", 10);
    context.Products.Add(product);

    // Act: trigger SavingChanges via interceptor
    var eventData = new TestDbContextEventData(context);
    var result = interceptor.SavingChanges(eventData, InterceptionResult<int>.Suppress());

    // Assert
    product.CreatedAt.Should().BeCloseTo(DateTime.UtcNow, precision: TimeSpan.FromSeconds(1));
}
```

**Integration test (full pipeline):**

```csharp
[Test]
public async Task SoftDeleteInterceptor_ConvertsDeleteToSoftDelete()
{
    // Arrange
    await using var context = BuildContextWithInterceptors();
    var repo = new ProductRepository(context);
    var product = new Product(ProductId.New(), "Test", 10);
    await repo.AddAsync(product, ct);
    await repo.SaveChangesAsync(ct);

    // Act
    await repo.DeleteAsync(product, ct);
    await repo.SaveChangesAsync(ct);

    // Assert
    var fromDb = await context.Products.FirstAsync(p => p.Id == product.Id, ct);
    fromDb.IsDeleted.Should().BeTrue();
    fromDb.DeletedAt.Should().BeCloseTo(DateTime.UtcNow, precision: TimeSpan.FromSeconds(1));
}
```

## Summary

Interceptors implement cross-cutting concerns declaratively and transparently:

- **Auditable** — "set it and forget it" timestamps
- **SoftDelete** — opaque soft-delete conversion (caller doesn't need to know)
- **AuditLogger** — optional change history

Register them once in `AddInfrastructureServices()` and they apply globally to all repositories using that `DbContext`. No per-repository boilerplate needed.
