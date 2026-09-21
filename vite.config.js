import { defineConfig } from "vite";

// Vite config tuned for Tauri: fixed port, no auto-clear so Rust logs stay visible.
export default defineConfig({
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
  },
});
