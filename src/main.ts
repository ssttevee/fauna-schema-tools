import * as zig from "./zig";
import * as fs from "fs/promises";

zig.$init(await fs.readFile("./dist/root.wasm"));

let tree = zig.parseSchemaTree(await fs.readFile("schema.fsl", "utf8"));
if (!tree) {
  throw new Error("could not parse schema");
}

try {
  const defs = zig.generateTypescriptDefinitions(tree);
  if (!defs) {
    throw new Error("could not generate definitions");
  }

  try {
    await fs.writeFile("schema.d.ts", defs.toString());
  } finally {
    zig.freeBytes(defs);
  }

  if (!zig.linkFunctions(tree)) {
    throw new Error("could not link functions");
  }

  const merged = zig.mergeRoles(tree);
  if (!merged) {
    throw new Error("could not merge roles");
  } else {
    tree = merged;
  }

  const canonical = zig.printCanonicalTree(tree);
  if (!canonical) {
    throw new Error("could not print canonical tree");
  }

  try {
    await fs.writeFile("canonical.fsl", canonical.toString());
  } finally {
    zig.freeBytes(canonical);
  }
} finally {
  zig.deinitSchemaTree(tree);
}
