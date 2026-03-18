import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import fs from "fs";
import path from "path";
import { spawn, execSync } from "child_process";

const SESSION_DIR = process.env.TEAM_SESSION_DIR;
const CONFIG_FILE = process.env.TEAM_CONFIG_FILE;
const PROMPTS_DIR = process.env.TEAM_PROMPTS_DIR;
const PATH_FLAGS  = process.env.TEAM_PATH_FLAGS || "--allow-all-paths";

if (!SESSION_DIR || !CONFIG_FILE || !PROMPTS_DIR) {
  console.error("Required env vars: TEAM_SESSION_DIR, TEAM_CONFIG_FILE, TEAM_PROMPTS_DIR");
  process.exit(1);
}

// Resolve copilot's Node.js entry point (avoids shell:true + cmd.exe arg mangling)
function resolveCopilotLoader() {
  try {
    const copilotPath = execSync("where copilot", { encoding: "utf8" }).trim().split("\n")[0].trim();
    const npmDir = path.dirname(copilotPath);
    const loaderJs = path.join(npmDir, "node_modules", "@github", "copilot", "npm-loader.js");
    if (fs.existsSync(loaderJs)) return loaderJs;
  } catch {}
  // Fallback: standard npm global path
  const fallback = path.join(process.env.APPDATA, "npm", "node_modules", "@github", "copilot", "npm-loader.js");
  if (fs.existsSync(fallback)) return fallback;
  throw new Error("Cannot find copilot npm-loader.js. Is copilot CLI installed globally?");
}

const COPILOT_LOADER = resolveCopilotLoader();
const config = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
const AGENTS = ["frontend", "backend", "pm", "qa", "devops"];

// Track running agent processes
const agentProcesses = new Map();

const server = new McpServer({
  name: "team-orchestrator",
  version: "2.0.0",
});

function getAgentModel(agent) {
  return config.agents[agent]?.model || "claude-sonnet-4.6";
}

function buildPromptFile(agent, task, context) {
  // Read role prompt and inject session dir
  let rolePrompt = fs.readFileSync(path.join(PROMPTS_DIR, `${agent}.txt`), "utf8");
  rolePrompt = rolePrompt.replaceAll("{SESSION}", SESSION_DIR);

  const outboxFile = path.join(SESSION_DIR, "outbox", `${agent}.json`);
  const fullPrompt = `${rolePrompt}

## YOUR CURRENT TASK
${task}

## CONTEXT
${context}

## OUTPUT INSTRUCTIONS
When you have completed the task, write your results as JSON to this file:
${outboxFile}

Use Set-Content (PowerShell) or write_file to write JSON to that path.
The JSON must follow the format specified in your role prompt above.
After writing your results, you are DONE.`;

  const promptFile = path.join(SESSION_DIR, `active_${agent}.txt`);
  fs.writeFileSync(promptFile, fullPrompt, "utf8");
  return promptFile;
}

function launchAgent(agent, promptFile) {
  const model = getAgentModel(agent);
  const outboxFile = path.join(SESSION_DIR, "outbox", `${agent}.json`);

  // Clear previous outbox
  fs.writeFileSync(outboxFile, "", "utf8");

  // Kill existing process if running
  if (agentProcesses.has(agent)) {
    const old = agentProcesses.get(agent);
    try { old.process.kill(); } catch {}
    agentProcesses.delete(agent);
  }

  // Use node + npm-loader.js directly (shell:true + cmd.exe mangles args on Windows)
  const args = [
    COPILOT_LOADER,
    "--model", model,
    "--allow-all-tools",
    ...PATH_FLAGS.split(" ").filter(Boolean),
    "--no-ask-user",
    "-i", `Read the file at '${promptFile}' and execute ALL instructions in it. Start by reading the file now.`,
  ];

  const logFile = path.join(SESSION_DIR, `log_${agent}.txt`);

  const child = spawn("node", args, {
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env },
  });

  // Capture stdout/stderr to log file and memory
  const logStream = fs.createWriteStream(logFile, { flags: "w" });
  let capturedOutput = "";

  child.stdout.on("data", (data) => {
    const text = data.toString();
    capturedOutput += text;
    logStream.write(text);
  });
  child.stderr.on("data", (data) => {
    const text = data.toString();
    capturedOutput += text;
    logStream.write("[stderr] " + text);
  });

  const info = {
    process: child,
    pid: child.pid,
    model,
    startedAt: new Date().toISOString(),
    status: "running",
    logFile,
    getOutput: () => capturedOutput,
  };

  child.on("exit", (code) => {
    info.status = code === 0 ? "completed" : `exited (code ${code})`;
    info.endedAt = new Date().toISOString();
    logStream.end();
  });

  child.on("error", (err) => {
    info.status = `error: ${err.message}`;
    logStream.end();
  });

  agentProcesses.set(agent, info);
  return info;
}

