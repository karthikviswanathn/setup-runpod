# setup-runpod

One-command setup of a RunPod pod for working with Claude Code, Codex, tmux and friends,
with everything persistent on `/workspace`.

## Quick start

From the Mac (recommended, also syncs auth):

```bash
# First time on a new pod (paste whatever ssh command RunPod shows, "ssh" prefix optional):
./setup-pod.sh abc123-xyz@ssh.runpod.io

# Connect and work (attaches persistent tmux session "main"):
./pod.sh

# Plain shell instead of tmux:
./pod.sh shell
```

The pod is remembered in `.last-pod`, so after the first run both scripts work with
no arguments.

Or directly on the pod (web terminal or any ssh session), no Mac needed:

```bash
curl -fsSL https://raw.githubusercontent.com/karthikviswanathn/setup-runpod/main/bootstrap.sh -o /workspace/bootstrap.sh && bash /workspace/bootstrap.sh
```

This installs everything, but cannot sync auth from the Mac. If the `/workspace`
volume already has logins from an earlier `setup-pod.sh` run they keep working;
on a fresh volume, log in once (`claude` then `/login`, and `codex login` or run
`./setup-pod.sh` from the Mac).

## What it installs

| Tool | How | Where | Persistent? |
|---|---|---|---|
| Claude Code | official native installer | `/workspace/home/.local` | yes, self-updates land there too |
| Codex | npm | `/workspace/npm-global` | yes |
| node + npm | tarball | `/workspace/tools/node` | yes |
| uv | official installer | `/workspace/bin` | yes |
| tmux, git, ripgrep, htop, vim, ... | apt | container disk | no, reinstalled in seconds |

All tool state is redirected to `/workspace` via environment variables in
`/workspace/pod_env.sh` (hooked into `~/.bashrc`):

- Claude Code config and login: `CLAUDE_CONFIG_DIR=/workspace/home/.claude`
- Codex config and login: `CODEX_HOME=/workspace/home/.codex`
- git config: `GIT_CONFIG_GLOBAL=/workspace/home/.gitconfig`
- tmux config: `/workspace/home/.config/tmux/tmux.conf` (via `XDG_CONFIG_HOME`)
- Hugging Face, pip and uv caches: `/workspace/cache/...`
- bash history: `/workspace/home/.bash_history`

Personal additions (extra exports, aliases) go in `/workspace/pod_env.local.sh`,
which survives bootstrap re-runs.

Note: Codex stays on npm deliberately. Its native installer's tar step aborts on
`/workspace` because network volumes refuse `chown` (the npm package ships the same
`codex-cli` binary without that problem). Claude's native installer is run with
`HOME=/workspace/home` for the same reason node is extracted with `--no-same-owner`.

## Auth

`setup-pod.sh` pushes these from your Mac to the pod, only if the pod does not
already have them (use `--sync-auth` to force a re-push):

- `~/.codex/auth.json` and `~/.codex/config.toml` (Codex login + your model defaults)
- Claude Code credentials, exported from the macOS Keychain
- `~/.claude/CLAUDE.md` (global instructions) and `~/.gitconfig`

If the Keychain export is unavailable, run `claude` on the pod and `/login` once.
Logins land on `/workspace`, so they survive restarts either way.

## After a pod restart

The container disk (apt packages, `~/.bashrc`, `~/.ssh/authorized_keys`) is wiped on
every stop/start, but `/workspace` is not. Just re-run:

```bash
./setup-pod.sh
```

It reinstalls the few apt packages, re-hooks the environment, and refreshes the
cached direct connection (the pod's public ip/port change on restart). Takes seconds,
since Claude, Codex, node and all your logins are already on `/workspace`.

From inside the pod you can also run `bash /workspace/bootstrap.sh` directly
(a copy is kept there), but that won't refresh `.last-pod` for `pod.sh`.

## Flags

- `./setup-pod.sh --update` - update Claude Code, Codex and uv to latest
- `./setup-pod.sh --sync-auth` - force re-push of auth/config files from the Mac

## How the connection works

RunPod's `ssh.runpod.io` proxy only supports interactive shells: no command
execution, no scp/sftp. So when given a proxy address, `setup-pod.sh` drives one
scripted interactive session to:

1. add your public key to the pod's `~/.ssh/authorized_keys` if missing (the pod
   only picks up account-level keys at start, so keys added later never arrive
   without this), and
2. read `$RUNPOD_PUBLIC_IP` / `$RUNPOD_TCP_PORT_22` to discover the direct
   TCP connection.

All real work then runs over direct ssh (`root@<ip> -p <port>`), which is cached in
`.last-pod`. This requires the pod template to expose TCP port 22 ("SSH over exposed
TCP"), which the standard RunPod PyTorch templates do by default.

## Notes

- The default key is `~/.ssh/runpod/id_ed25519`; pass `-i <key>` to override.
  The key must be registered in RunPod account settings for the proxy to work.
- Assumes the usual Ubuntu-based RunPod images (root user, apt available).
