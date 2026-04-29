---
title: Advanced Topics
description: Advanced patterns and optimization techniques for NFramework Persistence, covering Native AOT compilation, performance tuning, custom repositories, multi-tenancy, testing strategies, and migration management.
---

## Native AOT Support

Native AOT (Ahead-of-Time) compilation produces self-contained native executables with fast startup times and reduced memory footprint. NFramework.Persistence supports AOT with specific constraints and patterns.

### AOT Requirements

**Project configuration:**

```xml
<PropertyGroup>
  <OutputType>Exe</OutputType>
  <TargetFramework>net11.0</TargetFramework>
  <PublishAot>true</PublishAot>
  <InvariantGlobalization>true</InvariantGlobalization>
  <Nullable>enable</Nullable>
  <ImplicitUsings>enable</ImplicitUsings>
  <!-- Suppress IL trimming warnings for known EF Core/Dynamic LINQ limitations -->
  <NoWarn>$(NoWarn);IL2104;IL3000;IL3053;IL2026;IL3050;IL3002</NoWarn>
</PropertyGroup>
```

**Package references:**

```xml
<PackageReference Include="NFramework.Persistence.Abstractions" Version="1.0.0" />
<PackageReference Include="NFramework.Persistence.EFCore" Version="1.0.0" />
<!-- Use EF Core compiled model for AOT -->
<PackageReference Include="Microsoft.EntityFrameworkCore.Sqlite" Version="8.0.0" />
```

### DynamicallyAccessedMembers Attributes

EF Core constructs entity types and mappings via reflection at runtime. The trimmer removes unused members unless explicitly preserved. NFramework uses `[DynamicallyAccessedMembers]` on generic type parameters to instruct the trimmer to keep required constructors, properties, and fields.