// --- delegate_task ---
server.tool(
  "delegate_task",
  "Assign a task to a team member agent. Launches a background copilot process with the agent's configured model. The agent works autonomously and writes results to its outbox.",
  {
    agent: z.enum(["frontend", "backend", "pm", "qa", "devops"]).describe("Which agent to assign the task to"),
    task: z.string().describe("Detailed description of what the agent should do. Be very specific — include file paths, API contracts, data schemas, tech stack choices, and all context needed."),
    context: z.string().describe("Additional context: project structure, dependencies on other agents, design decisions, etc."),
    priority: z.enum(["high", "medium", "low"]).default("medium").describe("Task priority"),
  },
  async ({ agent, task, context, priority }) => {
    const promptFile = buildPromptFile(agent, task, context);
    const info = launchAgent(agent, promptFile);
    return {
      content: [{ type: "text", text: `✅ ${agent} agent launched (model: ${info.model}, PID: ${info.pid}). Working in background.` }],
    };
  }
);

// --- check_agent_status ---
server.tool(
  "check_agent_status",
  "Check whether a specific agent has completed their task. Shows process status and outbox contents.",
  {
    agent: z.enum(["frontend", "backend", "pm", "qa", "devops"]).describe("Which agent to check"),
  },
  async ({ agent }) => {
    const outboxFile = path.join(SESSION_DIR, "outbox", `${agent}.json`);
    const info = agentProcesses.get(agent);
    const processStatus = info ? `${info.status} (model: ${info.model}, started: ${info.startedAt})` : "not started";

    let outboxContent = "";
    if (fs.existsSync(outboxFile)) {
      outboxContent = fs.readFileSync(outboxFile, "utf8").trim();
    }

    // Include recent captured output for visibility
    const recentOutput = info?.getOutput ? info.getOutput().slice(-500) : "";

    if (outboxContent && outboxContent !== "{}" && outboxContent.length > 2) {
      try {
        const data = JSON.parse(outboxContent);
        return { content: [{ type: "text", text: `${agent} — process: ${processStatus}\nResult:\n${JSON.stringify(data, null, 2)}` }] };
      } catch {
        return { content: [{ type: "text", text: `${agent} — process: ${processStatus}\nRaw output:\n${outboxContent}` }] };
      }
    }

    const logHint = recentOutput ? `\nRecent activity:\n${recentOutput}` : "";
    return { content: [{ type: "text", text: `⏳ ${agent} — process: ${processStatus} — no results yet.${logHint}` }] };
  }
);

// --- check_all_agents ---
server.tool(
  "check_all_agents",
  "Get a status overview of all team agents. Shows process state and whether results are available.",
  {},
  async () => {
    const lines = [];
    for (const agent of AGENTS) {
      const info = agentProcesses.get(agent);
      const outboxFile = path.join(SESSION_DIR, "outbox", `${agent}.json`);

      let processStr = "idle";
      if (info) {
        processStr = `${info.status} [${info.model}]`;
      }

      let resultStr = "—";
      if (fs.existsSync(outboxFile)) {
        const oc = fs.readFileSync(outboxFile, "utf8").trim();
        if (oc && oc !== "{}" && oc.length > 2) {
          try {
            const data = JSON.parse(oc);
            resultStr = data.status || "has output";
          } catch { resultStr = "has output"; }
        }
      }

      lines.push(`${agent.padEnd(10)} | process: ${processStr.padEnd(30)} | result: ${resultStr}`);
    }
    return { content: [{ type: "text", text: `Agent Status:\n${"—".repeat(70)}\n${lines.join("\n")}` }] };
  }
);

// --- send_command ---
server.tool(
  "send_command",
  "Stop a running agent process. Kills the background copilot process.",
  {
    agent: z.enum(["frontend", "backend", "pm", "qa", "devops", "all"]).describe("Which agent to stop, or 'all'"),
    command: z.enum(["stop", "cancel"]).describe("The command to send"),
    reason: z.string().optional().describe("Optional reason"),
  },
  async ({ agent, command, reason }) => {
    const targets = agent === "all" ? AGENTS : [agent];
    const results = [];
    for (const t of targets) {
      const info = agentProcesses.get(t);
      if (info && info.status === "running") {
        try { info.process.kill(); } catch {}
        info.status = `${command}ed`;
        results.push(`${t}: stopped`);
      } else {
        results.push(`${t}: not running`);
      }
    }
    return { content: [{ type: "text", text: results.join("\n") }] };
  }
);

// --- Start server ---
const transport = new StdioServerTransport();
await server.connect(transport);
