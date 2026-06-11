# Agent & contributor guide

> ## 🔴 ALWAYS `git pull` BEFORE EDITING
> Multiple developers and AI agents work in this repo. Pull the latest `main`
> before making any change:
> ```bash
> git pull --rebase origin main
> ```
> Start every session with a pull, and pull again before a new edit if time has
> passed. Never edit on top of a stale or unknown base.

> ## 🚀 ALWAYS DEPLOY EDITS TO THE VPS
> After changes build and pass checks, ship them live:
> ```bash
> bash scripts/deploy.sh        # backend + web, with health + md5 verification
> ```
> The repo machine's SSH key is already accepted by the VPS — runs without
> prompts. (`scripts/deploy.sh backend` or `… web` for one side.)

See **[CLAUDE.md](CLAUDE.md)** for the full working guide (layout, build/verify
commands, migrations, deploy). The rules above apply to all agents and humans.
