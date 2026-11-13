import Database from "better-sqlite3";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const dataDir = process.env.TRACKER_DATA_DIR || path.join(__dirname, "../../data");
const dbPath = process.env.TRACKER_DB_PATH || path.join(dataDir, "tracker.db");

fs.mkdirSync(dataDir, { recursive: true });

export const db = new Database(dbPath);

db.pragma("journal_mode = WAL");
db.pragma("foreign_keys = ON");

export function migrate() {
  db.exec(`
    CREATE TABLE IF NOT EXISTS projects (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      slug TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      description TEXT DEFAULT '',
      issue_counter INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS issues (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      number INTEGER NOT NULL,
      identifier TEXT NOT NULL UNIQUE,
      title TEXT NOT NULL,
      description TEXT DEFAULT '',
      state TEXT NOT NULL DEFAULT 'backlog',
      priority INTEGER DEFAULT 0,
      assignee TEXT,
      labels TEXT NOT NULL DEFAULT '[]',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE(project_id, number)
    );

    CREATE TABLE IF NOT EXISTS issue_comments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      issue_id INTEGER NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
      body TEXT NOT NULL,
      author TEXT DEFAULT 'human',
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS issue_blockers (
      issue_id INTEGER NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
      blocker_issue_id INTEGER NOT NULL REFERENCES issues(id) ON DELETE CASCADE,
      PRIMARY KEY (issue_id, blocker_issue_id),
      CHECK (issue_id != blocker_issue_id)
    );

    CREATE INDEX IF NOT EXISTS idx_issues_project_state ON issues(project_id, state);
    CREATE INDEX IF NOT EXISTS idx_issues_updated ON issues(updated_at);
    CREATE INDEX IF NOT EXISTS idx_issue_blockers_issue ON issue_blockers(issue_id);
  `);

  const row = db.prepare("SELECT id FROM projects WHERE slug = ?").get("comic");
  if (!row) {
    db.prepare(
      "INSERT INTO projects (slug, name, description) VALUES (?, ?, ?)",
    ).run(
      "comic",
      "ai-comic-drama",
      "分镜画布项目；Symphony 可轮询带 symphony 标签的 open / in_progress 工单",
    );
  }
}

export function parseLabels(raw) {
  try {
    const v = JSON.parse(raw || "[]");
    return Array.isArray(v) ? v.map(String) : [];
  } catch {
    return [];
  }
}

export function serializeLabels(labels) {
  return JSON.stringify(Array.isArray(labels) ? labels : []);
}

export function nextIssueNumber(projectId) {
  const tx = db.transaction((pid) => {
    const project = db.prepare("SELECT issue_counter FROM projects WHERE id = ?").get(pid);
    if (!project) throw new Error("project_not_found");
    const next = project.issue_counter + 1;
    db.prepare("UPDATE projects SET issue_counter = ? WHERE id = ?").run(next, pid);
    return next;
  });
  return tx(projectId);
}

export function branchNameForIssue(identifier, projectSlug) {
  const slug = String(projectSlug || "issue")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-");
  const ident = String(identifier || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-");
  return `${slug}/${ident}`;
}

export function loadBlockedByForIssues(issueIds) {
  const ids = [...new Set((issueIds || []).map((id) => String(id)))].filter(Boolean);
  if (ids.length === 0) return new Map();
  const placeholders = ids.map(() => "?").join(",");
  const rows = db
    .prepare(
      `SELECT b.issue_id, bi.id AS blocker_id, bi.identifier AS blocker_identifier, bi.state AS blocker_state
       FROM issue_blockers b
       JOIN issues bi ON bi.id = b.blocker_issue_id
       WHERE b.issue_id IN (${placeholders})`,
    )
    .all(...ids);
  const map = new Map();
  for (const row of rows) {
    const key = String(row.issue_id);
    if (!map.has(key)) map.set(key, []);
    map.get(key).push({
      id: String(row.blocker_id),
      identifier: row.blocker_identifier,
      state: row.blocker_state,
    });
  }
  return map;
}

export function replaceIssueBlockers(issueId, blockerIds) {
  const ids = [...new Set((blockerIds || []).map((id) => Number(id)))].filter(
    (id) => Number.isInteger(id) && id > 0 && id !== Number(issueId),
  );
  const tx = db.transaction((targetId, blockerList) => {
    db.prepare("DELETE FROM issue_blockers WHERE issue_id = ?").run(targetId);
    const insert = db.prepare(
      "INSERT INTO issue_blockers (issue_id, blocker_issue_id) VALUES (?, ?)",
    );
    for (const blockerId of blockerList) {
      insert.run(targetId, blockerId);
    }
  });
  tx(Number(issueId), ids);
}

export function rowToIssue(row, baseUrl, projectSlug) {
  if (!row) return null;
  const labels = parseLabels(row.labels);
  const slug = projectSlug || row.project_slug;
  return {
    id: String(row.id),
    project_id: row.project_id,
    project_slug: slug,
    number: row.number,
    identifier: row.identifier,
    title: row.title,
    description: row.description,
    state: row.state,
    priority: row.priority,
    assignee: row.assignee,
    assignee_id: row.assignee,
    labels,
    branch_name: branchNameForIssue(row.identifier, slug),
    url: `${baseUrl}/p/${slug}/issues/${row.number}`,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}
