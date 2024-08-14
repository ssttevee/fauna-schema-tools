import * as chokidar from "chokidar";
import type { AstNodeLocation, Plugin } from "rollup";
import * as fs from "fs/promises";
import type { Matcher } from "anymatch";
import { init, Schema } from "./schema";
import { createFilter, FilterPattern } from "@rollup/pluginutils";
import { walk } from "estree-walker";
import type * as estree from "estree";
import MagicString from "magic-string";

import source from "../dist/root.wasm.mjs";

init(source);

export type PushSchemaOptions = { validate?: boolean } & (
  | { key: string }
  | { endpoint: string; key?: string }
);

async function pushSchema(
  schema: string,
  options: PushSchemaOptions,
): Promise<void> {
  const endpoint = (options as any).endpoint || "https://db.fauna.com";
  const key = options.key || "";

  const body = new FormData();
  body.append("combined.fsl", schema);

  const validationResponse = await fetch(
    new URL("/schema/1/validate?force=true", endpoint),
    {
      method: "POST",
      headers: { Authorization: `Bearer ${key}` },
      body,
    },
  );

  const validation = await validationResponse.json();
  if (validation.error) {
    console.error(validation.error.message);
    throw new Error("Validation failed");
  }

  console.log(validation);

  const updateResponse = await fetch(
    new URL("/schema/1/update?version=" + validation.version, endpoint),
    {
      method: "POST",
      headers: { Authorization: `Bearer ${key}` },
      body,
    },
  );

  const json = await updateResponse.json();
  if (json.error) {
    console.error(json.error.message);
    throw new Error("Update failed");
  }

  console.log(json);
}

async function writeIfChanged(path: string, content: string): Promise<boolean> {
  try {
    const prevContent = await fs.readFile(path);
    if (prevContent.toString() === content) {
      return false;
    }
  } catch (err) {
    if (err.code !== "ENOENT") {
      throw err;
    }
  }

  await fs.writeFile(path, content);

  return true;
}

async function generate(
  { dtspath = "src/schematypes.ts", schema }: Options["output"] = {},
  changes: Array<{ event: "add" | "change" | "unlink"; id: string }>,
  schemas: Record<string, Schema>,
): Promise<Record<string, string>> {
  const schemapath = schema.path || "combined.fsl";
  const changesCopy = changes.splice(0, changes.length);

  for (const { event, id } of changesCopy) {
    const prevSchema = schemas[id];
    if (prevSchema) {
      prevSchema.free();
    }

    switch (event) {
      case "add":
      case "change":
        schemas[id] = Schema.parse(await fs.readFile(id, "utf-8"), id);
        break;

      case "unlink":
        delete schemas[id];
        break;
    }
  }

  const mergedSchema = Schema.merge(
    Object.values(schemas).map((schema) => schema.clone()),
  );
  try {
    const mangledNames = mergedSchema.linkFunctions();
    mergedSchema.mergeRoles();
    mergedSchema.sort();

    const strfsl = mergedSchema.toString();

    await Promise.all([
      writeIfChanged(dtspath, mergedSchema.getTypescriptDefinitions()),
      schemapath && writeIfChanged(schemapath, strfsl),
      schema.push && pushSchema(strfsl, schema.push),
    ]);

    return mangledNames;
  } finally {
    mergedSchema.free();
  }
}

function startWatcher(
  generateFn: (
    changes: Array<{ event: "add" | "change" | "unlink"; id: string }>,
    schemas: Record<string, Schema>,
  ) => any,
  paths:
    | string
    | string[]
    | {
        include: string | string[];
        exclude?: Matcher;
      },
): chokidar.FSWatcher {
  const schemas: Record<string, Schema> = {};
  const changes: Array<{ event: "add" | "change" | "unlink"; id: string }> = [];

  const include =
    typeof paths === "string" || Array.isArray(paths) ? paths : paths.include;
  const exclude =
    typeof paths === "string" || Array.isArray(paths)
      ? undefined
      : paths.exclude;

  let generateTimeout: NodeJS.Timeout | null = null;
  return chokidar
    .watch(include, { ignored: exclude })
    .on("all", (event, id) => {
      if (event === "addDir" || event === "unlinkDir") {
        return;
      }

      changes.push({ event, id });
      if (generateTimeout) {
        clearTimeout(generateTimeout);
      }

      generateTimeout = setTimeout(() => {
        generateTimeout = null;
        generateFn(changes, schemas);
      }, 10);
    });
}

