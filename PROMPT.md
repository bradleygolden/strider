# Strider: Vision & Design Principles

## What Strider Is

A sandbox runtime abstraction. Create isolated execution environments across different infrastructure backends.

## Core Principle

**Operations are abstract. Config is concrete.**

- `create`, `exec`, `terminate`, `read_file`, `write_file` work identically across adapters
- Config uses real values (`memory_mb: 2048`, `ports: [4001]`), not abstract mappings
- Adapters translate config to infra-specific API calls

## Interface Goals

1. **Consistent operations** - Same function signatures across all adapters
2. **Concrete config** - Callers specify actual values, no magic mappings
3. **Sensible defaults** - Minimize required config, but don't hide what's happening
4. **Adapter-specific escape hatches** - When needed, pass through infra-specific options

## What Strider Does NOT Do

- Map abstract concepts (`memory: :medium`) to concrete values
- Hide infrastructure details behind layers of indirection
- Make decisions the caller should make

## Goal

Your task is to make this repo clean AF for users. Do this by:

1. Reviewing the codebase
2. Refactoring as needed
3. Reviewing your changes

## Workflow

Commit after each completed shippable change. Small, atomic commits that each leave the codebase in a working state.
