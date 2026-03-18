import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import fs from "fs";
import path from "path";

const SESSION_DIR = process.env.TEAM_SESSION_DIR;
if (!SESSION_DIR) {
  console.error("TEAM_SESSION_DIR environment variable is required");
  process.exit(1);
}

const AGENTS = ["frontend", "backend", "pm", "qa", "devops"];

const server = new McpServer({
  name: "team-orchestrator",
  version: "1.0.0",
});

// --- delegate_task: Assign a task to a specific agent ---
server.tool(
  "delegate_task",
  "Assign a task to a team member agent. The agent will pick it up from their inbox and execute it autonomously. Use this instead of doing the work yourself.",
  {
    agent: z.enum(["frontend", "backend", "pm", "qa", "devops"]).describe("Which agent to assign the task to"),
    task: z.string().describe("Detailed description of what the agent should do. Be very specific — include file paths, API contracts, data schemas, tech stack choices, and all context needed."),
    context: z.string().describe("Additional context: project structure, dependencies on other agents, design decisions, etc."),
    priority: z.enum(["high", "medium", "low"]).default("medium").describe("Task priority"),
  },
  async ({ agent, task, context, priority }) => {
    const inboxFile = path.join(SESSION_DIR, "inbox", `${agent}.json`);
    const outboxFile = path.join(SESSION_DIR, "outbox", `${agent}.json`);
    const payload = {
      from: "orchestrator",
      task,
      context,
      priority,
      dependencies: [],
      output_path: outboxFile,
      assigned_at: new Date().toISOString(),
    };
    fs.writeFileSync(inboxFile, JSON.stringify(payload, null, 2), "utf8");
    // Clear previous outbox
    if (fs.existsSync(outboxFile)) {
      fs.writeFileSync(outboxFile, "", "utf8");
    }
    return {
      content: [{ type: "text", text: `✅ Task assigned to ${agent}. They will pick it up from their inbox shortly.` }],
    };
  }
);

// --- check_agent_status: Check a single agent's response ---
server.tool(
  "check_agent_status",
  "Check whether a specific agent has completed their assigned task by reading their outbox file.",
  {
    agent: z.enum(["frontend", "backend", "pm", "qa", "devops"]).describe("Which agent to check"),
  },
  async ({ agent }) => {
    const outboxFile = path.join(SESSION_DIR, "outbox", `${agent}.json`);
    if (!fs.existsSync(outboxFile)) {
      return { content: [{ type: "text", text: `⏳ ${agent}: No outbox file yet — agent has not responded.` }] };
    }
    const content = fs.readFileSync(outboxFile, "utf8").trim();
    if (!content || content === "{}") {
      return { content: [{ type: "text", text: `⏳ ${agent}: Still working — outbox is empty.` }] };
    }
    try {
      const data = JSON.parse(content);
      return { content: [{ type: "text", text: `${agent} [${data.status || "unknown"}]:\n${JSON.stringify(data, null, 2)}` }] };
    } catch {
      return { content: [{ type: "text", text: `${agent}: Raw response:\n${content}` }] };
    }
  }
);

// --- check_all_agents: Status overview of all agents ---
server.tool(
  "check_all_agents",
  "Get a status overview of all team agents. Shows who has responded and who is still working.",
  {},
  async () => {
    const results = [];
    for (const agent of AGENTS) {
      const inboxFile = path.join(SESSION_DIR, "inbox", `${agent}.json`);
      const outboxFile = path.join(SESSION_DIR, "outbox", `${agent}.json`);

      let inboxStatus = "empty";
      if (fs.existsSync(inboxFile)) {
        const ic = fs.readFileSync(inboxFile, "utf8").trim();
        if (ic && ic !== "{}") {
          try {
            const data = JSON.parse(ic);
            inboxStatus = data.command ? `command: ${data.command}` : "has task";
          } catch { inboxStatus = "has content"; }
        }
      }

      let outboxStatus = "no response";
      if (fs.existsSync(outboxFile)) {
        const oc = fs.readFileSync(outboxFile, "utf8").trim();
        if (oc && oc !== "{}") {
          try {
            const data = JSON.parse(oc);
            outboxStatus = data.status || "has response";
          } catch { outboxStatus = "has content"; }
        }
      }

      results.push(`${agent.padEnd(10)} | inbox: ${inboxStatus.padEnd(15)} | outbox: ${outboxStatus}`);
    }
    return { content: [{ type: "text", text: `Agent Status:\n${"—".repeat(60)}\n${results.join("\n")}` }] };
  }
);

// --- send_command: Send stop/cancel to an agent ---
server.tool(
  "send_command",
  "Send a control command (stop, cancel) to a specific agent or all agents.",
  {
    agent: z.enum(["frontend", "backend", "pm", "qa", "devops", "all"]).describe("Which agent to command, or 'all' for all agents"),
    command: z.enum(["stop", "cancel"]).describe("The command to send"),
    reason: z.string().optional().describe("Optional reason for the command"),
  },
  async ({ agent, command, reason }) => {
    const targets = agent === "all" ? AGENTS : [agent];
    const payload = { command, from: "orchestrator", reason: reason || "" };
    for (const t of targets) {
      const inboxFile = path.join(SESSION_DIR, "inbox", `${t}.json`);
      fs.writeFileSync(inboxFile, JSON.stringify(payload, null, 2), "utf8");
    }
    return {
      content: [{ type: "text", text: `📨 Sent "${command}" to: ${targets.join(", ")}` }],
    };
  }
);

// --- Start server ---
const transport = new StdioServerTransport();
await server.connect(transport);
