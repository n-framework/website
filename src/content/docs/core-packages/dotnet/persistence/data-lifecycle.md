---
title: Data Lifecycle
description: End-to-end trace of data flowing from HTTP request through handler into the database and back. Covers entity states, interceptor pipeline, concurrency conflict resolution, transaction boundaries, and error propagation.
---

## Introduction

Understanding the **data lifecycle** is key to reasoning about persistence behavior, debugging issues, and designing efficient handlers. This document traces a typical request from API endpoint to database and back, showing how NFramework's pieces fit together.

## The Full Request Pipeline

```
HTTP Request
   ↓
Minimal API Endpoint (ProductEndpoints.cs)
   ↓
MediatR.Send(command/query)
   ↓
MediatR Pipeline Behaviors (validation, logging, transaction)
   ↓
Handler (CreateProductCommandHandler)
   ↓
Repository methods (AddAsync → SaveChangesAsync)
   ↓
EF Core Change Tracker (tracks entity states)
   ↓
SavingChanges Interceptors
   ├─ AuditableInterceptor (sets timestamps)
   ├─ SoftDeletionInterceptor (converts delete → soft-delete)
   └─ AuditLoggerInterceptor (optional logging)
   ↓
EF Core Command Recipe Generation (INSERT/UPDATE/DELETE SQL)
   ↓
Database Execute ( Db.SaveChangesAsync() )
   ↓
RowVersion updated (on INSERT/UPDATE)
   ↓
Response propagates back up → JSON
```

## Data Flow: Creating an Entity (INSERT)

### Step 1: API Endpoint Receives Request

**File:** `presentation/Features/Products/ProductEndpoints.cs`

```csharp
[HttpPost("/api/v1/products")]
public static async Task<IResult> Create(
    CreateProductCommand command,
    IMediator mediator,
    CancellationToken ct
)
{
    var result = await mediator.Send(command, ct);
    return result.IsSuccess
        ? Results.CreatedAtRoute("GetProduct", new { id = result.Value.Id }, result.Value)
        : Results.BadRequest(new ValidationProblemDetail(result.Errors.ToDictionary()));
}
```

The endpoint is thin — just unmarshals the request and sends it to MediatR.

### Step 2: MediatR Pipeline (Optional)

If you've registered pipeline behaviors (e.g., validation, logging, transactions), they execute **around** the handler:

```csharp
public class ValidationBehavior<TRequest, TResponse> : IPipelineBehavior<TRequest, TResponse>
    where TRequest : IRequest<TResponse>
{
    public async Task<TResponse> Handle(
        TRequest request,
        RequestHandlerDelegate<TResponse> next,
        CancellationToken cancellationToken
    )
    {
        // Validate before handler
        var validator = _validatorFactory.GetValidator<TRequest>();
        if (validator is not null)
        {
            var validationResult = await validator.ValidateAsync(request, cancellationToken);
            if (!validationResult.IsValid)
                throw new ValidationException(validationResult.Errors);
        }

        var response = await next();  // ← Call handler
        return response;
    }
}
```

Transaction behavior (if used):

```csharp
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
```

Pipeline behaviors run in the order they're registered. A common stack: Validation → Logging → Transaction → Handler.

### Step 3: Handler Executes