**On `EFCoreRepository`:**

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
    [DynamicallyAccessedMembers(DynamicallyAccessedMemberTypes.PublicConstructors)]
    TId,
    [DynamicallyAccessedMembers(
        DynamicallyAccessedMemberTypes.PublicConstructors
            | DynamicallyAccessedMemberTypes.PublicMethods)]
    TContext>(TContext context)
{ }
```

**When extending repository**, preserve the attribute on your generic type parameters:

```csharp
public partial class ProductRepository<TContext> : EFCoreRepository<Product, Guid, TContext>
    where TContext : DbContext
{
    // No additional attributes needed — inherited from base class
}
```

If you create **new generic base classes** inheriting from `EFCoreRepository`, re-apply the attribute:

```csharp
public abstract class CustomRepository<TEntity, TId, TContext>(
    TContext context
) : EFCoreRepository<TEntity, TId, TContext>(context)
    where TEntity : Entity<TId>
    where TContext : DbContext
{
    [DynamicallyAccessedMembers(
        DynamicallyAccessedMemberTypes.PublicConstructors
            | DynamicallyAccessedMemberTypes.PublicProperties)]
    public abstract class BaseEntity { }
}
```

### Dynamic Queries and AOT

**System.Linq.Dynamic.Core** uses runtime compilation and reflection; it is **NOT AOT-compatible**. All methods in `IDynamicReadRepository` are marked `[RequiresUnreferencedCode]`.

**Consequences:**

- Calling dynamic query methods will emit trim warnings (IL2026, IL2104, etc.).
- The application may fail at runtime with `MissingMetadataException` or `MissingMethodException` if required types were trimmed.
- Dynamic queries will not work on **Native AOT** without disabling trimming (not recommended) or including all dynamic query types via `DynamicDependency` attributes (complex and fragile).

**Recommended approaches for AOT:**

1. **Use typed queries only.** Leverage `IReadRepository` and `IQueryRepository` with strongly-typed LINQ expressions:

   ```csharp
   var products = await _repository.GetAllAsync(
       new QueryOption<Product>(
           Predicate: p => p.Category == category && p.Price > minPrice,
           OrderBy: q => q.OrderBy(p => p.Name)
       ),
       ct
   );
   ```

2. **Create query-specialized repository methods** that encapsulate common filter combinations:

   ```csharp
   public interface IProductRepository : IReadRepository<Product, Guid>
   {
       Task<IReadOnlyList<Product>> GetByCategoryAsync(string category, CancellationToken ct);
       Task<IReadOnlyList<Product>> SearchAsync(string term, CancellationToken ct);
   }
   ```

3. **Use Specification pattern** (not included by default). Implement your own `ISpecification<T>` interface that compiles to `Expression<Func<T, bool>>` rather than string-based filters.

4. **Conditional compilation** (if you must support both AOT and non-AOT builds):

   ```csharp
   #if !AOT
   var results = await _dynamicRepo.GetAllByDynamicAsync(options, ct);
   #else
   var results = await _repository.GetAllAsync(
       new QueryOption<Product>(/* build typed predicate */),
       ct
   );
   #endif
   ```

### Migrations and AOT

`ApplyMigrationsAsync<TContext>()` is marked `[RequiresDynamicCode]` because EF Core needs to build the design-time model to compute pending migrations. This method will fail on Native AOT.

**Alternatives:**

1. **Pre-generate migration scripts** and run them as part of the deployment pipeline:

   ```bash
   dotnet ef migrations script --idempotent -o migrate.sql
   # Then execute migrate.sql against target database
   ```

2. **Migration bundles** — EF Core tools can produce a self-contained executable that applies migrations standalone:

   ```bash
   dotnet ef migrations bundle --self-contained -o migrate.exe
   # Run migrate.exe at deployment time
   ```

3. **Manual migration applier** that executes raw SQL from a bundled resource:

   ```csharp
   public class SqlMigrationApplier : IHostedService
   {
       public async Task StartAsync(CancellationToken ct)
       {
           var sql = await ReadEmbeddedResource("Migrations.001_initial.sql");
           await using var cmd = context.Database.GetDbConnection().CreateCommand();
           cmd.CommandText = sql;
           await cmd.ExecuteNonQueryAsync(ct);
       }
   }
   ```

### AOT Checklist

- [ ] All entities have explicit constructors with ID + obsolete parameterless constructor
- [ ] Repository registrations are **explicit** (no `Assembly.Scan()`)
- [ ] No dynamic query methods called in production code paths
- [ ] If calling methods with `[RequiresUnreferencedCode]`, verify with `dotnet publish -c Release` that no trim errors surface
- [ ] Consider `PublishAot=true` with `InvariantGlobalization=true` for smallest binary
- [ ] Test published binary thoroughly — reflection-based features fail silently under AOT

## Performance Optimization

### Query Performance

1. **Use pagination** — Always paginate list endpoints:

   ```csharp
   // Correct
   var page = await repo.GetListAsync(new PageableQueryOption<Order>());

   // Incorrect — risk of OOM
   var all = await repo.GetAllAsync();  // Limited to 10,000, but still heavy
   ```

2. **Avoid N+1 queries** — Use `Include()` only through `IQueryRepository.Query()`:

   ```csharp
   // Good: eager load with Include
   var ordersWithItems = await orderRepository.Query()
       .Include(o => o.Items)
       .Take(100)
       .ToListAsync(ct);

   // Bad: lazy loading not configured; causes N+1 if accessing Items in loop
   ```

3. **Project to DTOs** to avoid entity overhead:

   ```csharp
   var dtos = await productRepository.Query()
       .Where(p => p.IsActive)
       .Select(p => new ProductListDto
       {
           Id = p.Id,
           Name = p.Name,
           Category = p.Category.Name  // joined property
       })
       .ToListAsync(ct);
   ```

4. **Use compiled queries** for hot paths (EF Core feature):

   ```csharp
   private static readonly Func<MyServiceDbContext, Guid, Task<Product?>>
       _getByIdCompiled = EF.CompileAsyncQuery(
           (MyServiceDbContext ctx, Guid id) =>
               ctx.Products.FirstOrDefault(p => p.Id == id)
       );

   public async Task<Product?> GetByIdCompiledAsync(Guid id, CancellationToken ct)
       => await _getByIdCompiled(Context, id);
   ```

   Compile once, reuse: avoids LINQ expression tree compilation on each call.

### Write Performance

1. **Batch size tuning** — Default `MaxBatchSize = 1000`. Larger batches reduce roundtrips but increase memory:

   ```csharp
   public override int MaxBatchSize => 5000;   // Larger batches for ETL jobs
   ```

2. **Disable change tracking for bulk reads** — Use `QueryTrackingMode.NoTracking`.

3. **Soft-delete cascade depth** — Keep `MaxCascadeDepth` reasonable (default 50). Deep cascades indicate aggregate boundary issues; consider redesign.

### Memory Management

- `DbContext` is **scoped per request**. Do not create long-lived contexts.
- `AsNoTracking()` on read-only queries → entities are not tracked → less memory.
- `ExecuteWithLimitAsync` prevents runaway queries.

### Connection Pooling

Configure in connection string:

| Provider | Pooling config |
|----------|----------------|
| SQL Server | `"Max Pool Size=100;Min Pool Size=0;"` |
| PostgreSQL | `"Maximum Pool Size=100;Minimum Pool Size=0;"` (via Npgsql) |
| SQLite | No pooling (file-based; consider connection per request) |

## Custom Repository Patterns

### Overriding Base Behavior

Extend base repository with `partial` methods or override virtual methods:

```csharp
public partial class ProductRepository : EFCoreRepository<Product, Guid, MyDbContext>
{
    // Custom read method not on base interface
    public async Task<IReadOnlyList<Product>> GetActiveAsync(CancellationToken ct)
    {
        return await DbSet
            .Where(p => p.IsActive && !p.IsDeleted)
            .OrderBy(p => p.Name)
            .ToListAsync(ct);
    }

