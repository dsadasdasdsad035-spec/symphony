const base = "";

export async function fetchJson(path, options = {}) {
  const res = await fetch(`${base}${path}`, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(data?.error?.message || res.statusText || "请求失败");
  }
  return data;
}

export function getProjects() {
  return fetchJson("/api/v1/projects");
}

export function getIssues(slug) {
  return fetchJson(`/api/v1/projects/${slug}/issues`);
}

export function getIssue(id) {
  return fetchJson(`/api/v1/issues/${id}`);
}

export function createIssue(slug, payload) {
  return fetchJson(`/api/v1/projects/${slug}/issues`, {
    method: "POST",
    body: JSON.stringify(payload),
  });
}

export function updateIssue(id, payload) {
  return fetchJson(`/api/v1/issues/${id}`, {
    method: "PATCH",
    body: JSON.stringify(payload),
  });
}

export function addComment(id, body, author = "human") {
  return fetchJson(`/api/v1/issues/${id}/comments`, {
    method: "POST",
    body: JSON.stringify({ body, author }),
  });
}

export function getStates() {
  return fetchJson("/api/meta/states");
}
