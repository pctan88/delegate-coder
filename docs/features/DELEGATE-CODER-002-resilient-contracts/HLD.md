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
router and dispatcher reject absolute paths, traversal, symlinks, directory
components, secret/credential-like filenames (e.g. `.env*`, `.npmrc`, keys),
blocked credential directories (e.g. `.aws/`, `.ssh/`), and symlinked parent
directories. Files must be within the conservative limit of 64KB per file
and 256KB total context size.
Context is included after the task instructions under a clearly labeled
untrusted-reference section. Its bytes count toward the prompt budget.

## Output budgeting

The output budget is the larger of the target-size estimate plus reserve and
the configured minimum for new/small files (enforcing a safety floor of 4096 tokens).
The router validates and rejects the request early if prompt plus output cannot
fit inside `num_ctx`; Ollama truncation remains a hard failure.

## Syntax preflight

Preflight uses direct argument vectors for `bash -n`, Python compilation
(invoking the active project interpreter with target compilation to `$WORK_DIR/target.pyc`),
`node --check`, and `tsc --noEmit`. It must not construct a shell command with
`eval`, because a repository filename is untrusted input. Safe argument passing
guarantees metacharacters in filenames are handled without shell expansion.

## Compatibility

Absent contract configuration keeps the existing agent backend and
`read`/`exec` adapter behavior. The frozen v1 benchmark remains untouched.