    // Override bulk operation batch size
    protected override int MaxBatchSize => 2000;

    // Override result limit per query
    protected override int? MaxResultSetSize => 5000;
}
```

**Note:** Base class is `partial`. You can place custom methods in your own file without touching generated scaffolding.

### Custom Interface Adding Domain-Specific Operations

Define your repository interface with domain-specific methods:

```csharp
public interface IOrderRepository
    : IReadRepository<Order, OrderId>,
      IWriteRepository<Order, OrderId>,
      IUnitOfWork
{
    Task<decimal> GetTotalRevenueAsync(DateTime from, DateTime to, CancellationToken ct);
    Task<IReadOnlyList<Order>> GetByCustomerAsync(CustomerId customerId, CancellationToken ct);
    Task MarkAsShippedAsync(OrderId orderId, TrackingInfo tracking, CancellationToken ct);
}
```

Implement custom methods by calling `Query()` (inherited from `IQueryRepository`) or `DbSet` directly:

```csharp
public async Task<decimal> GetTotalRevenueAsync(DateTime from, DateTime to, CancellationToken ct)
{
    return await DbSet
        .Where(o => o.Status == OrderStatus.Completed && o.CreatedAt >= from && o.CreatedAt <= to)
        .SumAsync(o => o.TotalAmount, ct);
}
```

### Composing Multiple Repositories (Domain Services)

When a use case spans multiple aggregates, inject multiple repositories:

```csharp
public class CreateOrderWithInventoryReservationHandler
    : IRequestHandler<CreateOrderCommand, Result<Guid>>
{
    private readonly IOrderRepository _orderRepo;
    private readonly IProductRepository _productRepo;

    public async Task<Result<Guid>> Handle(CreateOrderCommand request, CancellationToken ct)
    {
        // Both repositories share the same DbContext (scoped)
        var order = Order.Create(request.OrderId, request.CustomerId);
        await _orderRepo.AddAsync(order, ct);

        foreach (var item in request.Items)
        {
            var product = await _productRepo.GetByIdAsync(item.ProductId, ct)
                ?? throw new NotFoundException($"Product {item.ProductId} not found");

            product.ReserveStock(item.Quantity);  // Domain method
            await _productRepo.UpdateAsync(product, ct);
        }

        await _orderRepo.SaveChangesAsync(ct);  // Single transaction across both
        return Result<Guid>.Success(order.Id);
    }
}
```

**Important:** Both repositories must be registered with the **same `DbContext` type** (e.g., `MyServiceDbContext`) to participate in the same unit of work.

### Domain Service Pattern

If a domain operation doesn't naturally belong to a single aggregate, extract a domain service:

```csharp
public interface IInventoryService
{
    Task<bool> CanFulfillAsync(ICollection<OrderItem> items, CancellationToken ct);
    Task ReserveAsync(ICollection<OrderItem> items, CancellationToken ct);
    Task ReleaseAsync(ICollection<OrderItem> items, CancellationToken ct);
}

