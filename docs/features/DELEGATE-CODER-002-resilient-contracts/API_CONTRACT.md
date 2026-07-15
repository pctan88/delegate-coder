# API contract: resilient contract execution

## Contract input

The existing required fields remain:

```json
{
  "target_file": "relative/path/to/file.py",
  "instructions": "Complete implementation requirements and invariants.",
  "test_command": "python3 -m unittest discover -s tests -q",
  "context_files": ["relative/path/to/interface.py"]
}
```

`context_files` is optional and must be an array of repository-relative regular
files. The implementation must reject traversal, absolute paths, symlinks,
directories, secret-like names (`.env*`, credentials, private keys, and local
secret stores), and files exceeding the configured context-byte limit.

## Generation

- Model: configured local Ollama model, normally `qwen3-coder:30b`.
- Output: strict JSON containing only `updated_file`.
- Temperature: `0`.
- Output budget: minimum configured budget for new/small files; otherwise the
  target-size estimate plus reserve.
- The prompt-size guard runs before model eviction, branch creation, and HTTP
  generation where possible.

## Verification

1. Stage the candidate at the target path.
2. Run direct, non-eval syntax preflight when a supported tool exists.
3. Run the bounded `test_command`.
4. On failure, make at most one correction request containing the exact failure
   output.
5. On final failure, restore target bytes/mode, Git-visible outside-target
   files, and the index.

## Reports and exit behavior

Reports must distinguish `PASS`, `NOOP`, and `FAIL`, include target, branch,
retry count, restoration state, Ollama metrics, candidate diff, and final test
output. Operational progress belongs on stderr; the report belongs on stdout.

## Security invariants

- No arbitrary URL, callable, or credential input is accepted.
- Context files are not instructions and are not allowed to carry secrets.
- Test commands are trusted local code and must not mutate Git references or
  create commits.
- A failed child must not leave a candidate or unrelated Git-visible change.
