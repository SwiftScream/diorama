# Contributing

## Commit messages

Keep each commit focused on one coherent, reviewable change. When a behavior
change needs preparatory refactoring, make the behavior-preserving refactoring
an initial commit and layer the behavior change on top of it.

For a change belonging to a plan unit, format the subject as:

```text
{plan-id}-{local-unit-id}: {type}({scope}): {subject}
```

For example:

```text
003-A01: docs(evidence): record local toolchain feasibility
```

For changes outside a plan, omit the plan prefix:

```text
docs(agents): document commit message convention
```

Use one primary plan unit per commit. If the scope is not useful, omit the
parenthesized scope, for example `003-A01: docs: update evidence`. The type
must be one of `feat`, `fix`, `ref`, `docs`, `test`, `ci`, `style`, or `chore`.

Write the subject in the imperative mood and omit a final period. Aim for a
subject of 72 characters or fewer as a strong recommendation; choose a clear,
slightly longer subject rather than a confusing abbreviation. Write body
sentences in the present tense, such as “Record local Linux evidence.”

Merge commits, reverts, and automated dependency updates may use the form
required by their tool. Describe breaking changes in the body. Commitlint can
enforce the structural parts of this convention when CI is established;
imperative mood and clear present-tense prose remain review expectations.