export interface Options {
  schemapaths?:
    | string
    | string[]
    | {
        include: string | string[];
        exclude?: Matcher;
      };

  transformfilter?: {
    include?: FilterPattern;
    exclude?: FilterPattern;
  };

  output?: {
    dtspath?: string;
    schema?: {
      path?: false | string;
      push?: false | PushSchemaOptions;
    };
  };
}

export default function ({
  schemapaths = "src/**/*.fsl",
  transformfilter = {
    exclude: ["**/node_modules/**"],
  },
  output,
}: Options = {}): Plugin {
  let watcher: chokidar.FSWatcher;
  let mangledNamesPromise: Promise<Record<string, string>>;

  const transformFilter = createFilter(
    transformfilter.include,
    transformfilter.exclude,
  );

  return {
    name: "fauna",
    async buildStart() {
      if (mangledNamesPromise) {
        return;
      }

      if (!this.meta.watchMode) {
        mangledNamesPromise = new Promise<Record<string, string>>(
          (resolve, reject) => {
            const w = startWatcher(
              (changes, schemas) =>
                generate(output, changes, schemas)
                  .then(resolve, reject)
                  .finally(() => w.close()),
              schemapaths,
            );
          },
        );
      } else {
        let resolve: (value: Record<string, string>) => void;
        let reject: (reason: any) => void;
        mangledNamesPromise = new Promise<Record<string, string>>(
          (_resolve, _reject) => {
            resolve = _resolve;
            reject = _reject;
          },
        );
        var initial = true;
        watcher = startWatcher((changes, schemas) => {
          const p = generate(output, changes, schemas);
          if (initial) {
            p.then(resolve, reject);
          } else {
            mangledNamesPromise = p;
          }
        }, schemapaths);
      }
    },
    async transform(code, id) {
      if (!transformFilter(id)) {
        return;
      }

      const ast = this.parse(code);
      let tagIdentifier: string | undefined;

      walk(ast, {
        enter(node) {
          if (
            tagIdentifier ||
            !isImportDeclaration(node) ||
            node.source.value !== "fauna"
          ) {
            return;
          }

          tagIdentifier = node.specifiers.find(
            (specifier) =>
              isImportSpecifier(specifier) && specifier.imported.name === "fql",
          )?.local?.name;
        },
      });

      const mangledNames = Object.entries(await mangledNamesPromise);

      const s = new MagicString(code);

      let changes = false;
      walk(ast, {
        enter(node) {
          if (
            !isTaggedTemplateExpression(node) ||
            node.tag.type !== "Identifier" ||
            node.tag.name !== tagIdentifier
          ) {
            return;
          }

          // TODO: do identifier replacements in wasm
          const { quasis, expressions } = node.quasi;
          for (const elem of quasis as Array<
            estree.TemplateElement & AstNodeLocation
          >) {
            for (const [originalName, mangledName] of mangledNames) {
              let pos = 0;
              while (true) {
                const index = elem.value.raw.indexOf(originalName, pos);
                if (index == -1) {
                  break;
                }

                changes = true;

                s.update(
                  elem.start + index,
                  elem.start + index + originalName.length,
                  mangledName,
                );

                pos = index + originalName.length;
              }
            }
          }
        },
      });

      if (!changes) {
        return;
      }

      return {
        code: s.toString(),
        map: s.generateMap({
          source: id,
          file: id + ".map",
          includeContent: false,
        }),
      };
    },
    closeWatcher() {
      watcher?.close();
    },
  };
}

function isTaggedTemplateExpression(
  node: estree.BaseNode,
): node is estree.TaggedTemplateExpression {
  return node.type === "TaggedTemplateExpression";
}

function isImportSpecifier(
  node: estree.BaseNode,
): node is estree.ImportSpecifier {
  return node.type === "ImportSpecifier";
}

function isImportDeclaration(
  node: estree.BaseNode,
): node is estree.ImportDeclaration {
  return node.type === "ImportDeclaration";
}
