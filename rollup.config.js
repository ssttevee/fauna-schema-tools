import typescript from "@rollup/plugin-typescript";
import dts from "rollup-plugin-dts";
import { rollupPluginFileUint8Array } from "rollup-plugin-uint8-array";

/**
 * @type {import('rollup').RollupOptions[]}
 */
export default [
  {
    input: "dist/root.wasm",
    output: {
      file: "dist/root.wasm.mjs",
      format: "esm",
    },
    plugins: [rollupPluginFileUint8Array({ include: ["dist/root.wasm"] })],
  },
  {
    input: "src/index.ts",
    output: {
      file: "dist/index.mjs",
      format: "esm",
    },
    external: [
      "fs/promises",
      "zbind",
      "chokidar",
      "@rollup/pluginutils",
      "magic-string",
      "estree-walker",
      "../dist/root.wasm.mjs",
    ],
    plugins: [typescript()],
  },
  {
    input: "src/index.ts",
    output: {
      file: "dist/index.d.ts",
      format: "esm",
    },
    external: ["fs", "zbind", "chokidar", "../dist/root.wasm.mjs"],
    plugins: [dts()],
  },
];
