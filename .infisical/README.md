# .infisical/: Infisical Agent Secret Management for Dotfiles

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│  Human Operator (you)                                       │
│  Holds the "dotfiles-provisioner" machine identity. It can  │
│  create projects and child identities but CANNOT read any   │
│  secret values.                                             │
└──────────────────┬──────────────────────────────────────────┘
                   │ INFISICAL_PROVISIONER_CLIENT_ID/SECRET
                   ▼
┌─────────────────────────────────────────────────────────────┐
│  provision.sh [slug...]   (or: provision.sh import <slug>)  │
│  For each project in projects.conf:                         │
│    1. Ensure the project exists                             │
│    2. Create a reader-only child identity                   │
│    3. Age-encrypt its credentials → children/<slug>/        │
│    4. Install the LaunchAgents (macOS)                      │
└──────────────────┬──────────────────────────────────────────┘
                   │ children/<slug>/client-id.age, client-secret.age, project-id
                   ▼
┌─────────────────────────────────────────────────────────────┐
│  LaunchAgent com.hole.infisical-agent.<slug>                │
│  (RunAtLoad + KeepAlive, logs ~/Library/Logs)               │
│    runs agent-run.sh <slug>, which:                         │
│      - age-decrypts the credentials with                    │
│        ~/.config/chezmoi/key.txt into                       │
│        ~/.local/state/infisical-agent/<slug>/ (700/600)     │
│      - writes the agent config there                        │
│      - execs `infisical agent`                              │
│  No keychain anywhere, so it works over SSH.                │
└──────────────────┬──────────────────────────────────────────┘
                   │ renders every 5 minutes
                   ▼
┌─────────────────────────────────────────────────────────────┐
│  ~/.infisical/<slug>-secrets.env   (mode 600)               │
│    dot_zshrc.tmpl sources backend-secrets.env               │
│    the godocs install script reads godocs-secrets.env       │
│    (no network call needed; the files are pre-rendered)     │
└─────────────────────────────────────────────────────────────┘
```

## Files

```
.infisical/
├── projects.conf               # The project list. Add a line to add a project.
├── provision.sh                # Creates identities, stores credentials (human-run)
├── agent-run.sh                # Wrapper: decrypt credentials, exec the agent
├── install-launchagents.sh     # Writes and (re)starts one LaunchAgent per project
├── lib.sh                      # Shared helpers
├── templates/
│   ├── _default.tpl            # Used when a project has no template of its own
│   ├── backend-secrets.tpl
│   ├── godocs-secrets.tpl
│   └── mcp-servers-secrets.tpl
└── children/                   # Per machine, gitignored
    └── <slug>/
        ├── client-id.age
        ├── client-secret.age
        └── project-id
```

Outside the repo:

| Path | What |
|---|---|
| `run_onchange_after_install-infisical-agents.sh.tmpl` | chezmoi runs `install-launchagents.sh` when the project list, the scripts, or the credentials change |
| `~/Library/LaunchAgents/com.hole.infisical-agent.<slug>.plist` | Generated LaunchAgent (no secrets in it) |
| `~/Library/Logs/infisical-agent-<slug>.log` | Agent log |
| `~/.local/state/infisical-agent/<slug>/` | Decrypted credentials, generated config and template (700/600) |
| `~/.infisical/<slug>-secrets.env` | Rendered secrets (600) |

## Security Model

### Provisioner Identity (human-held)
- **Capability:** Create projects, environments, child machine identities
- **Restriction:** Cannot read ANY secret values
- **Storage:** Client ID/Secret held in a password manager. Never on disk in the repo, never given to an agent.

### Child Agent Identities (agent-held)
- **Capability:** Read secrets from ONE project only
- **Restriction:** Cannot create, modify, or delete anything
- **Storage:** Age-encrypted to the chezmoi age key in `children/<slug>/`.
  `provision.sh` pipes the plaintext straight into `age`, so it never touches disk.
- **At runtime:** `agent-run.sh` decrypts them into
  `~/.local/state/infisical-agent/<slug>/` (owner-only). Anyone who can read
  that directory can already read `~/.config/chezmoi/key.txt`, so this adds no
  new exposure.

### Blast Radius
| Compromised Key | What an Attacker Gets |
|---|---|
| Provisioner | Can create new projects + child IDs, but NO secret values |
| A child identity | Read access to that one project |
| `~/.config/chezmoi/key.txt` | Every child identity on that machine (and the repo's other age-encrypted files) |

## projects.conf

One line per project:

```
# slug          envs        render-env  project-id
backend         dev,prod    prod        -
lav3-vespa      dev         dev         -
```

| Column | Meaning |
|---|---|
| `slug` | Infisical project slug. Names the identity, the LaunchAgent and `~/.infisical/<slug>-secrets.env`. |
| `envs` | Environments `provision.sh` checks for. |
| `render-env` | The environment rendered into the file. |
| `project-id` | Project UUID (not a secret). `-` means read `children/<slug>/project-id`, which `provision.sh` writes. Set it explicitly if the project's real slug differs (projects made in the UI can get a suffix), so `provision.sh` doesn't look it up by slug. |

The template is `templates/<slug>-secrets.tpl` if it exists, otherwise
`templates/_default.tpl`, which exports every key at path `/` of `render-env`.
In templates, `agent-run.sh` replaces `@PROJECT_ID@` and `@RENDER_ENV@`.

## Setup

### Step 1: Install tools
`infisical`, `age` and `jq` come from the Brewfiles. After `chezmoi apply`:
```bash
brew install infisical/get-cli/infisical age jq
```
The age key must be at `~/.config/chezmoi/key.txt` (or set `INFISICAL_AGE_KEY_PATH`).

### Step 2: Create the Provisioner Identity (once per org)
In Infisical Cloud (`app.infisical.com`):
1. Go to **Organization Settings → Access Control → Machine Identities**
2. Click **Create Identity**, name it `dotfiles-provisioner`
3. Assign an organization-level role that allows project creation
4. Add Universal Auth method
5. Generate Client ID + Client Secret
6. Store these in your password manager (they are NEVER committed to git)

### Step 3: Provision (on each machine)
```bash
export INFISICAL_ORG_ID="your-org-id"
export INFISICAL_PROVISIONER_CLIENT_ID="your-client-id"
export INFISICAL_PROVISIONER_CLIENT_SECRET="your-client-secret"

