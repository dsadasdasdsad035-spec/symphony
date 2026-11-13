import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/**
 * 若存在 web/dist，则挂载静态前端（生产一体化）。
 */
export async function registerStatic(app) {
  const dist = path.join(__dirname, "../../web/dist");
  const indexHtml = path.join(dist, "index.html");
  if (!fs.existsSync(indexHtml)) return;

  const fastifyStatic = (await import("@fastify/static")).default;
  await app.register(fastifyStatic, {
    root: dist,
    prefix: "/",
  });

  app.setNotFoundHandler((req, reply) => {
    if (req.url.startsWith("/api")) {
      return reply.code(404).send({ error: { message: "未找到" } });
    }
    return reply.sendFile("index.html");
  });
}
