import { defineConfig } from "@playwright/test";

const webPort = Number(process.env.VITE_DEV_PORT || 14781);
const baseURL = process.env.PLAYWRIGHT_BASE_URL || `http://127.0.0.1:${webPort}`;
const channel = process.env.PLAYWRIGHT_CHANNEL || "chrome";

export default defineConfig({
  testDir: "./e2e",
  timeout: 60_000,
  retries: 0,
  use: {
    baseURL,
    headless: true,
    trace: "retain-on-failure",
  // 默认用本机 Chrome，避免 CI/自测反复下载 ~190MB Chromium 包
    ...(channel ? { channel } : {}),
  },
  reporter: [["list"]],
});
