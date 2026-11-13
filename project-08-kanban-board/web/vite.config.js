import { defineConfig } from "vite";
import solid from "vite-plugin-solid";

export default defineConfig({
  plugins: [solid()],
  build: { outDir: "dist", emptyOutDir: true, sourcemap: false, reportCompressedSize: false },
  server: { proxy: { "/api": "http://127.0.0.1:5008" } },
});
