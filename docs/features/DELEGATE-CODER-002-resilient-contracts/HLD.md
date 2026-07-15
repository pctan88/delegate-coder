# High-level design: resilient contract execution

## Boundary

The cloud orchestrator remains responsible for decomposition, dependency
analysis, security decisions, and final acceptance. `delegate.sh contract` is
an opt-in local execution boundary. It receives one JSON contract, prepares an
isolated branch, asks Ollama for a complete target file, runs bounded checks,
and either accepts the target or restores the pre-child Git-visible state.

## Flow

```text
contract JSON
    |
    v
validate shape, target, context, limits, and runner
    |
    v
preflight prompt budget -> create/use delegate branch -> snapshot state
    |
    v
Ollama structured generation {updated_file}
    |
    v
stage target -> direct syntax preflight -> project test command
    |                         |
    | failure                 | pass
    v                         v
one correction, then rollback  restore pre-child index and accept target
```

## Context handling

`context_files` are explicit, repository-relative, read-only references. The
router must reject absolute paths, traversal, symlinks, directories, secret
filenames, and files over the configured byte budget before model contact.
Context is included after the task instructions under a clearly labeled
untrusted-reference section. Its bytes count toward the prompt budget.

## Output budgeting

The output budget is the larger of the target-size estimate plus reserve and
the configured minimum for new/small files. The router rejects the request if
prompt plus output cannot fit inside `num_ctx`; Ollama truncation remains a
hard failure.

## Syntax preflight

Preflight uses direct argument vectors for `bash -n`, Python compilation,
`node --check`, and `tsc --noEmit`. It must not construct a shell command with
`eval`, because a repository filename is untrusted input.

## Compatibility

Absent contract configuration keeps the existing agent backend and
`read`/`exec` adapter behavior. The frozen v1 benchmark remains untouched.