**File:** `application/Features/Products/CreateProduct/CreateProductCommandHandler.cs`

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
        // 1. Create domain entity with explicit ID
        var product = new Product(
            id: request.Id,           // Guid from client or server-generated
            name: request.Name,
            price: request.Price
        );

        // 2. Add to repository (tracks as Added)
        await _repository.AddAsync(product, cancellationToken);

        // 3. Persist changes (triggers interceptors → database)
        await _repository.SaveChangesAsync(cancellationToken);

        // 4. Return DTO (RowVersion now populated from DB)
        return Result<ProductDto>.Success(product.ToDto());
    }
}
```

**State transition:**

| Entity | Before `AddAsync` | After `AddAsync` | After `SaveChangesAsync` |
|--------|-------------------|------------------|--------------------------|
| `product` | Transient (not tracked) | `EntityState.Added` | `EntityState.Unchanged` (with DB-generated values) |

At this point, EF Core has not yet sent any SQL. `AddAsync` just marks the entity as `Added` in the change tracker (`DbContext`). The actual `INSERT` occurs on `SaveChangesAsync`.

### Step 4: Repository AddAsync

EFCoreRepository implementation:

```csharp
public virtual async Task<TEntity> AddAsync(TEntity entity, CancellationToken cancellationToken = default)
{
    ArgumentNullException.ThrowIfNull(entity);
    _ = await DbSet.AddAsync(entity, cancellationToken).ConfigureAwait(false);
    return entity;
}
```

`DbSet.AddAsync` calls `DbContext.AddAsync` internally, which:

- Starts tracking the entity if not already tracked
- Marks it as `EntityState.Added`
- If the entity's `Id` is `default` (e.g., `Guid.Empty`), EF Core may generate a value depending on configuration (`ValueGeneratedOnAdd`)

**Note:** No database round-trip here. `AddAsync` only queues the entity for insertion.

### Step 5: SaveChangesAsync — Interceptor Pipeline

`EFCoreRepository.SaveChangesAsync`:

```csharp
public virtual async Task<int> SaveChangesAsync(CancellationToken cancellationToken = default)
{
    try
    {
        return await Context.SaveChangesAsync(cancellationToken).ConfigureAwait(false);
    }
    catch (DbUpdateConcurrencyException ex)
    {
        // Convert to domain exception with structured data
        throw new ConcurrencyConflictException(...);
    }
}
```

Calling `Context.SaveChangesAsync` triggers EF Core's `SavingChanges` interception pipeline **before** any SQL is generated.

#### Interceptor 1: AuditableInterceptor

Sets timestamps:

```csharp
foreach (var entry in context.ChangeTracker.Entries())
{
    if (entry.Entity is IAuditableEntity auditable)
    {
        if (entry.State == EntityState.Added && auditable.CreatedAt == default)
            auditable.CreatedAt = DateTime.UtcNow;
        else if (entry.State == EntityState.Modified)
            auditable.UpdatedAt = DateTime.UtcNow;
    }
}
```

**Before interceptor:**
- `product.CreatedAt == default(DateTime)` (0 or uninitialized)

**After interceptor:**
- `product.CreatedAt == 2026-04-29T14:30:00Z` (approx. now)

#### Interceptor 2: SoftDeletionInterceptor (skip for INSERT)

No action for `Added` state. Only interested in `Deleted` state.

#### Interceptor 3: AuditLoggerInterceptor (optional)

If configured, logs the pending changes to `ILogger`.

### Step 6: EF Core Generates INSERT

EF Core examines the change tracker, sees an `Added` entity, and generates parameterized SQL:

```sql
INSERT INTO [Products] ([Id], [Name], [Price], [CreatedAt], [UpdatedAt], [RowVersion])
VALUES (@p0, @p1, @p2, @p3, @p4, @p5);
```

Parameters:
- `@p0` = `'a1b2c3...'` (Guid)
- `@p1` = `'Widget'`
- `@p2` = `19.99`
- `@p3` = `'2026-04-29T14:30:00Z'` (set by interceptor)
- `@p4` = `NULL` (not set on INSERT)
- `@p5` = `0x0000000000000000` (RowVersion placeholder — DB will generate)

**Database actions:**

- Executes INSERT
- Generates new `RowVersion` binary value (e.g., `0x00000000000007D3`)
- Returns generated values if configured (`OUTPUT` clause or `RETURNING`)

### Step 7: AFTER SAVE — EF Core Updates Entity

After successful INSERT, EF Core:

1. Reads database-generated values (`RowVersion`, identity columns, computed columns)
2. Updates the tracked entity's properties
3. Marks entity as `EntityState.Unchanged`

**Entity state after SaveChanges:**

```csharp
product.Id        // Guid (from request.Id, unchanged)
product.Name      // "Widget"
product.Price     // 19.99m
product.CreatedAt // 2026-04-29T14:30:00Z (set by interceptor, persisted)
product.UpdatedAt // null (not set on insert)
product.RowVersion // byte[]{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0xD3 } (from DB)
```

### Step 8: Response Returns

Handler returns `Result<ProductDto>.Success(product.ToDto())`. The DTO includes the `RowVersion` if needed for subsequent updates (optimistic concurrency). The API layer serializes to JSON and returns HTTP `201 Created`.

## Data Flow: Updating an Entity (UPDATE with Concurrency)

### Step 1: Handler Fetches → Modifies → Updates

```csharp
public async Task<Result<ProductDto>> Handle(UpdateProductCommand request, CancellationToken ct)
{
    // Fetch existing entity (tracked)
    var product = await _repository.GetByIdAsync(request.Id, ct)
        ?? throw new NotFoundException($"Product {request.Id} not found");

    // Apply modifications
    product.Rename(request.NewName);
    product.UpdatePrice(request.NewPrice);

    // Mark as modified
    await _repository.UpdateAsync(product, ct);

    // Persist
    await _repository.SaveChangesAsync(ct);

    return Result<ProductDto>.Success(product.ToDto());
}
```

**Entity states:**

| Step | State |
|------|-------|
| After `GetByIdAsync` | `Unchanged` (tracked by DbContext) |
| After `Rename()` / `UpdatePrice()` (property setters) | `Modified` (EF Core detects changes automatically) |
| After `UpdateAsync` call | Still `Modified` (explicitly marks as modified, though already modified) |
| After `SaveChangesAsync` | `Unchanged` |

### Step 2: UpdateAsync Implementation

```csharp
public virtual async Task<TEntity> UpdateAsync(TEntity entity, CancellationToken cancellationToken = default)
{
    ArgumentNullException.ThrowIfNull(entity);

    // Fetch the currently tracked entity from database
    TEntity? existing = await DbSet.FindAsync([entity.Id], cancellationToken)
        ?? throw new InvalidOperationException($"Entity {typeof(TEntity).Name} with ID {entity.Id} not found.");

    // If caller passed a different instance (common), copy values
    if (!ReferenceEquals(existing, entity))
        applyConcurrencyValues(existing, entity);

    return existing;
}
```

**Why fetch first?** Fetching ensures EF Core's change tracker has the original entity state, including the **current `RowVersion` from the database**. This allows EF Core to generate a concurrency-optimistic UPDATE with a `WHERE RowVersion = @original` clause.

**`applyConcurrencyValues`:**

```csharp
private void applyConcurrencyValues(TEntity existing, TEntity callerEntity)
{
    byte[] callerRowVersion = callerEntity.RowVersion;
    Context.Entry(existing).CurrentValues.SetValues(callerEntity);
    // Set original value for concurrency check
    Context.Entry(existing).Property(e => e.RowVersion).OriginalValue = callerRowVersion;
}
```

This copies property values from the caller's entity into the tracked entity, but crucially sets the **original** `RowVersion` to the value the caller submitted. EF Core will use this original value in the `WHERE` clause.

### Step 3: SaveChangesAsync — Concurrency Check

EF Core generates:

```sql
UPDATE [Products]
SET [Name] = @p0, [Price] = @p1, [RowVersion] = ROWVERSION()
WHERE [Id] = @id AND [RowVersion] = @originalRowVersion
```

**If row matched (0 or 1 rows affected):**

- RowVersion in database differs from caller's original → concurrency conflict → `DbUpdateConcurrencyException` (zero rows affected)
- RowVersion matches → UPDATE succeeds → database generates new `RowVersion` → EF Core updates tracked entity

**Concurrency conflict handling:**

```csharp
catch (DbUpdateConcurrencyException ex)
{
    var entry = ex.Entries[0];
    string entityType = entry.Metadata.Name;
    string entityId = entry.Property("Id").CurrentValue?.ToString();
    byte[]? current = entry.Property("RowVersion").CurrentValue as byte[];
    byte[]? original = entry.Property("RowVersion").OriginalValue as byte[];

    throw new ConcurrencyConflictException(
        $"A concurrency conflict was detected for {entityType} with ID {entityId}...",
        entityType,
        entityId,
        current,
        original,
        ex
    );
}
```

**Handler catches and resolves:**

```csharp
try
{
    await _repo.UpdateAsync(updatedProduct, ct);
    await _repo.SaveChangesAsync(ct);
}
catch (ConcurrencyConflictException ex)
{
    // Re-fetch current DB state
    var current = await _repo.GetByIdAsync(ex.EntityId, ct);

    // Merge client's changes into current
    current.Rename(updatedProduct.Name);
    current.UpdatePrice(updatedProduct.Price);

    // Retry
    await _repo.UpdateAsync(current, ct);
    await _repo.SaveChangesAsync(ct);
}
```

The second `UpdateAsync` uses the fresh `RowVersion` from the database, guaranteeing the concurrency check passes.

### Alternative: Automatic Retry

For optimistic concurrency, you might retry automatically 2-3 times before surfacing an error to the user:

```csharp
int retries = 0;
while (retries < 3)
{
    try
    {
        await _repo.UpdateAsync(product, ct);
        await _repo.SaveChangesAsync(ct);
        break;
    }
    catch (ConcurrencyConflictException)
    {
        retries++;
        if (retries == 3) throw;
        // Refresh product from DB and re-apply changes
        var current = await _repo.GetByIdAsync(product.Id, ct);
        current.ApplyChangesFrom(product);
        product = current;
    }
}
```

## Data Flow: Deleting an Entity (Soft Delete)

```csharp
await _repo.DeleteAsync(product, ct);
await _repo.SaveChangesAsync(ct);
```

### Step 1: DeleteAsync Marks as Deleted

```csharp
public virtual Task<TEntity> DeleteAsync(TEntity entity, CancellationToken cancellationToken = default)
{
    _ = DbSet.Remove(entity);  // Marks EntityState.Deleted
    return Task.FromResult(entity);
}
```

At this point, the entity is still in memory, but `DbContext.Entry(entity).State == EntityState.Deleted`.

### Step 2: Interceptor Converts to Soft Delete

`SoftDeletionInterceptor.SavingChanges` scans `ChangeTracker.Entries()` for `ISoftDeletableEntity` entries with state `Deleted`. For each:

1. Check if already soft-deleted (`IsDeleted == true`) → if so, just set state to `Modified` (re-delete or re-soft-delete)
2. Change state to `Modified`
3. Set `IsDeleted = true`, `DeletedAt = DateTime.UtcNow`
4. Traverse navigations to cascade to children
5. Mark visited entities to prevent cycles

**SQL generated will be UPDATE**, not DELETE.

### Step 3: UPDATE Statement

```sql
UPDATE [Products]
SET [IsDeleted] = 1,
    [DeletedAt] = '2026-04-29T14:35:00Z'