public sealed class InventoryService : IInventoryService
{
    private readonly IProductRepository _productRepo;

    public async Task<bool> CanFulfillAsync(ICollection<OrderItem> items, CancellationToken ct)
    {
        foreach (var grp in items.GroupBy(i => i.ProductId))
        {
            var product = await _productRepo.GetByIdAsync(grp.Key, ct);
            if (product == null || product.AvailableStock < grp.Sum(i => i.Quantity))
                return false;
        }
        return true;
    }
}
```

Register in Application layer DI.

## Multi-Tenancy Patterns

Multi-tenant applications isolate data per tenant (organization/customer). Two main approaches:

### 1. Tenant ID Discriminator (Shared Database)

Add `TenantId` column to every table. All queries filter by `TenantId`.

**Entity:**

```csharp
public abstract class TenantEntity<TId> : Entity<TId>, ITenantEntity
    where TId : IEquatable<TId>
{
    public Guid TenantId { get; private set; }
}
```

**Global query filter:**

```csharp
public sealed class BaseDbContext : DbContext
{
    private readonly ICurrentTenantService _tenantService;

    public BaseDbContext(DbContextOptions<BaseDbContext> options, ICurrentTenantService tenantService)
        : base(options)
    {
        _tenantService = tenantService;
    }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.ApplyTenantFilter<ITenantEntity>(e => e.TenantId, _tenantService.TenantId);
    }
}
```

Or per-entity:

```csharp
builder.HasQueryFilter<Product>(p => p.TenantId == _tenantService.TenantId);
```

**Querying:**

All auto-queries filter by current tenant. Expose tenant ID via middleware that sets `HttpContext.Items["TenantId"]` → `ICurrentTenantService`.

### 2. Separate Database per Tenant

Each tenant gets its own database (connection string). Resolve repository with tenant-specific `DbContext`.

**Factory pattern:**

```csharp
public interface IMyServiceDbContextFactory
{
    MyServiceDbContext Create(Guid tenantId);
}

public sealed class TenantDbContextFactory : IMyServiceDbContextFactory
{
    private readonly IServiceProvider _serviceProvider;

    public MyServiceDbContext Create(Guid tenantId)
    {
        // Resolve DbContextOptions from DI, then inject tenant-specific connection string
        var options = _serviceProvider.GetRequiredService<DbContextOptions<MyServiceDbContext>>();
        var connectionString = _connectionStringProvider.GetForTenant(tenantId);
        return new MyServiceDbContext(options, connectionString);
    }
}
```

**Usage in handler:**

```csharp
var context = _contextFactory.Create(tenantId);
var repo = new ProductRepository(context);
await repo.GetAllAsync(...);
```

Separate databases provide strong isolation but increase operational complexity.

## Validation and Business Rules

Persistence layer does **not** enforce business validation. Use:

### Domain Invariants (inside entity)

```csharp
public sealed class Product : Entity<ProductId>
{
    public void SetPrice(decimal newPrice)
    {
        if (newPrice < 0)
            throw new DomainException("Price cannot be negative.");
        if (newPrice == 0)
            throw new DomainException("Price must be greater than zero.");

        Price = newPrice;
    }
}
```

### Application Validation (FluentValidation)

```csharp
public class CreateProductCommandValidator : AbstractValidator<CreateProductCommand>
{
    public CreateProductCommandValidator()
    {
        RuleFor(x => x.Name)
            .NotEmpty()
            .MaximumLength(200)
            .Matches("^[a-zA-Z0-9\\s-]+$")
            .WithMessage("Name contains invalid characters.");

        RuleFor(x => x.Price)
            .GreaterThanOrEqualTo(0.01m)
            .LessThanOrEqualTo(1000000m);
    }
}
```

Validators run via MediatR pipeline behaviors automatically.

### Database Constraints

EF Core Fluent API enforces schema constraints:

```csharp
builder.Property(p => p.Email)
    .HasMaxLength(254)
    .IsRequired();

