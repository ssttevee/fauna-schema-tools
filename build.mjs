import { build } from "esbuild";

await build({
  entryPoints: ["src/main.ts"],
  bundle: true,
  outfile: "dist/main.mjs",
  format: "esm",
  external: ["fs", "zbind"],
  target: "es2022",
  platform: "neutral",
});

await build({
  entryPoints: ["dist/root.wasm"],
  bundle: true,
  outfile: "dist/root.wasm.mjs",
  format: "esm",
  loader: { ".wasm": "binary" },
});
