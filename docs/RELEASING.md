# Releasing ge-mcp (maintainer crib sheet)

All commands from the repo root. Identity for anything public: **MARVVV**
with the GitHub noreply email (never the personal one).

## 0. Pre-flight

```
python tests/offline/run_all.py
python -u scripts/regression.py        [editor open + poller armed; all green]
python scripts/docgen.py               [refreshes docs/TOOLS.md]
```

## 1. Version bump (three places move together)

- `ge_mcp/__init__.py` → `__version__`
- `pyproject.toml` → `version`
- `CHANGELOG.md` → new top section

```
git add -A
git -c user.name="MARVVV" -c user.email="marvvv@users.noreply.github.com" commit -m "x.y.z: ..."
```

## 2. Build both artifacts

```
git archive --format=zip --prefix=GiantsEditor-mcp/ -o ..\ge-mcp-<ver>.zip HEAD
python scripts/build_mcpb.py
```

[the mcpb builder reads the version from the package automatically;
both land next to the repo. Verify: no `__pycache__`, no `*.full.json`,
no `map_backups` inside either archive]

## 3. Refresh the public branch (squashed, identity-safe)

The `main` branch holds full dev history (stays local). The `public` branch is
a single squashed commit — the only thing ever pushed.

```
git checkout public
git checkout main -- .
git add -A
git -c user.name="MARVVV" -c user.email="marvvv@users.noreply.github.com" commit -m "ge-mcp <ver>"
git checkout main
```

[first time only: `git checkout --orphan public` instead of `git checkout public`]

## 4. Push + GitHub release

With GitHub CLI (`winget install GitHub.cli`, then `gh auth login`, once).
NOTE: in cmd.exe use `cd /d D:\...` — plain `cd` does not switch drives.

```
git checkout public
git push origin public:main
git checkout main
gh release create v<ver> ..\ge-mcp-<ver>.mcpb ..\ge-mcp-<ver>.zip --title "ge-mcp <ver>" --notes "..."
```

[first time the repo was created with:
`gh repo create giants-editor-mcp --public --source . --remote origin`
then `git push -u origin public:main` — there is NO --branch flag on repo create]

Web alternative: github.com → New repository (public, empty) →
`git remote add origin https://github.com/<user>/giants-editor-mcp.git` →
`git push -u origin public:main` → repo page → *Releases* → *Draft a new
release* → tag `v<ver>` → attach the `.mcpb` and `.zip` → *Publish*.

## 5. Announce

Point people at the release page; the `.mcpb` is the headline download,
the `.zip` for Claude Code users. Remind: Python 3.10+ + `pip install mcp`
(Step 0 of INSTALL.md).
