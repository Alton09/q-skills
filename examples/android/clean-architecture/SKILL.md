---
name: clean-architecture
description: >
  Load Android project architecture rules and layer conventions into context.
  Use this skill to get architecture rules, layer rules, conventions, or structural
  guidelines before implementing — called automatically by implement-plan before each phase.
---

# Clean Architecture Rules

Reference rules for the project. Callers (implement-plan, feature-plan) load these before
writing code so every phase stays consistent.

## Three Layers

### Presentation
- Compose UI screens + ViewModel
- ViewModel exposes `StateFlow<UiState>` — single source of truth for UI state
- No business logic in composables; composables only render state and emit events
- Depends on: **domain** (use cases, entities)

### Domain
- Use cases, entities, repository *interfaces*
- Zero Android framework imports (`android.*`, `androidx.*`) — pure Kotlin
- Depends on: **nothing** (the core; no outward dependencies)

### Data
- Repository *implementations*, Room entities + DAOs, Retrofit DTOs
- Mappers between domain entities and data-layer models
- Depends on: **domain** (implements domain interfaces)

## Dependency Direction

```
presentation → domain ← data
```

Neither presentation nor data depends on the other. Domain depends on nothing.

## Naming Conventions

| Artifact | Convention | Layer |
|---|---|---|
| ViewModel | `XxxViewModel` | presentation |
| Use case | `XxxUseCase` | domain |
| Repository interface | `XxxRepository` | domain |
| Repository implementation | `XxxRepositoryImpl` | data |
| Room entity | `XxxEntity` | data |
| DTO | `XxxDto` | data |
| Mapper | `XxxMapper` | data |

## Dependency Injection

Use Hilt throughout. Provide bindings in `@Module` classes; inject via constructor injection
wherever possible. Do not use `ServiceLocator` patterns or access `Hilt` outside of
`@AndroidEntryPoint`-annotated entry points.

## NEVER

- **Never** import `android.*` or `androidx.*` in the domain layer.
- **Never** call a repository implementation directly from presentation — go through a use case.
- **Never** put business logic in a composable function.
- **Never** expose Room entities or Retrofit DTOs to the domain layer — map to domain entities first.
- **Never** let data and presentation depend on each other.