WHERE [Id] = @id
```

Soft-deleted rows remain in the table, but `IsDeleted = 1` excludes them from all regular queries due to the global query filter.

### Cascade Example

```csharp
// Order has 3 OrderItems (all ISoftDeletableEntity)
await _orderRepo.DeleteAsync(order, ct);
await _orderRepo.SaveChangesAsync(ct);
```

Generated SQL (approximate):

```sql
UPDATE [OrderItems] SET IsDeleted = 1, DeletedAt = '...' WHERE Id = @itemId1;
UPDATE [OrderItems] SET IsDeleted = 1, DeletedAt = '...' WHERE Id = @itemId2;
UPDATE [OrderItems] SET IsDeleted = 1, DeletedAt = '...' WHERE Id = @itemId3;
UPDATE [Orders] SET IsDeleted = 1, DeletedAt = '...' WHERE Id = @orderId;
```

Order of operations: children first, then parent (due to recursive DFS ordering in the interceptor). This respects foreign key constraints.

## Transaction Boundaries

### Implicit Transaction (Single SaveChanges)

Default: Each `SaveChangesAsync` call runs in its own implicit transaction. If you call `SaveChangesAsync` once, that's one atomic transaction.

**Scope:**

```csharp
await _productRepo.AddAsync(p1, ct);
await _productRepo.AddAsync(p2, ct);
await _productRepo.AddAsync(p3, ct);
await _productRepo.SaveChangesAsync(ct);  // ONE transaction for all 3 INSERTs
```

All three `AddAsync` calls queue entities to the change tracker. When `SaveChangesAsync` is finally called, EF Core wraps the entire batch in a transaction (some databases batch automatically; EF Core explicitly starts/commits a transaction if needed).

### Explicit Transaction (Multiple SaveChanges)

When you need to commit work in stages (perhaps interspersed with external API calls), use explicit transactions:

```csharp
await _unitOfWork.BeginTransactionAsync(ct);
try
{
    await _orderRepo.AddAsync(order, ct);
    await _orderRepo.SaveChangesAsync(ct);  // Flush order to get generated OrderId

    // External call between saves (payment gateway)
    await _paymentService.ChargeAsync(order.Total, ct);

    // Now add line items (need OrderId from DB)
    foreach (var item in orderItems)
        await _orderRepo.AddAsync(item, ct);
    await _orderRepo.SaveChangesAsync(ct);

    await _unitOfWork.CommitTransactionAsync(ct);
}
catch
{
    await _unitOfWork.RollbackTransactionAsync(ct);
    throw;
}
```

**Important:** Multiple repositories in the same DI scope share the same `DbContext` and therefore the same ambient transaction.

## Error Propagation

### Concurrency Conflicts

`ConcurrencyConflictException` bubbles up from `SaveChangesAsync`. Handler decides resolution strategy (refresh + retry, abort with 409, or merge).

**Middleware translation to HTTP:**

```csharp
app.UseExceptionHandler(errorApp =>
{
    errorApp.Run(async context =>
    {
        var exception = context.Features.Get<IExceptionHandlerFeature>()?.Error;
        if (exception is ConcurrencyConflictException)
        {
            context.Response.StatusCode = StatusCodes.Status409Conflict;
            await context.Response.WriteAsJsonAsync(new
            {
                error = "concurrency_conflict",
                message = exception.Message,
                entityType = exception.EntityType,
                entityId = exception.EntityId
            });
        }
    });
});
```

### Database Exceptions

EF Core provider exceptions (e.g., `SqlException`, `NpgsqlException`, `SqliteException`) propagate as `DbUpdateException` or provider-specific types.

**Common cases:**

- **Unique constraint violation** → `DbUpdateException` inner exception has SQL error code (e.g., SQLite `SQLITE_CONSTRAINT_UNIQUE`, SQL Server `2601`/`2627`). Translate to domain error if needed.
- **Foreign key constraint violation** → similar, check error code → `ForeignKeyConstraintException` (custom domain exception).
- **Timeout** → `DbUpdateException` with inner `TimeoutException` → consider transient; retry with backoff.

**Example handler:**

```csharp
try
{
    await _repo.SaveChangesAsync(ct);
}
catch (DbUpdateException ex) when (IsUniqueConstraintViolation(ex))
{
    throw new DomainException($"A {entityName} with that name already exists.");
}
```

### Validation Errors

Validation occurs **before** reaching the repository, in the MediatR pipeline (FluentValidation). Repository methods do **not** validate business rules. Only guard against null arguments (`ArgumentNullException.ThrowIfNull`).

If you need validation at repository level (e.g., for programmatic use outside MediatR), implement domain methods on entities themselves:

```csharp
public void SetPrice(decimal newPrice)
{
    if (newPrice < 0)
        throw new DomainException("Price cannot be negative.");
    Price = newPrice;
}
```

## Entity States and Transitions

EF Core tracks each entity through one of these states:

| State | Meaning | How it gets there |
|-------|---------|-------------------|
| `Detached` | Not tracked | New entity not yet added to any `DbSet` |
| `Added` | Scheduled for INSERT | `DbSet.Add` or `AddAsync` |
| `Unchanged` | Tracked, no changes | After `SaveChangesAsync` where entity was Added/Modified; or after query with tracking |
| `Modified` | Scheduled for UPDATE | Property setter on a tracked entity; or `Entry(entity).State = Modified` |
| `Deleted` | Scheduled for DELETE | `DbSet.Remove` or `DeleteAsync` (may become Modified for soft-delete) |

**Transitions during CreateProduct flow:**

```
Detached (new Product()) 
  └─ AddAsync → Added
        └─ SaveChangesAsync → Unchanged
