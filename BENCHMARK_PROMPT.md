# Ready-to-paste prompt for Claude Code

Open a terminal in this folder, start `claude`, and paste the prompt below.
Fill in the one placeholder first: `<TARGET_REPO>` = absolute path to a local git repo with a working test suite.

---

Run the delegate-coder benchmark in this repo. Read CLAUDE.md and benchmark/README.md first, then follow this exactly:

1. Verify prerequisites: `claude` CLI, `jq`, and at least one worker agent via `bash skills/delegate-coder/scripts/detect.sh`. If any is missing, stop and tell me what to install.

2. Target repo: `<TARGET_REPO>`. Confirm it is a clean git checkout, find its test command, and tell me the base commit you will benchmark against. Do not proceed until I confirm.

3. Rewrite benchmark/tasks.json with 6–12 real tasks for that repo, covering all four categories (bulk-read, implement, refactor, review). Each task needs an objective `verify` command that exits 0 on success. Show me the tasks for approval before running anything.

4. Smoke run: REPS=1 with the first two tasks only. Show me the resulting JSON from benchmark/results/ and confirm cost_usd, success, and skill_triggered fields look sane.

5. On my go-ahead, run the full benchmark:
   `cd benchmark && REPO_DIR=<TARGET_REPO> SKILL_SRC=$(pwd)/../skills/delegate-coder REPS=3 bash run_benchmark.sh`
   It is resumable; if interrupted, just rerun the same command.

6. Generate the report with `python3 report.py results/ tasks.json` and write benchmark/RESULTS.md containing the table plus: Claude model, worker agent + model, target repo + commit, REPS, and today's date. Include per-category numbers and call out any category where the skill lost.

Important: each run is a full `claude -p` session and consumes my real Claude usage — never expand the run matrix beyond what I approved, and pause for my confirmation at steps 2, 3, and 4.

---

## Notes

- No target repo in mind? A reasonable default is to `git clone --depth 1` a small OSS project with fast tests (e.g. a utility library with `npm test` or `pytest` finishing in under a minute) and benchmark against that. Mention this to Claude Code and it can set one up — but a repo of your own gives more representative numbers for the README.
- Budget rough guide: tasks × 2 conditions × REPS sessions. 8 tasks × 2 × 3 = 48 Claude Code sessions. Start the full run when you have usage headroom.
- The worker agent (e.g. MiMo) must be authenticated before the run; see skills/delegate-coder/references/setup.md.
