import typescript from "@rollup/plugin-typescript";
import dts from "rollup-plugin-dts";
import { rollupPluginFileUint8Array } from "rollup-plugin-uint8-array";
import resolve from "@rollup/plugin-node-resolve";
import commonjs from "@rollup/plugin-commonjs";

/**
 * @type {import('rollup').RollupOptions[]}
 */
export default [
  {
    input: "dist/root.wasm",
    output: [
      {
        file: "dist/root.wasm.mjs",
        format: "esm",
      },
      {
        file: "dist/root.wasm.cjs",
        format: "cjs",
      },
    ],
    plugins: [rollupPluginFileUint8Array({ include: ["dist/root.wasm"] })],
  },
  {
    input: ["src/lib.ts", "src/main.ts"],
    output: [
      {
        dir: "dist",
        format: "esm",
        sourcemap: true,
        entryFileNames: "[name].mjs",
      },
      {
        dir: "dist",
        format: "cjs",
        sourcemap: true,
        entryFileNames: "[name].cjs",
      },
    ],
    external: [
      "node:fs/promises",
      "node:path",
      "chokidar",
      "source-map",
      "jennifer-js",
      "cmd-ts",
    ],
    plugins: [
      typescript(),
      resolve(),
      commonjs(),
      {
        renderChunk(code, chunk) {
          if (!chunk.name.startsWith("main")) {
            return null;
          }

          return `#!/usr/bin/env node\n\n${code}`;
        },
      },
    ],
  },
  {
    input: "src/lib.ts",
    output: {
      file: "dist/lib.d.ts",
      format: "esm",
    },
    plugins: [dts()],
  },
];
