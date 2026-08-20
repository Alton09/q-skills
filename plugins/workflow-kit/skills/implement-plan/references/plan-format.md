# Plan Format Reference

Referenced from `SKILL.md`. This is the shape `feature-plan` emits and the Step 1 prep agent
parses. Show it to a user whose plan fails structure validation.

## Required structure

Each phase is a `###` section whose tasks are checkboxes (`- [ ]` / `- [x]`) — the skill
reads and rewrites those boxes to track progress. Two optional-but-load-bearing extras:
`**Files**:` per phase (drives the file-overlap safety check in 5a.1) and a
`## Task Dependency Graph` block (drives parallel scheduling).

## Example

``markdown
# Feature: Recipe Favorites

## Overview
Add ability to mark recipes as favorites and filter by them.

## Phases

### Phase 1: Domain Layer
- [ ] Create Favorite use case in domain/favorites/
- [ ] Create FavoritesRepository interface
- [ ] Add unit tests for use case

### Phase 2: Data Layer
- [ ] Implement FavoritesRepositoryImpl
- [ ] Add Room entity and DAO
- [ ] Add data layer tests

### Phase 3: UI Layer
- [ ] Create FavoritesViewModel with UDF state
- [ ] Build Favorites Compose screens
- [ ] Add UI tests

### Phase 4: Integration
- [ ] Wire up navigation
- [ ] Integration tests across layers
- [ ] Manual testing (happy path + edge cases)

## Tests
- FavoritesUseCaseTest: ≥80% coverage
- FavoritesRepositoryImplTest: ≥80% coverage
- FavoritesViewModelTest: ≥80% coverage

## Edge Cases
- Favorite a recipe, then delete it from system
- Toggle favorite state rapidly
- Sync favorites across multiple devices (if applicable)
```

