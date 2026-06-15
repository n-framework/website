---
title: Entities
description: Entity base classes providing identity, optimistic concurrency, audit tracking, and soft-delete capabilities for all persistent aggregates in NFramework Persistence.
---

## Introduction

All persistent domain entities inherit from framework-provided base classes located in `NFramework.Persistence.Abstractions.Entities`. These bases supply:

- **Immutable identity** (`Id`) with validation
- **Optimistic concurrency token** (`RowVersion`) for conflict detection
- **Audit timestamps** (`CreatedAt`, `UpdatedAt`) via interceptor
- **Soft-delete state** (`IsDeleted`, `DeletedAt`) with cascade support

The base classes are part of the **Abstractions** package — zero external dependencies. They're infrastructure-agnostic and can be used without EF Core if needed.

## Entity Hierarchy

```
Entity<TId> (abstract)
  └── AuditableEntity<TId> (abstract)
        └── SoftDeletableEntity<TId> (abstract)
```

Each level adds capabilities:

| Base Class | Adds | Interface |
|------------|------|-----------|
| `Entity<TId>` | `Id`, `RowVersion` | *(none)* |
| `AuditableEntity<TId>` | `CreatedAt`, `UpdatedAt` | `IAuditableEntity` |
| `SoftDeletableEntity<TId>` | `IsDeleted`, `DeletedAt` | `ISoftDeletableEntity` |

Choose the appropriate base based on your aggregate's needs:

- **Simple entities** (lookup tables, value lists) → inherit from `Entity<TId>` only
- **Auditable entities** (most business aggregates) → inherit from `AuditableEntity<TId>`
- **Soft-deletable entities** (customers, orders, posts) → inherit from `SoftDeletableEntity<TId>`

## Entity<TId>

Foundation base class for all aggregates.

```csharp
public abstract class Entity<TId> where TId : IEquatable<TId>
```

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `Id` | `TId` | Immutable primary key. Set via constructor; read-only (`init`) thereafter. |
| `RowVersion` | `byte[]` | Optimistic concurrency token. Auto-managed by database as a `rowversion`/`timestamp` column. |

### Constructors

```csharp
// Application code — use this
protected Entity(TId id);

// ORM-only — DO NOT USE in business logic
[Obsolete("Use constructor with ID instead. This is only for ORM use.")]
protected Entity();
```

**Why two constructors?**

EF Core requires a parameterless constructor to materialize entities during queries. Marking it `[Obsolete]` prevents accidental use in domain code while satisfying EF Core's requirement. The actual application-use constructor enforces that every entity has a valid identity at creation time.

### Identity Validation

The constructor validates that `id` is not the default value for the type:

```csharp
protected Entity(TId id)
{
    if (EqualityComparer<TId>.Default.Equals(id, default))
        throw new ArgumentException("Entity ID cannot be the default value.", nameof(id));
    Id = id;
}
```

This prevents creating entities with `Guid.Empty`, `0`, `null` (for nullable IDs), or other sentinel default values.

### Equality

`Entity<TId>` implements `IEquatable<Entity<TId>>`. Equality is based on `Id` value identity:

```csharp
public override bool Equals(object? obj) =>
    obj is Entity<TId> other && EqualityComparer<TId>.Default.Equals(Id, other.Id);

public override int GetHashCode() => Id.GetHashCode();
```

Two entity instances with the same `Id` are considered equal even if they're different object references. This is crucial for collection operations and change tracking.

### RowVersion Concurrency Token

`RowVersion` is a `byte[]` that EF Core maps to a database `rowversion` (SQL Server) or `BLOB` (SQLite) column. On every INSERT/UPDATE, the database generates a new binary value. EF Core includes `WHERE RowVersion = @original` in UPDATE/DELETE statements; if zero rows match, a `DbUpdateConcurrencyException` is thrown.

**Configuration in EF Core:**

```csharp
builder.Property(e => e.RowVersion)
    .IsRowVersion()
    .IsConcurrencyToken();
```

Do not set `RowVersion` manually — it's managed by the database.

## AuditableEntity<TId>

Adds automatic timestamp tracking for creation and modification.

```csharp
public abstract class AuditableEntity<TId> : Entity<TId>, IAuditableEntity
    where TId : IEquatable<TId>
```

### Additional Properties

| Property | Type | Description |
|----------|------|-------------|
| `CreatedAt` | `DateTime` | UTC timestamp when the entity was first inserted. Set automatically by `AuditableInterceptor`. |
| `UpdatedAt` | `DateTime?` | UTC timestamp of the most recent modification. Set automatically by `AuditableInterceptor`. |

