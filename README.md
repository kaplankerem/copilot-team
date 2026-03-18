# 🧠 KK-Orchestrator

**Multi-agent AI team orchestration for GitHub Copilot CLI.**

Launch a full software development team of AI agents with a single command. Each agent runs in its own Windows Terminal pane with a full interactive Copilot CLI TUI — streaming output, tool calls, file I/O, all visible in real time.

```
┌──────────────────┬──────────────────┬──────────────────┐
│  🧠 ORCHESTRATOR │  🎨 FRONTEND     │  ⚙️  BACKEND     │
│  claude-opus-4.6 │  claude-sonnet   │  gpt-5.3-codex   │
├──────────────────┼──────────────────┼──────────────────┤
│  📋 PM           │  🔬 QA/TEST      │  🚀 DEVOPS       │
│  gpt-5.4         │  claude-sonnet   │  gpt-5.3-codex   │
└──────────────────┴──────────────────┴──────────────────┘
```

## How It Works

1. Type `team` in any terminal
2. Windows Terminal opens with **6 panes** — each a full Copilot CLI session
3. **Orchestrator** pane is focused — type your project task there
4. Orchestrator decomposes the task and routes subtasks to specialist agents
5. Agents communicate via a **file-based message bus** (inbox/outbox JSON files)
6. Every agent's work is visible live in its own TUI pane
7. You can type directly into any pane at any time

## Agents

| Agent | Model | Role |
|-------|-------|------|
| 🧠 Orchestrator | `claude-opus-4.6` | Decomposes tasks, routes work, synthesizes results |
| 🎨 Frontend | `claude-sonnet-4.6` | React/Vue/HTML/CSS/UI implementation |
| ⚙️ Backend | `gpt-5.3-codex` | APIs, databases, server logic |
| 📋 PM | `gpt-5.4` | Requirements, user stories, documentation |
| 🔬 QA/Test | `claude-sonnet-4.6` | Test cases, bug finding, quality review |
| 🚀 DevOps | `gpt-5.3-codex` | CI/CD, Docker, infrastructure, deployment |

Models are configurable in `config.json`.

## Prerequisites

- **Windows 10/11** with [Windows Terminal](https://aka.ms/terminal)
- **PowerShell 7+** ([Install](https://aka.ms/powershell))
- **GitHub Copilot CLI** ([Install](https://gh.io/copilot-cli))
- **GitHub CLI** authenticated (`gh auth login`)
- A GitHub Copilot subscription with model access

## Installation

```powershell
git clone https://github.com/kaplankerem/copilot-team.git
cd copilot-team
.\install.ps1
```

The installer:
- Copies files to `~/.copilot-team/`
- Adds the `team` function to your PowerShell profile
- Validates all prerequisites

Then open a **new terminal** and type:

```powershell
team
```

## Uninstallation

```powershell
cd copilot-team
.\uninstall.ps1
```

## Architecture

```
~/.copilot-team/
  config.json               ← model + color assignments per agent
  prompts/
    orchestrator.txt        ← role prompt for each agent
    frontend.txt
    backend.txt
    pm.txt
    qa.txt
    devops.txt
  scripts/
    launch-team.ps1         ← Windows Terminal launcher
  sessions/
    <session-id>/           ← created per session at runtime
      inbox/                ← task assignments (JSON)
      outbox/               ← completed results (JSON)
      prompt_*.txt          ← injected prompts per agent
      launch_*.ps1          ← per-agent launcher scripts
      launch.cmd            ← Windows Terminal layout command
      state.json            ← session metadata
```

### Communication Flow

```
User ──► Orchestrator ──► writes to agent inboxes
              ▲                     │
              │                     ▼
              └──── reads outboxes ◄── Agents complete work
```

1. **Orchestrator** receives the user's task in its interactive TUI
2. Decomposes the task and writes subtasks to each agent's `inbox/*.json`
3. Each agent **polls its inbox** using Copilot's built-in file tools
4. Agents execute the work (create files, write code, run commands)
5. Agents write results to their `outbox/*.json`
6. Orchestrator monitors outboxes, synthesizes, and reports back

All file reads/writes happen through Copilot's own tools — visible in each pane's TUI.

## Customization

### Change Models

Edit `config.json` to assign different models:

```json
{
  "agents": {
    "frontend": {
      "model": "gpt-5.4",
      "emoji": "🎨",
      "title": "FRONTEND",
      "tabColor": "#2563EB"
    }
  }
}
```

Available models (check `copilot --help` for the latest):
- `claude-opus-4.6`, `claude-sonnet-4.6`, `claude-haiku-4.5`
- `gpt-5.4`, `gpt-5.3-codex`, `gpt-5.2-codex`, `gpt-4.1`
- `gemini-3-pro-preview`

### Customize Agent Prompts

Edit files in `prompts/` to change agent behavior, expertise areas, or communication protocols. After editing, re-run `.\install.ps1 -Force` to update the installation.

### Add/Remove Agents

1. Add/remove entries in `config.json`
2. Add/remove prompt files in `prompts/`
3. Update the pane layout in `scripts/launch-team.ps1`
4. Re-run `.\install.ps1 -Force`

## How Each Pane Launches

Each agent pane runs:

```powershell
copilot --model <model> --allow-all-tools --allow-all-paths --no-ask-user -i "<role-prompt>"
```

- `-i` — starts the full interactive TUI and auto-executes the role prompt
- `--allow-all-tools` — agents can read/write files, run shell commands, search code
- `--allow-all-paths` — access to the shared session directory
- `--no-ask-user` — worker agents never ask questions; they communicate via files only

The Orchestrator omits `--no-ask-user` since it's the agent you interact with directly.

## Tips

- **Focus any pane** by clicking on it to give direct instructions to that agent
- **Scroll up** in any pane to see the full history of that agent's work
- **Session files** persist in `~/.copilot-team/sessions/` — you can review past sessions
- The Orchestrator sees all agent outputs and can re-assign work or request fixes

## License

MIT — see [LICENSE](LICENSE).