builder.HasIndex(p => p.Email).IsUnique();
```

Database-level constraints are the final safety net even if application validation is bypassed.

## Testing Strategies

### Unit Tests (Repository Interface)

Mock repository interfaces, not implementations:

```csharp
var repoMock = new Mock<IProductRepository>();
repoMock.Setup(r => r.GetByIdAsync(It.IsAny<Guid>(), It.IsAny<CancellationToken>()))
       .ReturnsAsync((Guid id, CancellationToken ct) => new Product(new ProductId(id), "Test", 10));

var handler = new GetProductHandler(repoMock.Object);
```

For dynamic query testing, mock `GetAllByDynamicAsync` to return datasets.

### Integration Tests (Real Repository)

Use **SQLite in-memory** with EF Core real database operations:

```csharp
public class ProductRepositoryIntegrationTests : IAsyncLifetime
{
    private MyServiceDbContext _context = null!;

    public async Task InitializeAsync()
    {
        var options = new DbContextOptionsBuilder<MyServiceDbContext>()
            .UseSqlite("DataSource=:memory:")
            .Options;

        _context = new MyServiceDbContext(options);
        await _context.Database.OpenConnectionAsync();
        await _context.Database.EnsureCreatedAsync();
    }

    [Test]
    public async Task AddAsync_ShouldPersistEntity()
    {
        var repo = new ProductRepository(_context);
        var product = new Product(ProductId.New(), "Test", 10m);
        await repo.AddAsync(product);
        await repo.SaveChangesAsync();

        var fromDb = await repo.GetByIdAsync(product.Id);
        fromDb.Should().NotBeNull();
    }

    public async Task DisposeAsync()
    {
        await _context.Database.CloseConnectionAsync();
        await _context.DisposeAsync();
    }
}
```

### Concurrent Update Testing

Test concurrency handling with **two parallel contexts**:

```csharp
[Test]
public async Task ConcurrentUpdate_ShouldThrowConcurrencyConflict()
{
    // Context A fetches entity
    var optionsA = new DbContextOptionsBuilder<MyDbContext>().UseSqlite("...").Options;
    await using var contextA = new MyDbContext(optionsA);
    var repoA = new ProductRepository(contextA);
    var productA = await repoA.GetByIdAsync(id);

    // Context B updates same entity
    var optionsB = new DbContextOptionsBuilder<MyDbContext>().UseSqlite("...").Options;
    await using var contextB = new MyDbContext(optionsB);
    var repoB = new ProductRepository(contextB);
    var productB = await repoB.GetByIdAsync(id);
    productB.Price = 999;
    await repoB.SaveChangesAsync();

    // Context A tries to update — should throw
    productA.Price = 123;
    var act = () => repoA.UpdateAsync(productA);
    await act.Should().ThrowAsync<ConcurrencyConflictException>();
}
```

## Migrations and Database Evolution

### Applying Migrations

**At application startup:**

```csharp
public class MigrationApplier : IHostedService
{
    public async Task StartAsync(CancellationToken ct)
    {
        using var scope = _serviceProvider.CreateScope();
        var context = scope.ServiceProvider.GetRequiredService<MyDbContext>();
        await context.Database.MigrateAsync(ct);
    }

