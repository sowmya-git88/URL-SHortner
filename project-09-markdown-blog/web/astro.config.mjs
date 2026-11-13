import { defineConfig } from "astro/config";

// Static output: Astro renders HTML at build time; data is fetched from /api at runtime.
export default defineConfig({
  output: "static",
  trailingSlash: "ignore",
  build: { format: "directory" },
  server: { port: 4321 },
  vite: { server: { proxy: { "/api": "http://127.0.0.1:5009" } } },
});
