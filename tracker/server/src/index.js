import Fastify from "fastify";
import cors from "@fastify/cors";
import { registerStatic } from "./static.js";
import {
  db,
  migrate,
  nextIssueNumber,
  parseLabels,
  rowToIssue,
  serializeLabels,
  loadBlockedByForIssues,
  replaceIssueBlockers,
} from "./db.js";

const PORT = Number(process.env.TRACKER_PORT || 4780);
const HOST = process.env.TRACKER_HOST || "127.0.0.1";
const PUBLIC_URL = process.env.TRACKER_PUBLIC_URL || `http://${HOST}:${PORT}`;
const API_TOKEN = process.env.TRACKER_API_TOKEN || "";

const ACTIVE_STATES = new Set(
  (process.env.TRACKER_ACTIVE_STATES || "backlog,todo,in_progress,in_review")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean),
);

const TERMINAL_STATES = new Set(
  (process.env.TRACKER_TERMINAL_STATES || "done,cancelled")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean),
);

migrate();

const app = Fastify({ logger: true });
await app.register(cors, { origin: true });

function authOptional(req, reply, done) {
  if (!API_TOKEN) return done();
  const h = req.headers.authorization || "";
  const token = h.startsWith("Bearer ") ? h.slice(7) : "";
  if (token !== API_TOKEN) {
    reply.code(401).send({ error: { message: "未授权" } });
    return;
  }
  done();
}

function requireAuth(req, reply, done) {
  if (!API_TOKEN) return done();
  authOptional(req, reply, done);
}

app.addHook("onRequest", (req, reply, done) => {
  if (req.method === "GET") return done();
  requireAuth(req, reply, done);
});

function getProject(slug) {
  return db.prepare("SELECT * FROM projects WHERE slug = ?").get(slug);
}

function listIssuesQuery(projectId, states) {
  let sql = `
    SELECT i.*, p.slug AS project_slug
    FROM issues i
    JOIN projects p ON p.id = i.project_id
    WHERE i.project_id = ?
  `;
  const params = [projectId];
  if (states?.length) {
    sql += ` AND i.state IN (${states.map(() => "?").join(",")})`;
    params.push(...states);
  }
  sql += " ORDER BY i.updated_at DESC";
  return { sql, params };
}

app.get("/api/health", async () => ({ ok: true, service: "symphony-tracker" }));

app.get("/api/v1/projects", async () => {
  const projects = db.prepare("SELECT id, slug, name, description, created_at FROM projects").all();
  return { projects };
});

app.post("/api/v1/projects", async (req, reply) => {
  const { slug, name, description = "" } = req.body || {};
  if (!slug || !name) {
    return reply.code(400).send({ error: { message: "slug 与 name 必填" } });
  }
  const info = db
    .prepare("INSERT INTO projects (slug, name, description) VALUES (?, ?, ?)")
    .run(String(slug).toLowerCase(), name, description);
  return { project: db.prepare("SELECT * FROM projects WHERE id = ?").get(info.lastInsertRowid) };
});

app.get("/api/v1/projects/:slug/issues", async (req, reply) => {
  const project = getProject(req.params.slug);
  if (!project) return reply.code(404).send({ error: { message: "项目不存在" } });
  const stateParam = req.query.state;
  const states = stateParam
    ? String(stateParam)
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean)
    : null;
  const { sql, params } = listIssuesQuery(project.id, states);
  const rows = db.prepare(sql).all(...params);
  const blockerMap = loadBlockedByForIssues(rows.map((r) => r.id));
  const issues = rows.map((r) => {
    const issue = rowToIssue(r, PUBLIC_URL, project.slug);
    return { ...issue, blocked_by: blockerMap.get(issue.id) || [] };
  });
  return { issues };
});