### Interface

```csharp
public interface IAuditableEntity
{
    DateTime CreatedAt { get; set; }
    DateTime? UpdatedAt { get; set; }
}
```

### Validation

`AuditableEntity` overrides `Validate()`:

```csharp
public virtual IEnumerable<string> Validate()
{
    if (CreatedAt == default)
        yield return "CreatedAt must be a valid timestamp.";

    if (UpdatedAt.HasValue && UpdatedAt.Value < CreatedAt)
        yield return "UpdatedAt cannot be earlier than CreatedAt.";
}
```

This is a basic sanity check — most applications won't call it directly since timestamps are managed by the interceptor.

### AuditableInterceptor Behavior

The `AuditableInterceptor` (in `NFramework.Persistence.EFCore`) hooks into EF Core's `SavingChanges` event:

| Entity State | Action |
|--------------|--------|
| `Added` | Set `CreatedAt = DateTime.UtcNow` (only if current value is `default`) |
| `Modified` | Set `UpdatedAt = DateTime.UtcNow` |

The interceptor runs **after** your handler calls `SaveChangesAsync()` but **before** EF Core sends the SQL to the database. This ensures timestamps reflect the exact moment of persistence.

## SoftDeletableEntity<TId>

Adds soft-delete (logical delete) capabilities with automatic cascade behavior.

```csharp
public abstract class SoftDeletableEntity<TId> : AuditableEntity<TId>, ISoftDeletableEntity
    where TId : IEquatable<TId>
```

### Additional Properties

| Property | Type | Description |
|----------|------|-------------|
| `IsDeleted` | `bool` | Boolean deletion flag. Setting to `true` auto-sets `DeletedAt = DateTime.UtcNow`. |
| `DeletedAt` | `DateTime?` | Deletion timestamp. Setting to non-null auto-sets `IsDeleted = true`. |

Both properties are synchronized — setting one updates the other.

### Interface

```csharp
public interface ISoftDeletableEntity
{
    bool IsDeleted { get; set; }
    DateTime? DeletedAt { get; set; }
}
```

### Thread-Safe Setters

The property setters use `Interlocked.CompareExchange` to prevent infinite recursion when one property setter triggers the other:

```csharp
public bool IsDeleted
{
    get => field;
    set
    {
        if (Interlocked.CompareExchange(ref _isSyncing, 1, 0) == 1)
        {
            field = value;
            return;
        }

        try
        {
            field = value;
            if (field && DeletedAt == null)
                DeletedAt = DateTime.UtcNow;
            else if (!field)
                DeletedAt = null;
        }
        finally
        {
            Volatile.Write(ref _isSyncing, 0);
        }
    }
}
```

This ensures that setting `IsDeleted = true` updates `DeletedAt` without causing a stack overflow due to `DeletedAt`'s setter also setting `IsDeleted`.

### Soft-Delete Behavior

When you call `repository.DeleteAsync(entity)`:

1. EF Core marks the entity as `EntityState.Deleted`
2. `SoftDeletionInterceptor` intercepts `SavingChanges`
3. Converts `Deleted` → `Modified`
4. Sets `IsDeleted = true` and `DeletedAt = DateTime.UtcNow`
5. Database UPDATE writes the soft-delete flags

The entity **remains in the database** but is excluded from all queries by default via a global query filter.

### Cascade Soft-Delete

If the deleted entity has navigations to other soft-deletable children, the interceptor automatically marks them as deleted too, respecting `DeleteBehavior.Cascade` relationships.

Example: Deleting an `Order` soft-deletes all `OrderItems` (if they implement `ISoftDeletableEntity` and the FK is configured with `OnDelete(DeleteBehavior.Cascade)`).

The cascade depth is limited to 50 levels by default (configurable via `SoftDeletionInterceptor.MaxCascadeDepth`). Exceeding the limit throws `InvalidOperationException` — typically indicates a circular reference or excessively deep graph.

### Global Query Filter

All queries automatically exclude soft-deleted entities:

```sql
SELECT * FROM Products WHERE IsDeleted = 0
```

To include deleted records (admin/recovery scenarios), pass `IncludeDeleted: true` in query options:

```csharp
var options = new QueryOptionWithSoftDelete<Product>(IncludeDeleted: true);
var allProducts = await repo.GetAllAsync(options);
```

## Entity Example

Complete entity with all capabilities:

