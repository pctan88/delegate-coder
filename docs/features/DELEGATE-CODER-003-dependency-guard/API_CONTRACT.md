# API contract: dependency manifest guard

## Contract input (new optional field)

```json
{
  "target_file": "package.json",
  "instructions": "Move keycloak-angular to the Angular 22 compatible major.",
  "test_command": "npm ci && npm run build",
  "allow_downgrade": ["keycloak-angular"]
}
```

`allow_downgrade` is optional and defaults to rejecting every downgrade. It
accepts either:

- a JSON array of package name strings — only those names may move backward;
- the boolean `true` — every downgrade in this contract is permitted.

Invalid shapes (anything else) are rejected by `validate_contract_input`
before branch creation or model contact, same as the existing
`context_files` array-of-strings check.

## Verification (new step, runs after syntax preflight, before `test_command`)

Only when `target_file`'s basename is a guarded manifest name
(`scripts/lib/validate_dependency_manifest.MANIFEST_NAMES` — currently just
`package.json`):

1. Parse the pre-contract original and the candidate as JSON (a parse
   failure here is a "should be impossible" defensive check — the `json)`
   syntax preflight case already rejects malformed JSON one step earlier).
2. For every dependency present in the candidate's `dependencies`,
   `devDependencies`, `peerDependencies`, or `optionalDependencies`:
   - If its version string doesn't match `\d+\.\d+\.\d+(-...|+...)?` after
     stripping a leading range operator (`^`, `~`, `>=`, `<=`, `>`, `<`, `=`),
     and isn't one of the recognized unvalidatable forms (`workspace:`,
     `npm:`, `file:`, `link:`, `git+`, `git:`, `http(s)://`, `*`, `latest`,
     `next`) — **fail**, naming the package and the offending string.
   - Else if the same package existed in the original manifest with a
     comparable (parseable, validatable) version, and the new
     (major, minor, patch) tuple is lexicographically less than the old one,
     and the package name is not covered by `allow_downgrade` — **fail**,
     naming the package, both versions, and the escape hatch.
3. Any dependency with no comparable baseline (new package, or either side
   unvalidatable) is skipped rather than compared.

On failure: `LAST_FAILURE_TYPE=DEPENDENCY_GUARD`; the guard's full findings
list is written to the same `TEST_LOG` the report renders under "Final test
log", and — like every other failure type — feeds the router's existing
one-shot correction retry verbatim as the worker's "exact terminal error
output".

## Reports and exit behavior (new status value)

`- Status:` may now additionally read `DEPENDENCY_GUARD_FAIL`. `delegate.sh`'s
contract-mode `CONTRACT_STATUS` whitelist was extended to pass this value
through to the audit log verbatim (previously any status outside
`PASS|NOOP|FAIL|PREFLIGHT_FAIL|TEST_FAIL` was logged as the generic `ERROR`,
which would have hidden this new status entirely).

A `test_command` timeout (`timeout`/`gtimeout` exit 124, or the `perl alarm`
fallback's SIGALRM exit 142) still reports `- Status: TEST_FAIL` unchanged,
but now adds `- Hint:` text identifying it as a likely stall and naming the
configured `DELEGATE_TEST_TIMEOUT`, rather than being indistinguishable from
an assertion failure.

## Security invariants (unchanged, reaffirmed)

- No network call is made by this guard; it compares two JSON documents
  already on disk. This preserves the project's local-only privacy stance.
- The guard cannot be used to smuggle arbitrary code execution: it only
  reads `dependencies`-shaped keys of a JSON object via `json.loads`, never
  `eval`/`exec`, and never shells out with manifest content interpolated
  into a command string.