app.post("/api/v1/projects/:slug/issues", async (req, reply) => {
  const project = getProject(req.params.slug);
  if (!project) return reply.code(404).send({ error: { message: "项目不存在" } });
  const body = req.body || {};
  const title = String(body.title || "").trim();
  if (!title) return reply.code(400).send({ error: { message: "title 必填" } });
  const number = nextIssueNumber(project.id);
  const identifier = `${project.slug.toUpperCase()}-${number}`;
  const labels = serializeLabels(body.labels || []);
  const state = body.state || "backlog";
  const info = db
    .prepare(
      `INSERT INTO issues (project_id, number, identifier, title, description, state, priority, assignee, labels)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .run(
      project.id,
      number,
      identifier,
      title,
      body.description || "",
      state,
      body.priority ?? 0,
      body.assignee || null,
      labels,
    );
  const row = db
    .prepare(
      `SELECT i.*, p.slug AS project_slug FROM issues i JOIN projects p ON p.id = i.project_id WHERE i.id = ?`,
    )
    .get(info.lastInsertRowid);
  return { issue: rowToIssue(row, PUBLIC_URL, project.slug) };
});

app.get("/api/v1/issues/:id", async (req, reply) => {
  const row = db
    .prepare(
      `SELECT i.*, p.slug AS project_slug FROM issues i JOIN projects p ON p.id = i.project_id WHERE i.id = ?`,
    )
    .get(req.params.id);
  if (!row) return reply.code(404).send({ error: { message: "工单不存在" } });
  const comments = db
    .prepare("SELECT id, body, author, created_at FROM issue_comments WHERE issue_id = ? ORDER BY id")
    .all(row.id);
  const issue = rowToIssue(row, PUBLIC_URL, row.project_slug);
  const blockedBy = loadBlockedByForIssues([issue.id]).get(issue.id) || [];
  return { issue: { ...issue, blocked_by: blockedBy }, comments };
});

app.patch("/api/v1/issues/:id", async (req, reply) => {
  const row = db.prepare("SELECT * FROM issues WHERE id = ?").get(req.params.id);
  if (!row) return reply.code(404).send({ error: { message: "工单不存在" } });
  const body = req.body || {};
  const title = body.title !== undefined ? String(body.title) : row.title;
  const description = body.description !== undefined ? String(body.description) : row.description;
  const state = body.state !== undefined ? String(body.state) : row.state;
  const priority = body.priority !== undefined ? body.priority : row.priority;
  const assignee = body.assignee !== undefined ? body.assignee : row.assignee;
  const labels =
    body.labels !== undefined ? serializeLabels(body.labels) : row.labels;
  db.prepare(
    `UPDATE issues SET title=?, description=?, state=?, priority=?, assignee=?, labels=?, updated_at=datetime('now') WHERE id=?`,
  ).run(title, description, state, priority, assignee, labels, row.id);
  if (body.blocked_by_ids !== undefined) {
    const raw = Array.isArray(body.blocked_by_ids) ? body.blocked_by_ids : [];
    replaceIssueBlockers(row.id, raw);
  }
  const updated = db
    .prepare(
      `SELECT i.*, p.slug AS project_slug FROM issues i JOIN projects p ON p.id = i.project_id WHERE i.id = ?`,
    )
    .get(row.id);
  const issue = rowToIssue(updated, PUBLIC_URL, updated.project_slug);
  const blockedBy = loadBlockedByForIssues([issue.id]).get(issue.id) || [];
  return { issue: { ...issue, blocked_by: blockedBy } };
});

app.post("/api/v1/issues/:id/comments", async (req, reply) => {
  const row = db.prepare("SELECT id FROM issues WHERE id = ?").get(req.params.id);
  if (!row) return reply.code(404).send({ error: { message: "工单不存在" } });
  const body = String((req.body || {}).body || "").trim();
  if (!body) return reply.code(400).send({ error: { message: "body 必填" } });
  const author = (req.body || {}).author || "human";
  const info = db
    .prepare("INSERT INTO issue_comments (issue_id, body, author) VALUES (?, ?, ?)")
    .run(row.id, body, author);
  const comment = db.prepare("SELECT * FROM issue_comments WHERE id = ?").get(info.lastInsertRowid);
  return { comment };
});

/** Symphony issue_feed 兼容列表 */
app.get("/api/symphony/issues", async (req, reply) => {
  const projectSlug = req.query.project || "comic";
  const project = getProject(projectSlug);
  if (!project) return reply.code(404).send({ error: { message: "项目不存在" } });
  const wantStates = req.query.states
    ? String(req.query.states)
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean)
    : [...ACTIVE_STATES];
  const { sql, params } = listIssuesQuery(project.id, wantStates);
  let rows = db.prepare(sql).all(...params);
  const labelFilter = req.query.label || "symphony";
  if (labelFilter) {
    rows = rows.filter((r) => parseLabels(r.labels).map((l) => l.toLowerCase()).includes(labelFilter.toLowerCase()));
  }
  const blockerMap = loadBlockedByForIssues(rows.map((r) => r.id));
  const issues = rows.map((r) => {
    const issue = rowToIssue(r, PUBLIC_URL, project.slug);
    return {
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      description: issue.description,
      state: issue.state,
      url: issue.url,
      labels: issue.labels,
      assignee: issue.assignee,
      priority: issue.priority,
      branch_name: issue.branch_name,
      created_at: issue.created_at,
      updated_at: issue.updated_at,
      blocked_by: blockerMap.get(issue.id) || [],
    };
  });
  return { issues };
});

app.post("/api/symphony/issues/batch", async (req) => {
  const ids = (req.body || {}).ids || [];
  if (!Array.isArray(ids) || ids.length === 0) return { issues: [] };
  const placeholders = ids.map(() => "?").join(",");
  const rows = db
    .prepare(
      `SELECT i.*, p.slug AS project_slug FROM issues i JOIN projects p ON p.id = i.project_id WHERE i.id IN (${placeholders})`,
    )
    .all(...ids.map(String));
  const blockerMap = loadBlockedByForIssues(rows.map((r) => r.id));
  const issues = rows.map((r) => {
    const issue = rowToIssue(r, PUBLIC_URL, r.project_slug);
    return {
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      description: issue.description,
      state: issue.state,
      url: issue.url,
      labels: issue.labels,
      assignee: issue.assignee,
      priority: issue.priority,
      branch_name: issue.branch_name,
      created_at: issue.created_at,
      updated_at: issue.updated_at,
      blocked_by: blockerMap.get(issue.id) || [],
    };
  });
  return { issues };
});

app.get("/api/meta/states", async () => ({
  active: [...ACTIVE_STATES],
  terminal: [...TERMINAL_STATES],
  all: ["backlog", "todo", "in_progress", "in_review", "done", "cancelled"],
}));

await registerStatic(app);

await app.listen({ port: PORT, host: HOST });
console.log(`Symphony Tracker API http://${HOST}:${PORT}`);