```

**Transitions during UpdateProduct flow:**

```
Unchanged (from GetByIdAsync)
  └─ property setter(s) → Modified
        └─ SaveChangesAsync → Unchanged (with new values)
```

**Transitions during DeleteProduct flow:**

```
Unchanged (from GetByIdAsync or tracked already)
  └─ DeleteAsync mark → Deleted
        └─ SoftDeletionInterceptor (state = Modified, soft-delete flags set)
              └─ SaveChangesAsync → Unchanged (soft-deleted)
```

## Lifecycle Hooks

EF Core provides virtual methods on `DbContext` for global lifecycle events:

- `SavingChanges` / `SavingChangesAsync` — **interceptors** run here (see above)
- `SavedChanges` / `SavedChangesAsync` — after database commit (for post-save logic)
- `ChangeTracker.Tracked` — when an entity enters the tracker
- `ChangeTracker.StateChanged` — when entity state transitions

You generally don't need these — interceptors cover most cross-cutting needs. Use only for diagnostics or custom behavior not suited to interceptors.

## Change Tracking and Identity Map

`DbContext` implements the **Identity Map** pattern — within a single context instance, each entity identity exists only once. If you query the same row twice, you get the same object reference.

```csharp
var p1 = await repo.GetByIdAsync(id, ct);  // Fetches from DB, tracks
var p2 = await repo.GetByIdAsync(id, ct);  // Returns same instance from tracker
ReferenceEquals(p1, p2); // true
```

This identity guarantee is why `UpdateAsync` can fetch the existing entity and assume it's the same instance your earlier query returned (if they're in the same context scope). If you pass an entity from a different context (detached), `UpdateAsync` fetches by ID and merges values.

## Performance Implications

### Number of Roundtrips

- **Create**: `AddAsync` (0 roundtrips) + `SaveChangesAsync` (1 roundtrip for INSERT)
- **Update**: `GetByIdAsync` (1 roundtrip) + `UpdateAsync` (0; still tracked) + `SaveChangesAsync` (1 roundtrip for UPDATE) = **2 roundtrips**
  - If entity is already tracked from earlier in the same scope, you can skip the `GetByIdAsync` and just modify it directly → **1 roundtrip**
- **Bulk operations**: 1 roundtrip per chunk (default 1,000 entities/chunk). 10,000 entities = ~10 roundtrips.

### N+1 Query Problem

The repository pattern does not automatically prevent N+1:

```csharp
var orders = await orderRepo.GetAllAsync();  // 1 query: SELECT * FROM Orders
foreach (var order in orders)
{
    var items = await orderRepo.Query()   // NEW query per iteration!
        .Where(i => i.OrderId == order.Id)
        .ToListAsync(ct);
}
```

**Fix via eager loading:**

```csharp
var orders = await orderRepo.Query()
    .Include(o => o.Items)
    .ToListAsync(ct);
