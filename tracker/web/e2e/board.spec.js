import { test, expect } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";

const markerFile =
  process.env.E2E_PLAYWRIGHT_MARKER ||
  path.join(process.cwd(), "..", "scripts", ".e2e-playwright-marker.json");

test("看板：新建带 symphony 标签的工单并在待办列展示", async ({ page }) => {
  await page.goto("/");

  await expect(page.getByRole("heading", { name: /ai-comic-drama|comic/i }).first()).toBeVisible({
    timeout: 15_000,
  });

  const title = `Playwright-E2E-${Date.now()}`;
  await page.getByRole("button", { name: "新建工单" }).click();
  await page.locator("#new-title").fill(title);
  await page.locator("#new-labels").fill("symphony,e2e");
  await page.locator("#new-state").selectOption("todo");
  await page.getByRole("button", { name: "创建" }).click();

  const card = page.locator(".card", { hasText: title });
  await expect(card).toBeVisible({ timeout: 10_000 });

  const idText = await card.locator(".card-id").innerText();
  expect(idText).toMatch(/^COMIC-\d+$/);

  await card.click();
  await expect(page.locator(".modal-header h2, .modal h2").first()).toHaveText(title);
  await expect(page.locator("#edit-title")).toHaveValue(title);

  const projects = await page.evaluate(async () => {
    const res = await fetch("/api/v1/projects/comic/issues");
    return res.json();
  });

  const created = (projects.issues || []).find((i) => i.title === title);
  expect(created).toBeTruthy();
  expect(created.labels).toContain("symphony");

  fs.mkdirSync(path.dirname(markerFile), { recursive: true });
  fs.writeFileSync(
    markerFile,
    JSON.stringify(
      {
        title,
        issue_id: String(created.id),
        identifier: created.identifier,
      },
      null,
      2,
    ),
  );
});

test("看板：拖动阻塞手柄建立 blocked_by", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: /ai-comic-drama|comic/i }).first()).toBeVisible({
    timeout: 15_000,
  });

  const ts = Date.now();
  const blockerTitle = `Blocker-${ts}`;
  const blockedTitle = `Blocked-${ts}`;

  for (const [title, state] of [
    [blockerTitle, "in_progress"],
    [blockedTitle, "todo"],
  ]) {
    await page.getByRole("button", { name: "新建工单" }).click();
    await page.locator("#new-title").fill(title);
    await page.locator("#new-labels").fill("symphony,e2e");
    await page.locator("#new-state").selectOption(state);
    await page.getByRole("button", { name: "创建" }).click();
    await expect(page.locator(".card", { hasText: title })).toBeVisible({ timeout: 10_000 });
  }

  const blockedCard = page.locator(".card", { hasText: blockedTitle });
  const blockerCard = page.locator(".card", { hasText: blockerTitle });
  const handle = blockerCard.locator(".card-handle");
  await handle.dragTo(blockedCard);

  await expect(blockedCard.locator(".card-blocked")).toContainText("COMIC", { timeout: 10_000 });

  const blockedId = await blockedCard.evaluate((el) => {
    const idEl = el.querySelector(".card-id");
    return idEl?.textContent?.trim();
  });

  const list = await page.evaluate(async () => {
    const res = await fetch("/api/v1/projects/comic/issues");
    return res.json();
  });

  const blocked = (list.issues || []).find((i) => i.title === blockedTitle);
  expect(blocked?.blocked_by?.length).toBeGreaterThan(0);
  expect(blocked?.identifier).toBeTruthy();
  if (blockedId) expect(blocked.identifier).toBe(blockedId);
});

test("手机宽度：项目选择与点选阻塞", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");

  await expect(page.locator(".app-mobile, .topbar-project-select")).toBeVisible({ timeout: 15_000 });
  await expect(page.locator(".sidebar")).toBeHidden();

  const ts = Date.now();
  const blockerTitle = `MBlocker-${ts}`;
  const blockedTitle = `MBlocked-${ts}`;

  for (const [title, state] of [
    [blockerTitle, "in_progress"],
    [blockedTitle, "todo"],
  ]) {
    await page.getByRole("button", { name: "新建工单" }).click();
    await page.locator("#new-title").fill(title);
    await page.locator("#new-state").selectOption(state);
    await page.getByRole("button", { name: "创建" }).click();
    await expect(page.locator(".card", { hasText: title })).toBeVisible({ timeout: 10_000 });
  }

  const blockedCard = page.locator(".card", { hasText: blockedTitle });
  const blockerCard = page.locator(".card", { hasText: blockerTitle });
  await blockerCard.locator(".card-handle").click();
  await expect(page.locator(".link-banner")).toBeVisible();
  await blockedCard.locator(".card-body").click();
  await expect(blockedCard.locator(".card-blocked")).toBeVisible({ timeout: 10_000 });
});
