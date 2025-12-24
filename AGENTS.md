# ExecPlans

When writing complex features or significant refactors, use an ExecPlan (as described in .agent/PLANS.md) from design to implementation. Store plans in the .plans directory at the root of this project.

# Conventions

Avoid using the process dictionary unless it truly benefits the implementation. If there is an explicit alternative, use it.

Avoid Process.sleep or any other blocking operations in tests that could result in flakiness. Prefer message passing as an alternative.

Only write comments if they are critical, otherwise don't.

Do not write backwards compatible code.

Avoid using try/catch blocks unless it is absolutely necessary.

The "let it crash" philosophy (sometimes called "let it fail") is a core design principle in Erlang/Elixir that takes a counterintuitive approach to error handling: instead of writing defensive code to handle every possible error condition, you let processes crash and rely on supervisors to restart them.

When to still handle errors explicitly:
  * Expected, recoverable conditions (user input validation, file not found, etc.)
  * Boundary code interacting with external systems where you want graceful degradation
  * When crashing would lose important state that can't be reconstructed

  The philosophy isn't "never handle errors" — it's "don't handle errors you can't meaningfully recover from." Let the supervision tree do its job.