```csharp
using NFramework.Persistence.Abstractions.Entities;

namespace MyService.Domain.Features.Products;

public sealed class Product : SoftDeletableEntity<ProductId>
{
    // ORM-only constructor — never used in domain code
    [Obsolete("Only for ORM use", true)]
#pragma warning disable CS0618
    private Product() { }
#pragma warning restore CS0618

    // Primary constructor — application code uses this
    public Product(ProductId id, string name, decimal price) : base(id)
    {
        Name = name;
        Price = price;
    }

    // Properties
    public string Name { get; private set; }
    public decimal Price { get; private set; }
    public string? Description { get; private set; }
    public bool IsActive { get; set; }

    // Domain behavior
    public void Rename(string newName) => Name = newName;
    public void UpdatePrice(decimal newPrice) => Price = newPrice;
    public void Deactivate() => IsActive = false;
}
```

**Notes:**

- The obsolete parameterless constructor is required for EF Core. Suppress the compiler warning locally with `#pragma`.
- Keep the primary `Id` constructor `public` or `internal` depending on whether aggregates are created only by handlers or also by other aggregates.
- Properties can have `private set` if only domain methods modify them (encapsulation). EF Core can still set them via the parameterless constructor or property injection if configured with `UsePropertyAccessMode(PropertyAccessMode.Field)`.

## Strongly-Typed IDs

While not part of the entity base class, strongly-typed IDs are recommended:

```csharp
public readonly record struct ProductId(Guid Value)
{
    public static ProductId New() => new(Guid.NewGuid());
    public static explicit operator Guid(ProductId id) => id.Value;
    public static explicit operator ProductId(Guid id) => new(id);
}
```

**Benefits:**

- Type safety: `ProductId` vs `OrderId` cannot be mixed
- Clear intent: method parameters express domain meaning
- Validation centralization: conversions can throw if invalid

**EF Core configuration:**

```csharp
builder.Property(p => p.Id)
    .HasConversion(
        v => (Guid)v.Value,
        v => new ProductId(v))
    .ValueGeneratedNever(); // Application-generated IDs
```

## Entity Validation

Base classes provide a `Validate()` method that returns an `IEnumerable<string>` of errors. Override to add domain invariants:

```csharp
public sealed class Product : Entity<ProductId>
{
    public decimal Price { get; set; }

    public override IEnumerable<string> Validate()
    {
        foreach (var error in base.Validate())
            yield return error;

        if (Price <= 0)
            yield return "Price must be greater than zero.";
    }
}
```

However, most applications use **FluentValidation** in the Application layer instead of entity-level validation. Keep entities as pure data + domain behavior; put cross-cutting validation in command validators.

## Interceptor-Defined Interfaces

Three interfaces indicate which interceptors apply to an entity:

### IAuditableEntity

```csharp
public interface IAuditableEntity
{
    DateTime CreatedAt { get; set; }
    DateTime? UpdatedAt { get; set; }
}
```

Implemented by `AuditableEntity<TId>`. Presence indicates `AuditableInterceptor` will manage timestamps.

### ISoftDeletableEntity

```csharp
public interface ISoftDeletableEntity
{
    bool IsDeleted { get; set; }
    DateTime? DeletedAt { get; set; }
}
```

Implemented by `SoftDeletableEntity<TId>`. Presence indicates:

- Global query filter applies (`IsDeleted = false`)
- `SoftDeletionInterceptor` converts `DeleteAsync()` into an update

### No Interface for Entity<TId>

`Entity<TId>` does not implement a marker interface. It's a standalone base class. Check for `Entity<TId>` inheritance via `is Entity` pattern if needed in extension methods.

## AOT Considerations

When publishing with Native AOT (`PublishAot=true`), ensure your entity constructors follow the pattern shown above. EF Core uses reflection to construct entities at runtime. The `[DynamicallyAccessedMembers]` attributes on `EFCoreRepository` generic parameters instruct the trimmer to preserve the necessary constructors.

**Do NOT** use `new()` constraints on `TEntity` — they're incompatible with AOT trimming. The framework uses `DynamicallyAccessedMembers` instead.

## Summary

| Base Class | Use When | Provides |
|------------|----------|----------|
| `Entity<TId>` | Simple entities without audit or soft-delete needs | Identity + concurrency |
| `AuditableEntity<TId>` | Most business aggregates (common case) | Identity + concurrency + timestamps |
| `SoftDeletableEntity<TId>` | Entities that need logical delete (customers, orders, posts) | Identity + concurrency + timestamps + soft-delete |

All bases are async-safe. Timestamps and soft-delete flags are managed automatically by interceptors — you only set these if implementing custom persistence without interceptors.
