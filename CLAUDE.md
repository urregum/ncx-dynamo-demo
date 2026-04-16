# Claude Code — Project Instructions

## Pre-commit hooks

This repo uses pre-commit hooks enforced by CI on every PR. Always run them
before committing to catch issues locally:

```bash
.venv/bin/pre-commit run --all-files
```

If hooks auto-fix files (trailing whitespace, end-of-file newline), stage
those changes and re-run before committing — do not commit without a clean
pass.

Pre-commit is in `requirements.txt`. If `.venv/bin/pre-commit` is not found,
install it first:

```bash
pip install -r requirements.txt
pre-commit install && pre-commit install --hook-type commit-msg
```

## Branch and PR workflow

All changes go on a feature branch — direct commits to `main` are blocked by
branch protection. Follow the naming convention from CONTRIBUTING.md:

```
feat/short-description
fix/short-description
docs/short-description
chore/short-description
```

Open a PR against `main`; CI runs `pre-commit --all-files` and validates the
PR title follows Conventional Commits format. Squash-merge is the expected
merge strategy.

## Commit messages

Follow Conventional Commits (`type(scope): description`). Commit bodies must
include `Signed-off-by:` (gitlint enforces this locally; CI checks the PR
title format for the squash commit).