~/dotfiles/.infisical/provision.sh              # every project in projects.conf
~/dotfiles/.infisical/provision.sh lav3-vespa   # just one
```
Each run creates a new client secret for the identity it touches.

**Made the identity yourself?** (for example in the Infisical UI, with a
viewer role on the project) Import it instead. It prompts for the project ID,
client ID and client secret without echoing, and needs no Provisioner:
```bash
~/dotfiles/.infisical/provision.sh import lav3-vespa
```

Either way, on macOS the script then installs and starts the LaunchAgents.

### Step 4: Verify
Check key names only. Never print values.
```bash
launchctl print gui/$(id -u)/com.hole.infisical-agent.<slug> | grep -E 'state|pid'
tail ~/Library/Logs/infisical-agent-<slug>.log
grep -oE '^(export )?[A-Za-z_][A-Za-z0-9_]*=' ~/.infisical/<slug>-secrets.env
```

## Adding a project

1. Add a line to `projects.conf`.
2. Optional: add `templates/<slug>-secrets.tpl` to choose which keys to render.
3. Run `provision.sh <slug>`, or `provision.sh import <slug>`.

`chezmoi apply` also picks up new credentials, because the run script hashes
`children/*/client-secret.age`.

## Operating the agents

| Task | Command |
|---|---|
| Restart one | `launchctl kickstart -k gui/$(id -u)/com.hole.infisical-agent.<slug>` |
| Stop one | `launchctl bootout gui/$(id -u)/com.hole.infisical-agent.<slug>` |
| Reinstall all | `~/dotfiles/.infisical/install-launchagents.sh` |
| Run in the foreground (also over SSH) | `~/dotfiles/.infisical/agent-run.sh <slug>` |
| Remove one | Delete its line from `projects.conf` (or its `children/<slug>/`), then run `install-launchagents.sh` |

`install-launchagents.sh` removes any `com.hole.infisical-agent.*` agent
whose slug is no longer listed or has no credentials.

### Login and reboot

These are LaunchAgents, so they load when you log in at the console (or
through Screen Sharing). After a reboot, nothing runs until someone logs in:
**an SSH login alone does not start them.** The last rendered files stay on
disk in the meantime, so shells still get the previous values.

On a headless Mac that needs the agents running straight after boot, choose
one of:
- turn on automatic login for the user (System Settings → Users & Groups;
  needs FileVault off), or
- install the same plist as a LaunchDaemon in `/Library/LaunchDaemons` with a
  `UserName` key (needs sudo; not automated here).

On Linux there is no installer yet. Run `agent-run.sh <slug>` under systemd
or a similar supervisor.

## Migration from Doppler

Doppler is legacy. It fails over SSH because it reads the macOS keychain
(dotfiles#5). Read secrets from the rendered `~/.infisical/<slug>-secrets.env`
files instead. Doppler fallbacks in older scripts are left in place until
those scripts are migrated.
