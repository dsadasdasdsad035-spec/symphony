import { useCallback, useEffect, useMemo, useState } from "react";
import { useMobileLayout } from "./hooks/useMediaQuery.js";
import {
  addComment,
  createIssue,
  getIssue,
  getIssues,
  getProjects,
  getStates,
  updateIssue,
} from "./api.js";

const STATE_LABELS = {
  backlog: "待梳理",
  todo: "待办",
  in_progress: "进行中",
  in_review: "评审中",
  done: "已完成",
  cancelled: "已取消",
};

function labelsFromInput(text) {
  return text
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

function labelsToInput(labels) {
  return (labels || []).join(", ");
}

function blockedByIds(issue) {
  return (issue?.blocked_by || []).map((b) => String(b.id));
}

function IssueCard({
  issue,
  dragIssueId,
  dropTargetId,
  linkBlockerFromId,
  isMobile,
  onOpen,
  onHandleActivate,
  onDragStart,
  onDragEnd,
  onDragEnter,
  onDragLeave,
  onDragOver,
  onDrop,
}) {
  const id = String(issue.id);
  const isDragging = dragIssueId === id;
  const isDropTarget = dropTargetId === id && dragIssueId && dragIssueId !== id;
  const isLinkSource = linkBlockerFromId === id;
  const isLinkTarget =
    linkBlockerFromId && linkBlockerFromId !== id && Boolean(linkBlockerFromId);
  const blockedCount = issue.blocked_by?.length || 0;

  return (
    <article
      className={`card ${isDropTarget ? "card-drop-target" : ""} ${isDragging ? "card-dragging" : ""} ${isLinkSource ? "card-link-source" : ""} ${isLinkTarget ? "card-link-target" : ""}`}
      onDragOver={onDragOver}
      onDragEnter={() => onDragEnter(issue.id)}
      onDragLeave={(e) => {
        if (e.currentTarget.contains(e.relatedTarget)) return;
        onDragLeave();
      }}
      onDrop={(e) => onDrop(e, issue.id)}
    >
      <div className="card-header">
        <span className="card-id">{issue.identifier}</span>
        <button
          type="button"
          className="card-handle"
          title={isMobile ? "点选后点另一张卡片：本工单阻塞对方" : "拖到另一张卡片：本工单阻塞对方"}
          aria-label={`设置 ${issue.identifier} 的阻塞关系`}
          draggable={!isMobile}
          onDragStart={(e) => !isMobile && onDragStart(e, issue.id)}
          onDragEnd={onDragEnd}
          onClick={(e) => {
            e.stopPropagation();
            onHandleActivate(issue.id);
          }}
        >
          <span className="card-handle-icon" aria-hidden="true">
            ⋮⋮
          </span>
        </button>
      </div>
      <div
        className="card-body"
        onClick={() => onOpen(issue)}
        onKeyDown={(ev) => ev.key === "Enter" && onOpen(issue)}
        role="button"
        tabIndex={0}
      >
        <div className="card-title">{issue.title}</div>
        {issue.labels?.length || blockedCount > 0 ? (
          <div className="card-footer">
            {issue.labels?.length ? (
              <div className="card-labels">
                {issue.labels.map((l) => (
                  <span
                    key={l}
                    className={`tag ${l.toLowerCase() === "symphony" ? "tag--symphony" : ""}`}
                  >
                    {l}
                  </span>
                ))}
              </div>
            ) : null}
            {blockedCount > 0 ? (
              <span className="card-blocked" title="未完成的前置工单会阻塞 Symphony 派发">
                阻塞 {issue.blocked_by.map((b) => b.identifier).join(", ")}
              </span>
            ) : null}
          </div>
        ) : null}
      </div>
    </article>
  );
}

export default function App() {
  const [projects, setProjects] = useState([]);
  const [projectSlug, setProjectSlug] = useState("comic");
  const [issues, setIssues] = useState([]);
  const [states, setStates] = useState([]);
  const [error, setError] = useState("");
  const [selected, setSelected] = useState(null);
  const [detail, setDetail] = useState(null);
  const [commentText, setCommentText] = useState("");
  const [creating, setCreating] = useState(false);
  const [newIssue, setNewIssue] = useState({
    title: "",
    description: "",
    labels: "symphony",
    state: "backlog",
  });
  const [dragIssueId, setDragIssueId] = useState(null);
  const [dropTargetId, setDropTargetId] = useState(null);
  const [linkBlockerFromId, setLinkBlockerFromId] = useState(null);
  const isMobile = useMobileLayout();

  const loadBoard = useCallback(async () => {
    setError("");
    try {
      const [{ issues: list }, { all }] = await Promise.all([
        getIssues(projectSlug),
        getStates(),
      ]);
      setIssues(list);
      setStates(all);
    } catch (e) {
      setError(e.message);
    }
  }, [projectSlug]);

  useEffect(() => {
    getProjects()
      .then(({ projects: ps }) => {
        setProjects(ps);
        if (ps.length && !ps.find((p) => p.slug === projectSlug)) {
          setProjectSlug(ps[0].slug);
        }
      })
      .catch((e) => setError(e.message));
  }, [projectSlug]);

  useEffect(() => {
    loadBoard();
  }, [loadBoard]);

  const columns = useMemo(() => {
    const map = Object.fromEntries(states.map((s) => [s, []]));
    for (const issue of issues) {
      if (!map[issue.state]) map[issue.state] = [];
      map[issue.state].push(issue);
    }
    return states.map((state) => ({ state, items: map[state] || [] }));
  }, [issues, states]);

  const currentProject = projects.find((p) => p.slug === projectSlug);

  async function openIssue(issue) {
    setSelected(issue);
    setCommentText("");
    try {
      const data = await getIssue(issue.id);
      setDetail(data);
    } catch (e) {
      setError(e.message);
    }
  }

  function closeModal() {
    setSelected(null);
    setDetail(null);
  }

  async function saveDetail(patch) {
    if (!selected) return;
    try {
      await updateIssue(selected.id, patch);
      await loadBoard();
      const data = await getIssue(selected.id);
      setDetail(data);
      setSelected(data.issue);
    } catch (e) {
      setError(e.message);
    }
  }

  async function submitComment() {
    if (!selected || !commentText.trim()) return;
    try {
      await addComment(selected.id, commentText.trim());
      setCommentText("");
      const data = await getIssue(selected.id);
      setDetail(data);
    } catch (e) {
      setError(e.message);
    }
  }

  function handleBlockerDragStart(e, issueId) {
    e.dataTransfer.setData("application/x-tracker-issue-id", String(issueId));
    e.dataTransfer.effectAllowed = "link";
    setDragIssueId(String(issueId));
    setDropTargetId(null);
  }

  function handleBlockerDragEnd() {
    setDragIssueId(null);
    setDropTargetId(null);
  }

  function handleBlockerDragOver(e) {
    if (dragIssueId) e.preventDefault();
  }

  async function addBlockerRelation(blockedIssueId, blockerIssueId) {
    const blockedId = String(blockedIssueId);
    const blockerId = String(blockerIssueId);
    if (blockedId === blockerId) return;

    const blocked = issues.find((i) => String(i.id) === blockedId);
    if (!blocked) return;
    const ids = blockedByIds(blocked);
    if (ids.includes(blockerId)) return;

    setError("");
    try {
      await updateIssue(blockedId, { blocked_by_ids: [...ids, blockerId] });
      await loadBoard();
    } catch (err) {
      setError(err.message);
    }
  }

  async function handleBlockerDrop(e, targetIssueId) {
    e.preventDefault();
    const blockerId =
      e.dataTransfer.getData("application/x-tracker-issue-id") || dragIssueId;
    handleBlockerDragEnd();
    if (!blockerId) return;
    await addBlockerRelation(targetIssueId, blockerId);
  }

  function handleHandleActivate(issueId) {
    const id = String(issueId);
    if (isMobile) {
      setLinkBlockerFromId((prev) => (prev === id ? null : id));
      return;
    }
  }

  function handleCardOpen(issue) {
    const targetId = String(issue.id);
    if (linkBlockerFromId && linkBlockerFromId !== targetId) {
      addBlockerRelation(targetId, linkBlockerFromId).then(() => setLinkBlockerFromId(null));
      return;
    }
    if (linkBlockerFromId) {
      setLinkBlockerFromId(null);
      return;
    }
    openIssue(issue);
  }

  const linkSourceIssue = useMemo(
    () => issues.find((i) => String(i.id) === linkBlockerFromId),
    [issues, linkBlockerFromId],
  );

  const boardStats = useMemo(() => {
    const total = issues.length;
    const symphony = issues.filter((i) =>
      (i.labels || []).some((l) => String(l).toLowerCase() === "symphony"),
    ).length;
    const active = issues.filter((i) => !["done", "cancelled"].includes(i.state)).length;
    return { total, symphony, active };
  }, [issues]);

  async function removeBlocker(blockerId) {
    if (!issue) return;
    const ids = blockedByIds(issue).filter((id) => id !== String(blockerId));
    await saveDetail({ blocked_by_ids: ids });
  }

  async function submitNewIssue(e) {
    e.preventDefault();
    if (!newIssue.title.trim()) return;
    try {
      await createIssue(projectSlug, {
        title: newIssue.title.trim(),
        description: newIssue.description,
        state: newIssue.state,
        labels: labelsFromInput(newIssue.labels),
      });
      setCreating(false);
      setNewIssue({ title: "", description: "", labels: "symphony", state: "backlog" });
      await loadBoard();
    } catch (err) {
      setError(err.message);
    }
  }

  const issue = detail?.issue;

  return (
    <div className={`app ${isMobile ? "app-mobile" : ""}`}>
      <aside className="sidebar" aria-hidden={isMobile}>
        <div className="logo">
          <span className="logo-dot" />
          Symphony Tracker
        </div>
        <p className="sidebar-tagline">本地工单看板，供 Symphony issue_feed 轮询派发。</p>
        <nav className="project-list">
          <h3>项目</h3>
          {projects.map((p) => (
            <button
              key={p.slug}
              type="button"
              className={`project-btn ${p.slug === projectSlug ? "active" : ""}`}
              data-initial={(p.name || p.slug).slice(0, 1).toUpperCase()}
              onClick={() => setProjectSlug(p.slug)}
            >
              <span className="project-btn-label">{p.name}</span>
            </button>
          ))}
        </nav>
        <p className="sidebar-foot">带 <strong>symphony</strong> 标签的待办类工单会被编排器拉取。</p>
      </aside>

      <main className="main">
        <header className="toolbar">
          <div className="toolbar-row">
            <div className="toolbar-title">
              <h1>{currentProject?.name || projectSlug}</h1>
              <p className="toolbar-subtitle">
                项目 <strong>{projectSlug}</strong> · {boardStats.active} 个进行中
              </p>
            </div>
            <div className="toolbar-actions">
              <button
                type="button"
                className="btn btn-ghost btn-icon"
                onClick={loadBoard}
                title="刷新看板"
                aria-label="刷新看板"
              >
                ↻
              </button>
              <button
                type="button"
                className="btn btn-primary"
                onClick={() => setCreating(true)}
              >
                新建工单
              </button>
            </div>
          </div>
          {projects.length > 0 ? (
            <label className="topbar-project-select-wrap">
              <span className="visually-hidden">切换项目</span>
              <select
                className="topbar-project-select"
                value={projectSlug}
                onChange={(e) => setProjectSlug(e.target.value)}
                aria-label="切换项目"
              >
                {projects.map((p) => (
                  <option key={p.slug} value={p.slug}>
                    {p.name}
                  </option>
                ))}
              </select>
            </label>
          ) : null}
          <div className="stats-row">
            <span className="stat-chip">
              全部 <strong>{boardStats.total}</strong>
            </span>
            <span className="stat-chip stat-chip--accent">
              symphony <strong>{boardStats.symphony}</strong>
            </span>
          </div>
          {!linkBlockerFromId ? (
            <details className="help-panel">
              <summary>阻塞关系怎么设？</summary>
              <div className="help-panel-body">
                {isMobile
                  ? "点卡片右上角 ⋮⋮，再点另一张工单：前者阻塞后者。待办中被阻塞时 Symphony 不会派发。"
                  : "拖动卡片右上角 ⋮⋮ 到另一张工单：前者阻塞后者。待办中被阻塞时 Symphony 不会派发。"}
              </div>
            </details>
          ) : null}
        </header>

        {error ? <div className="error">{error}</div> : null}

        {linkBlockerFromId ? (
          <div className="link-banner" role="status">
            <span>
              已选阻塞工单 <strong>{linkSourceIssue?.identifier || linkBlockerFromId}</strong>
              ，点另一张卡片设为被阻塞
            </span>
            <button type="button" className="btn btn-small" onClick={() => setLinkBlockerFromId(null)}>
              取消
            </button>
          </div>
        ) : null}

        <div className={`board-scroll ${isMobile ? "board-scroll-mobile" : ""}`}>
          <div className="board">
            {columns.map(({ state, items }) => (
              <section key={state} className="column" data-state={state}>
                <div className="column-head">
                  <div className="column-title">
                    <span className="state-dot" aria-hidden="true" />
                    <span>{STATE_LABELS[state] || state}</span>
                  </div>
                  <span className="column-count">{items.length}</span>
                </div>
                <div className="column-cards">
                  {items.length === 0 ? (
                    <div className="empty">暂无</div>
                  ) : (
                    items.map((it) => (
                      <IssueCard
                        key={it.id}
                        issue={it}
                        dragIssueId={dragIssueId}
                        dropTargetId={dropTargetId}
                        linkBlockerFromId={linkBlockerFromId}
                        isMobile={isMobile}
                        onOpen={handleCardOpen}
                        onHandleActivate={handleHandleActivate}
                        onDragStart={handleBlockerDragStart}
                        onDragEnd={handleBlockerDragEnd}
                        onDragEnter={(id) => setDropTargetId(String(id))}
                        onDragLeave={() => setDropTargetId(null)}
                        onDragOver={handleBlockerDragOver}
                        onDrop={handleBlockerDrop}
                      />
                    ))
                  )}
                </div>
              </section>
            ))}
          </div>
        </div>
      </main>

      {isMobile ? (
        <button
          type="button"
          className="fab"
          onClick={() => setCreating(true)}
          aria-label="新建工单"
        >
          +
        </button>
      ) : null}

      {creating ? (
        <div className="overlay" onClick={() => setCreating(false)} role="presentation">
          <form className="modal" onClick={(e) => e.stopPropagation()} onSubmit={submitNewIssue}>
            <div className="modal-header">
              <div className="modal-header-text">
                <h2>新建工单</h2>
                <p className="modal-meta">创建后出现在所选状态列</p>
              </div>
              <button
                type="button"
                className="btn btn-ghost btn-icon"
                onClick={() => setCreating(false)}
                aria-label="关闭"
              >
                ×
              </button>
            </div>
            <div className="modal-body">
            <div className="field">
              <label htmlFor="new-title">标题</label>
              <input
                id="new-title"
                value={newIssue.title}
                onChange={(e) => setNewIssue((n) => ({ ...n, title: e.target.value }))}
                autoFocus
              />
            </div>
            <div className="field">
              <label htmlFor="new-desc">描述</label>
              <textarea
                id="new-desc"
                value={newIssue.description}
                onChange={(e) => setNewIssue((n) => ({ ...n, description: e.target.value }))}
              />
            </div>
            <div className="field">
              <label htmlFor="new-labels">标签（逗号分隔）</label>
              <input
                id="new-labels"
                value={newIssue.labels}
                onChange={(e) => setNewIssue((n) => ({ ...n, labels: e.target.value }))}
              />
            </div>
            <div className="field">
              <label htmlFor="new-state">状态</label>
              <select
                id="new-state"
                value={newIssue.state}
                onChange={(e) => setNewIssue((n) => ({ ...n, state: e.target.value }))}
              >
                {states.map((s) => (
                  <option key={s} value={s}>
                    {STATE_LABELS[s] || s}
                  </option>
                ))}
              </select>
            </div>
            <div className="modal-footer">
              <button type="button" className="btn" onClick={() => setCreating(false)}>
                取消
              </button>
              <button type="submit" className="btn btn-primary">
                创建
              </button>
            </div>
            </div>
          </form>
        </div>
      ) : null}

      {selected && issue ? (
        <div className="overlay" onClick={closeModal} role="presentation">
          <div className="modal" onClick={(e) => e.stopPropagation()} role="dialog">
            <div className="modal-header">
              <div className="modal-header-text">
                <h2>{issue.title}</h2>
                <p className="modal-meta">{issue.identifier}</p>
              </div>
              <button
                type="button"
                className="btn btn-ghost btn-icon"
                onClick={closeModal}
                aria-label="关闭"
              >
                ×
              </button>
            </div>
            <div className="modal-body">
            <div className="field">
              <label htmlFor="edit-title">标题</label>
              <input
                id="edit-title"
                defaultValue={issue.title}
                onBlur={(e) => {
                  if (e.target.value !== issue.title) saveDetail({ title: e.target.value });
                }}
              />
            </div>
            <div className="field">
              <label htmlFor="edit-desc">描述</label>
              <textarea
                id="edit-desc"
                defaultValue={issue.description}
                onBlur={(e) => {
                  if (e.target.value !== issue.description) {
                    saveDetail({ description: e.target.value });
                  }
                }}
              />
            </div>
            <div className="field">
              <label htmlFor="edit-state">状态</label>
              <select
                id="edit-state"
                value={issue.state}
                onChange={(e) => saveDetail({ state: e.target.value })}
              >
                {states.map((s) => (
                  <option key={s} value={s}>
                    {STATE_LABELS[s] || s}
                  </option>
                ))}
              </select>
            </div>
            <div className="field">
              <label htmlFor="edit-labels">标签</label>
              <input
                id="edit-labels"
                defaultValue={labelsToInput(issue.labels)}
                onBlur={(e) =>
                  saveDetail({ labels: labelsFromInput(e.target.value) })
                }
              />
            </div>
            <div className="panel-section">
              <h3>阻塞关系</h3>
              <p className="panel-hint">以下工单未完成时，本工单在「待办」不会被 Symphony 派发。</p>
              {(issue.blocked_by || []).length === 0 ? (
                <p className="muted-line">
                  暂无。看板上用 ⠿ {isMobile ? "点选" : "拖动"} 另一张卡片到本工单即可添加。
                </p>
              ) : (
                <ul className="blocker-list">
                  {(issue.blocked_by || []).map((b) => (
                    <li key={b.id}>
                      <span>
                        {b.identifier}
                        {b.state ? ` · ${STATE_LABELS[b.state] || b.state}` : ""}
                      </span>
                      <button type="button" className="btn btn-small" onClick={() => removeBlocker(b.id)}>
                        移除
                      </button>
                    </li>
                  ))}
                </ul>
              )}
            </div>
            <div className="panel-section">
              <h3>评论</h3>
              {(detail.comments || []).map((c) => (
                <div key={c.id} className="comment">
                  <div className="comment-meta">
                    {c.author} · {c.created_at}
                  </div>
                  <div>{c.body}</div>
                </div>
              ))}
              <div className="field">
                <textarea
                  placeholder="添加评论…"
                  value={commentText}
                  onChange={(e) => setCommentText(e.target.value)}
                />
              </div>
              <button type="button" className="btn btn-primary" onClick={submitComment}>
                发送
              </button>
            </div>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
