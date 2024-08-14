import * as faunatools from "./schema";
import * as fs from "fs/promises";

faunatools.init(await fs.readFile("./dist/root.wasm"));

using tree = faunatools.Schema.merge([
  faunatools.Schema.parse(await fs.readFile("schema-1.fsl", "utf8")),
  faunatools.Schema.parse(await fs.readFile("schema-2.fsl", "utf8")),
  faunatools.Schema.parse(await fs.readFile("schema-3.fsl", "utf8")),
]);
await fs.writeFile("schema.d.ts", tree.getTypescriptDefinitions());
tree.linkFunctions();
tree.mergeRoles();
await fs.writeFile("canonical.fsl", tree.toString());