    public Task StopAsync(CancellationToken ct) => Task.CompletedTask;
}
```

**Via hosted extension:**

```csharp
await host.ApplyMigrationsAsync<MyDbContext>();
```

### Applying Migrations in CI/CD

Recommended for production:

1. **Generate SQL script** in build:

   ```bash
   dotnet ef migrations script --idempotent -o migrations.sql
   ```

2. **Execute script** as part of the deployment:

   ```bash
   psql -U user -d dbname -f migrations.sql   # PostgreSQL
   sqlcmd -S server -d dbname -i migrations.sql  # SQL Server
   ```

This avoids needing `.NET` runtime or design-time packages on production servers.

### Creating Migrations

**Add migration**:

```bash
dotnet ef migrations add AddProductCategory --project src/infrastructure/MyService.Infrastructure.Persistence.csproj
```

EF Core generates migration with `CreateTable`, `AddColumn`, etc. Verify migration code — it should match your domain changes.

## Database Provider Considerations

NFramework Persistence is provider-agnostic; supported EF Core providers work:

| Provider | NuGet Package | AOT status |
|----------|--------------|------------|
| SQLite | `Microsoft.EntityFrameworkCore.Sqlite` | ✅ AOT-supported |
| SQL Server | `Microsoft.EntityFrameworkCore.SqlServer` | ✅ AOT-supported |
| PostgreSQL | `Npgsql.EntityFrameworkCore.PostgreSQL` | ✅ AOT-supported (Npgsql 8+) |
| InMemory | `Microsoft.EntityFrameworkCore.InMemory` | ❌ For testing only |

**SQLite appsettings:**

```json
{
  "Infrastructure": {
    "Persistence": {
      "ConnectionString": "Data Source=myservice.db"
    }
  }
}
```

**SQL Server:**

```json
{
  "Infrastructure": {
    "Persistence": {
      "ConnectionString": "Server=localhost;Database=MyService;Trusted_Connection=true;"
    }
  }
}
```

**Connection pooling:** Enabled by default. Adjust `Max Pool Size` based on expected concurrency.

## Advanced Interceptor Scenarios

### Custom Interceptor for Tenant ID Injection

```csharp
public class TenantIdInterceptor : SaveChangesInterceptor
{
    private readonly ICurrentTenantService _tenantService;

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

Register:

```csharp
services.AddScoped<TenantIdInterceptor>();
services.AddDbContext<MyDbContext>((sp, options) =>
{
    var interceptor = sp.GetRequiredService<TenantIdInterceptor>();
    options.UseSqlite(...).AddInterceptors(interceptor);
});
```

### Audit Log Interceptor

Log all changes to a separate audit table:

```csharp
public class AuditLogInterceptor : SaveChangesInterceptor
{
    public override async ValueTask<InterceptionResult<int>> SavingChangesAsync(
        DbContextEventData eventData,
        InterceptionResult<int> result,
        CancellationToken cancellationToken = default
    )
    {
        var context = eventData.Context!;
        var auditEntries = new List<AuditLog>();

        foreach (var entry in context.ChangeTracker.Entries())
        {
            if (entry.Entity is IAuditableEntity)
            {
                auditEntries.Add(new AuditLog
                {
                    EntityName = entry.Metadata.Name,
                    EntityId = entry.Property("Id").CurrentValue?.ToString(),
                    State = entry.State.ToString(),
                    Timestamp = DateTime.UtcNow
                });
            }
        }

        context.Set<AuditLog>().AddRange(auditEntries);
        return await base.SavingChangesAsync(eventData, result, cancellationToken);
    }
}
```

### Soft-Delete Cascade Customization

Override `MaxCascadeDepth` per-context:

```csharp
services.AddDbContext<MyDbContext>(options =>
    options.AddSoftDeleteInterceptor(maxCascadeDepth: 100) // deeper cascade for specific service
);
```

Or at runtime per-repository:

```csharp
public class MyRepository : EFCoreRepository<..., MyDbContext>
{
    public override int MaxCascadeDepth => 25;  // Limit to 25 for this entity type only
}
```

## Cross-Cutting Concerns

### Logging

Use standard `ILogger<T>` in handlers and repositories:

```csharp
internal sealed class ProductRepository : EFCoreRepository<Product, Guid, MyDbContext>, IProductRepository
{
    private readonly ILogger<ProductRepository> _logger;

    public ProductRepository(MyDbContext context, ILogger<ProductRepository> logger)
        : base(context)
    {
        _logger = logger;
    }

    public async Task<IReadOnlyList<Product>> GetActiveAsync(CancellationToken ct)
    {
        _logger.LogDebug("Fetching active products");
        var products = await DbSet.Where(p => p.IsActive).ToListAsync(ct);
        _logger.LogInformation("Found {Count} active products", products.Count);
        return products;
    }
}
```

For EF Core SQL logging, configure `EnableSensitiveDataLogging()` in development:

```csharp
#if DEBUG
options.EnableSensitiveDataLogging();
#endif
```

### Caching

The framework does not cache. Add a caching layer via repository decorator:

```csharp
public class CachingProductRepository : IProductRepository
{
    private readonly IProductRepository _inner;
    private readonly IMemoryCache _cache;
    private readonly TimeSpan _ttl = TimeSpan.FromMinutes(5);

    public async Task<Product?> GetByIdAsync(Guid id, CancellationToken ct)
    {
        return await _cache.GetOrCreateAsync(id, async entry =>
        {
            entry.AbsoluteExpirationRelativeToNow = _ttl;
            return await _inner.GetByIdAsync(id, ct);
        })!;
    }
}
```

Register decorator:

```csharp
services.Decorate<IProductRepository, CachingProductRepository>();
```

### Event Sourcing Considerations

NFramework Persistence is not an event-sourcing framework. For event-sourced systems, replace repository implementations entirely while keeping interfaces.

```csharp
public class EventSourcedProductRepository : IProductRepository
{
    // Implementation reads from event store, reconstructs aggregates
    // SaveChangesAsync persists new events instead of EF changes
}
```

## Security

### SQL Injection Protection

Dynamic queries use parameterized SQL automatically (via Dynamic LINQ). Values are passed as parameters, never string-concatenated:

```csharp
var filter = new Filter("Name", FilterOperator.Contains, userInput);
// Generates parameterized query: WHERE Name LIKE @p0
```

**Do not** concatenate user input into filter `Field` names — field names cannot be parameterized. Validate field names against allow-list if using dynamic columns.

### Sensitive Data Encryption

For PII (email, phone, SSN), consider EF Core value converters:

```csharp
builder.Property(p => p.Email)
    .HasConversion(
        v => Encrypt(v),        // To DB
        v => Decrypt(v)         // From DB
    );
```

Encryption can be AES with key from Azure Key Vault, AWS KMS, or user-provided key.

### Row-Level Security

Use EF Core query filters for multi-tenant row-level security:

```csharp
builder.HasQueryFilter<Product>(p => p.DepartmentId == _currentUser.DepartmentId);
```

## Monitoring and Observability

### Health Checks

ASP.NET Core health checks:

```csharp
builder.Services.AddHealthChecks()
    .AddDbContextCheck<MyServiceDbContext>("database");

app.MapHealthChecks("/health");
```

### Prometheus Metrics

Use `AddPrometheusHealthChecks()` if available in your projects, or instrument manually:

```csharp
public class MetricsMiddleware
{
    private readonly ILogger<MetricsMiddleware> _logger;
    private static readonly Counter RequestCounter = Metrics.CreateCounter("http_requests_total", ...);

    public async Task InvokeAsync(HttpContext context, RequestDelegate next)
    {
        var timer = Stopwatch.StartNew();
        await next(context);
        timer.Stop();

        RequestCounter
            .WithLabels(context.Request.Method, context.Response.StatusCode.ToString())
            .Inc();
    }
}
```

### EF Core Interception for Queries

Custom interceptor to log slow queries:

```csharp
public class SlowQueryInterceptor : DbCommandInterceptor
{
    private readonly ILogger<SlowQueryInterceptor> _logger;
    private readonly TimeSpan _slowThreshold = TimeSpan.FromMilliseconds(500);

    public override InterceptionResult<DbDataReader> ReaderExecuting(
        DbCommand command,
        CommandEventData eventData,
        InterceptionResult<DbDataReader> result
    )
    {
        var stopwatch = Stopwatch.StartNew();
        var interceptionResult = base.ReaderExecuting(command, eventData, result);
        stopwatch.Stop();

        if (stopwatch.Elapsed > _slowThreshold)
        {
            _logger.LogWarning(
                "Slow query ({ElapsedMs}ms): {Sql}",
                stopwatch.ElapsedMilliseconds,
                command.CommandText
            );
        }

        return interceptionResult;
    }
}
```

Register:

```csharp
options.AddInterceptors(new SlowQueryInterceptor());
```

## Future Roadmap

Planned enhancements (subject to change):

- **Dapper adapter** — Raw SQL / Dapper-based repository implementation
- **CQRS separation** — Separate read and write model bases
- **Event sourcing adapters** — Projections and event store integration
- **Repository refresh** — Optimistic concurrency with client-side merge helpers
- **Bulk extension from EF** — Direct use of `ExecuteDelete` / `ExecuteUpdate` for bulk operations
- **GraphQL provider** — Automatic resolver generation from repositories

---

With these advanced patterns, you can scale NFramework Persistence to complex enterprise scenarios while maintaining clean architecture boundaries and performance.
