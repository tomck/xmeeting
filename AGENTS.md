# Codex commit attribution

Before making an authorized commit in this repository:

- Ensure `git config --local core.hooksPath .githooks` is enabled in this
  checkout. Do not change the user's global Git configuration.
- Use `Scripts/codex-commit.sh` instead of plain `git commit` for Codex work.
- Explicitly supply `--model`, `--reasoning-effort`, and `--thread` with the
  actual model, reasoning effort, and current task ID. Do not guess missing
  metadata or silently reuse values from a different task or model.
- Astra Extra High is labeled `gpt-6-astra` with effort `xhigh`. This is an
  example, not a default to apply when another model or effort is active.
- Verify the resulting message contains the Codex co-author, model, effort,
  and task trailers. Ordinary human commits should remain untouched.

The hook adds attribution, not a cryptographic signature. Installing it does
not authorize a commit, push, history rewrite, or release.
