import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";

const apiProxy = process.env.VITE_API_PROXY || "http://127.0.0.1:4780";
const devPort = Number(process.env.VITE_DEV_PORT || 4781);

export default defineConfig(({ mode }) => {
  loadEnv(mode, process.cwd(), "");
  return {
    plugins: [react()],
    server: {
      port: devPort,
      host: process.env.VITE_DEV_HOST || "127.0.0.1",
      strictPort: true,
      proxy: {
        "/api": {
          target: apiProxy,
          changeOrigin: true,
        },
      },
    },
  };
});
