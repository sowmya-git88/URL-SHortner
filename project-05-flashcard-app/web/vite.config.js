import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

export default defineConfig({
  plugins: [svelte()],
  build: {
    outDir: "dist",
    emptyOutDir: true,
    sourcemap: false,
    // Smaller memory peak during the build on a 1 GB box
    minify: "esbuild",
    reportCompressedSize: false,
  },
  server: { proxy: { "/api": "http://127.0.0.1:5005" } },
});
