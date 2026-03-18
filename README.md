# 🧠 KK-Orchestrator

**Multi-agent AI team orchestration for GitHub Copilot CLI.**

Launch a full software development team of AI agents with a single command. You interact with a single **Orchestrator** TUI — it delegates to specialist agents running as background processes, each using its own AI model.

```
You ──► 🧠 Orchestrator (claude-opus-4.6, interactive)
              │
              ├── delegate_task ──► 📋 PM (gpt-5.4)          plans & breaks down work
              ├── delegate_task ──► 🎨 Frontend (sonnet-4.6)  UI implementation
              ├── delegate_task ──► ⚙️  Backend (codex)       APIs & server logic
              ├── delegate_task ──► 🔬 QA (sonnet-4.6)        tests & quality
              └── delegate_task ──► 🚀 DevOps (codex)         CI/CD & infra
```

## How It Works

1. Type `team` in any terminal
2. A single **Orchestrator** TUI opens — type your project task there
3. Orchestrator sends the request to the **PM agent** for planning and task breakdown
4. PM produces a structured plan; Orchestrator delegates each task to the right agents
5. Agents run as **background processes** (each with its own model), write results to outbox files
6. Orchestrator monitors agent progress and reports back to you when done

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

- **Windows 10/11**
- **PowerShell 7+** ([Install](https://aka.ms/powershell))
- **GitHub Copilot CLI** installed globally via npm (`npm install -g @github/copilot`)
- **GitHub CLI** authenticated (`gh auth login`)
- **Node.js 18+**
- A GitHub Copilot subscription with model access

## Installation

```powershell
git clone https://github.com/kaplankerem/copilot-team.git
cd copilot-team
.\install.ps1
```

The installer:
- Copies files to `~/.copilot-team/`
- Runs `npm install` in the MCP server directory
- Adds the `team` and `team-clean` functions to your PowerShell profile
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
    orchestrator.txt        ← orchestrator role prompt
    frontend.txt            ← agent role prompts
    backend.txt
    pm.txt
    qa.txt
    devops.txt
  scripts/
    launch-team.ps1         ← session launcher
  mcp-server/
    server.js               ← MCP server (agent process manager)
    package.json
  sessions/
    <session-id>/           ← created per session at runtime
      inbox/                ← (reserved for future use)
      outbox/               ← agent results (JSON)
      active_<agent>.txt    ← injected prompt per agent
      log_<agent>.txt       ← agent stdout/stderr capture
      mcp-config.json       ← generated MCP config for this session
      state.json            ← session metadata
```

### Communication Flow

```
User ──► Orchestrator TUI
              │
              │ delegate_task (MCP tool)
              ▼
         MCP Server (server.js)
              │
              │ spawns: node npm-loader.js --model <model> --no-ask-user -i "..."
              ▼
         Agent Process (headless)
              │ reads active_<agent>.txt for full instructions
              │ executes task (writes code, runs commands, etc.)
              ▼
         outbox/<agent>.json  ◄── Orchestrator polls via check_agent_status
```

1. **Orchestrator** receives user request, immediately delegates to **PM** via `delegate_task`
2. **PM** produces a task breakdown with assignments, acceptance criteria, and dependency order
3. **Orchestrator** reads PM's plan and calls `delegate_task` for each technical agent
4. Each **agent** runs as a child `node` process, reads its prompt file, executes the work
5. Agents write JSON results to their `outbox/` file
6. **Orchestrator** polls via `check_agent_status` / `check_all_agents` and reports to you

Agent processes are captured (stdout + stderr → `log_<agent>.txt`) so you can always check what happened if an agent fails.

### MCP Tools

The MCP server exposes 4 tools to the Orchestrator:

| Tool | Description |
|------|-------------|
| `delegate_task` | Launch an agent process with a task + context |
| `check_agent_status` | Check one agent's process status + results + recent output |
| `check_all_agents` | Overview of all agents at once |
| `send_command` | Stop or cancel a running agent |

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
3. Update the `AGENTS` array in `mcp-server/server.js`
4. Re-run `.\install.ps1 -Force`

## Session Management

Sessions are stored in `~/.copilot-team/sessions/`. Each run creates a new session directory.

```powershell
# Clean up sessions older than 7 days (also runs automatically on each `team` launch)
team-clean

# Clean up sessions older than 3 days
team-clean -Days 3
```

## How Agents Are Launched

Each agent runs as a headless Node.js process:

```
node <npm-loader.js> --model <model> --allow-all-tools --allow-all-paths --no-ask-user -i "Read the file at '...'"
```

- `npm-loader.js` — the Copilot CLI entry point (resolved automatically; avoids Windows cmd.exe arg mangling)
- `--allow-all-tools` — agents can read/write files, run shell commands, search code
- `--no-ask-user` — agents never ask questions; they write results to their outbox file
- `-i` — non-interactive mode, starts with a one-line instruction to read the full prompt file

Agent stdout/stderr is captured to `log_<agent>.txt` in the session directory for debugging.

## Agent Control Commands

Type these into the **Orchestrator** at any time:

| Command | Effect |
|---------|--------|
| `stop all` / `halt` / `abort` | Kills all running agent processes |
| `stop frontend` | Kills a specific agent process |
| `status` | Shows process status + results for all agents |

## Tips

- **Session logs** — if an agent fails, check `log_<agent>.txt` in the session directory for the full output
- **Retry** — just re-send the same task; the orchestrator will re-launch the agent
- **Session files** persist in `~/.copilot-team/sessions/` — review past work any time
- **Path access** — on launch you choose between full filesystem access or session-scoped access

## License

MIT — see [LICENSE](LICENSE).