// Items are already loaded for all orders
```

Or use explicit join:

```csharp
var ordersWithItems = await orderRepo.Query()
    .Select(o => new
    {
        Order = o,
        Items = o.Items.ToList()
    })
    .ToListAsync(ct);
```

## Summary Flowchart

```
Handler
  ├─ Create entity (new) → AddAsync → State: Added
  ├─ Read entity → GetAsync/GetAllAsync → State: Unchanged (tracked) or Unchanged (no-tracking)
  ├─ Modify tracked entity → property set → State: Modified (auto-detected)
  └─ Call SaveChangesAsync
        ↓
  Interceptors (Auditable → SoftDelete → AuditLogger)
        ↓
  EF Core generates SQL (INSERT/UPDATE/DELETE)
        ↓
  Database executes
        ↓
  EF Core updates entity state:
    - Added → Unchanged (IDs, RowVersion populated)
    - Modified → Unchanged (new values, new RowVersion)
    - Deleted → Detached (entity removed from context)
        ↓
  Control returns to handler with fresh entity state
```

Understanding this flow helps you:

- Predict when timestamps get set (just before INSERT/UPDATE, not in constructor)
- Know when `RowVersion` changes (after a successful `SaveChangesAsync`)
- Structure handlers to minimize roundtrips (track entities across multiple operations in one scope)
- Diagnose concurrency conflicts (original `RowVersion` must be preserved across read→update cycle)
