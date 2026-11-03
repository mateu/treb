# Dictionary verification policy

The broker freezes the operator-owned file selected by `BURT_VERIFICATION_POLICY`
for its lifetime. Candidate repository files never supply checks or policy.

To enable test-only verification on main, add `main:dictionary` alongside
`burt/dictionary:dictionary` in `~/.local/share/burt-policies/dictionary.json`.
Copy the entire existing dictionary entry (including `base_sha`, `baseline`,
`checks`, `argv`, `editable`, and `additions`) and set
`source_baseline` to `current_verified`. Do not replace or weaken the checks.
For example, generate the exact addition without modifying the live file:

```sh
jq '{"main:dictionary": (."burt/dictionary:dictionary" |
    .source_baseline = "current_verified")}' ~/.local/share/burt-policies/dictionary.json
```

Only `burt/dictionary:dictionary` and `main:dictionary` permit this mode.
The current broker-owned snapshot supplies effective `base_sha` and `baseline`;
checks, argv, editable paths and allowed additions stay frozen. Unapproved keys
still fail with `operator verification policy required for this project`.
Existing broker processes require their normal operator-controlled policy reload
procedure; editing the file alone does not hot-load it.

Both legacy `branch`/`project` reads and explicit `repo`/`ref`/`path` reads work.
Only `burt-agent/workspace` with exact `projects/<project>` paths is normalized
to a project key. This fixes the post-#84 explicit-read regression that left
`project` empty even for `projects/dictionary`. Other repos and nested or
unrelated paths do not inherit dictionary authorization.

Main jobs are test-only: no `from_job` commit (even to another branch), direct
saved-candidate selection, or gist publication. The repository publisher still
rejects main through unchanged `validate_destination`. Dictionary feature-branch
publication keeps its existing receipt and destination restrictions.
