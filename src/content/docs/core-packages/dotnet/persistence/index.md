---
title: NFramework Persistence for .NET
description: Production-grade data access abstraction layer built on Entity Framework Core with repository pattern, unit of work, soft delete, audit tracking, and dynamic queries — all with strict Clean Architecture boundaries.
---

import { LinkCard, CardGrid } from '@astrojs/starlight/components';

## Introduction

NFramework Persistence provides a complete data access solution for .NET services following Clean Architecture principles. It combines EF Core's power with repository/unit-of-work abstractions, automatic audit tracking, soft deletion with cascade support, and dynamic query capabilities — all while maintaining strict layer boundaries and AOT compatibility.

## Quick Start

Install the packages in your Infrastructure.Persistence project:

```xml
<PackageReference Include="NFramework.Persistence.Abstractions" Version="1.0.0" />
<PackageReference Include="NFramework.Persistence.EFCore" Version="1.0.0" />
```

Define an entity inheriting from `Entity<Guid>`:

```csharp{1,5}
using NFramework.Persistence.Abstractions.Entities;

public sealed class Product : Entity<Guid>
{
    public Product(Guid id, string name, decimal price) : base(id)
    {
        Name = name;
        Price = price;
    }

    public string Name { get; set; }
    public decimal Price { get; set; }
}
```

Create a repository:

```csharp{1,3,5}
public interface IProductRepository
    : IReadRepository<Product, Guid>,
      IWriteRepository<Product, Guid>,
      IDynamicReadRepository<Product, Guid>,
      IUnitOfWork { }

internal sealed class ProductRepository(
    MyDbContext context
) : EFCoreRepository<Product, Guid, MyDbContext>(context),
    IProductRepository { }
```

Use in a handler:

```csharp{1,5,7}
public async Task<ProductDto> Handle(CreateProductCommand request, CancellationToken ct)
{
    var product = new Product(request.Id, request.Name, request.Price);
    await _repository.AddAsync(product, ct);
    await _repository.SaveChangesAsync(ct);
    return product.ToDto();
}
```

## Documentation Sections

<CardGrid>
  <LinkCard title="Overview" href="/core-packages/dotnet/persistence/overview/" description="Architecture, layer responsibilities, core concepts, and data lifecycle." />
  <LinkCard title="Integration Guide" href="/core-packages/dotnet/persistence/integration-guide/" description="Step-by-step walkthrough: entities, DbContext, DI registration, repositories, endpoints, handlers." />
  <LinkCard title="API Reference" href="/core-packages/dotnet/persistence/api-reference/" description="Complete type signatures, interface contracts, extension methods, and attribute reference." />
  <LinkCard title="Advanced Topics" href="/core-packages/dotnet/persistence/advanced-topics/" description="AOT compilation, performance tuning, custom repositories, multi-tenancy, testing, migrations." />
</CardGrid>

## Key Features

### Clean Architecture Enforced

The persistence layer depends only on abstractions. Domain and Application layers reference `NFramework.Persistence.Abstractions` (zero external dependencies). Infrastructure references Abstractions and implements with EF Core. No reverse dependencies.

### Entity Base Classes

`Entity<TId>` — foundation with identity and optimistic concurrency via `RowVersion`.

`AuditableEntity<TId>` — automatic `CreatedAt` and `UpdatedAt` timestamp management via interceptor.

`SoftDeletableEntity<TId>` — logical delete with `IsDeleted` / `DeletedAt`, cascade soft-delete through navigations.

### Repository Pattern

Single abstract base (`EFCoreRepository`) implements four interfaces:

- **IReadRepository** — typed queries, pagination, filtering
- **IWriteRepository** — CRUD with optimistic concurrency, bulk operations
- **IDynamicReadRepository** — runtime-dynamic string-based queries
- **IQueryRepository** — raw `IQueryable` access for custom compositions

All repositories also implement `IUnitOfWork` for transaction coordination.

### Automatic Interceptors

- **AuditableInterceptor** — sets `CreatedAt` / `UpdatedAt` automatically
- **SoftDeletionInterceptor** — converts deletes into soft deletes, cascades through relationships
- **AuditLoggerInterceptor** — optional change auditing to `ILogger`

No manual timestamp or soft-delete flag management required.

### Dynamic Query Engine

Filter and order by property name at runtime using `Filter` and `Order` objects:

```csharp
var options = new DynamicQueryOption
{
    Filters =
    [
        new Filter("Category", FilterOperator.Equals, "Electronics"),
        new Filter("Price", FilterOperator.GreaterThan, 100)
    ],
    Orders = [new Order("CreatedAt", OrderDirection.Desc)]
};
var results = await repo.GetAllByDynamicAsync(options);
```

## Architecture at a Glance

```
Service.slnx
├── core/
│   ├── MyService.Domain/              ← Entities inherit from Entity<Guid>
│   └── MyService.Application/         ← Handlers depend on IRepository<T>
├── infrastructure/
│   └── MyService.Infrastructure.Persistence/
│       ├── InfrastructureServiceRegistrationExtensions.cs  ← DI setup
│       ├── Features/Entities/        ← EF Core configurations
│       └── Shared/Database/
│           ├── Contexts/BaseDbContext.cs
│           └── Models/DatabaseConfiguration.cs
└── presentation/
    └── MyService.WebApi/
        └── Program.cs ← AddApplicationLayer() + AddInfrastructureServices()
```

**Dependency flow:**

```
Api → Application, Infrastructure
Infrastructure → Application, Domain
Application → Domain
Domain → (nothing)
```

## Try It Out

The `NFramework.Persistence.AotSample` project under `tests/smoke/` demonstrates:

- AOT-compatible entity definitions
- Explicit DI registration (no reflection/scanning)
- Repository usage with `EFCoreRepository`
- Dynamic query execution
- Migration application via `host.ApplyMigrationsAsync<TContext>()`

Build and run the sample to validate Native AOT compatibility.

## Next Steps

- Read the [Integration Guide](./integration-guide/) to wire persistence into a generated service
- Consult the [API Reference](./api-reference/) for full method signatures
- Explore [Advanced Topics](./advanced-topics/) for AOT, performance, and custom patterns
