import {
  init,
  Schema,
  mergeSchemas,
  writeIfChanged,
  pushSchema,
  type PushSchemaOptions,
} from "./lib";
import * as fs from "node:fs/promises";
import * as chokidar from "chokidar";
import jen from "jennifer-js";
import {
  command,
  run,
  string,
  number,
  positional,
  restPositionals,
  option,
  optional,
  boolean,
  flag,
  subcommands,
} from "cmd-ts";

type SchemaCache = Record<string, { tree: Schema; content: string }>;

async function handleChange(
  schemas: SchemaCache,
  event: "add" | "change" | "unlink",
  id: string,
) {
  schemas[id]?.tree.free();

  switch (event) {
    case "add":
    case "change":
      {
        const content = await fs.readFile(id, "utf-8");
        schemas[id] = { tree: Schema.parse(content, id), content };
      }
      break;

    case "unlink":
      delete schemas[id];
      break;
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function debounce<T extends (...args: unknown[]) => unknown>(
  f: T,
  delayMs: number,
): (...arg: Parameters<T>) => Promise<Awaited<ReturnType<T>>> {
  let ts = Date.now();

  let started = 0;
  async function start(
    ...args: Parameters<T>
  ): Promise<Awaited<ReturnType<T>>> {
    while (ts > Date.now()) {
      await sleep(ts - Date.now());
    }

    started += 1;

    try {
      return await f.apply(this, args);
    } finally {
      started -= 1;
    }
  }

  let currentRun: Promise<Awaited<ReturnType<T>>> | null = null;
  return function run(...args: Parameters<T>): Promise<Awaited<ReturnType<T>>> {
    ts = Date.now() + delayMs;

    if (!currentRun || started) {
      const p = start.apply(this, args);
      currentRun = p;
      currentRun.finally(() => {
        if (currentRun === p) {
          currentRun = null;
        }
      });
    }

    return currentRun;
  };
}

function startWatcher(
  generateFn: (
    this: chokidar.FSWatcher,
    schamas: SchemaCache,
  ) => void | Promise<void>,
  paths: string | string[],
): chokidar.FSWatcher {
  const schemas: SchemaCache = {};

  const debouncedGenerate = debounce(generateFn, 10);

  const w = chokidar.watch(paths);
  w.on("all", (event, id) => {
    if (event === "addDir" || event === "unlinkDir") {
      return;
    }

    handleChange(schemas, event, id).then(() =>
      debouncedGenerate.call(w, schemas),
    );
  });
  return w;
}

function generateFnsMapFile(name: Record<string, string>): string {
  return jen
    .statements(
      ...Object.entries(name).map(([name, mangled]) =>
        jen.export.const.id(name).op("=").lit(mangled),
      ),
    )
    .toString();
}

interface OutputOptions {
  dtspath?: string;
  fnspath?: string;
  schema?: {
    path?: false | string;
    push?: false | PushSchemaOptions;
  };
}

async function writeAndPush(
  [schema, names]: ReturnType<typeof mergeSchemas>,
  output?: OutputOptions,
) {
  try {
    await Promise.all([
      output?.dtspath &&
        writeIfChanged(output.dtspath, schema.getTypescriptDefinitions()),
      output?.fnspath &&
        writeIfChanged(output.fnspath, generateFnsMapFile(names)),
      output?.schema?.path &&
        writeIfChanged(output.schema.path, schema.toString()),
      output?.schema?.push && pushSchema(schema, output.schema.push),
    ]);
  } finally {
    schema.free();
  }
}

async function build(
  schemapaths: string | string[],
  output?: OutputOptions,
): Promise<void> {
  const schemas = Object.values(
    await new Promise((resolve) => {
      const w = startWatcher(async function (schemas) {
        this.close();
        resolve(schemas);
      }, schemapaths);
      sleep(100).then(() => {
        resolve({});
        w.close();
      });
    }),
  );

  if (schemas.length === 0) {
    console.log("no schemas found");
    return;
  }

  console.log(`found ${schemas.length} schema files`);

  const start = Date.now();
  const mergedSchema = mergeSchemas(schemas.map((s) => s.tree));
  console.log(`merged schema in ${Date.now() - start}ms`);

  const writeStart = Date.now();
  await writeAndPush(mergedSchema, output);
  console.log(`generated and wrote files in ${Date.now() - writeStart}ms`);
}

function watch(
  schemapaths: string | string[],
  output?: OutputOptions,
): chokidar.FSWatcher {
  return startWatcher(
    (schemas) =>
      writeAndPush(
        mergeSchemas(Object.values(schemas).map((s) => s.tree)),
        output,
      ),
    schemapaths,
  );
}

const link = command({
  name: "link",
  description: "Link functions in a schema",
  args: {
    schemapath: positional({
      displayName: "schema path",
      description: "Path to schema files (globs are supported)",
      type: string,
    }),
    schemapaths: restPositionals({
      displayName: "schema paths",
      description: "Additional paths to schema files",
      type: string,
    }),
    watch: flag({
      long: "watch",
      short: "w",
      description: "Watch for changes and rebuild",
      type: boolean,
    }),
    typesout: option({
      long: "types-out",
      short: "t",
      description: "Output path for ts types file",
      type: optional(string),
    }),
    namesout: option({
      long: "names-out",
      short: "n",
      description: "Output path for ts function names map file",
      type: optional(string),
    }),
    schemaout: option({
      long: "schema-out",
      short: "s",
      description: "Output path for combined fsl file",
      type: optional(string),
    }),
    push: flag({
      long: "push",
      short: "p",
      description: "Push schema to db",
      type: boolean,
    }),
    pushkey: option({
      long: "key",
      short: "k",
      description: "Fauna key",
      type: optional(string),
    }),
    endpoint: option({
      long: "endpoint",
      short: "e",
      description:
        "Fauna endpoint (defaults to https://db.fauna.com if key is set, otherwise https://localhost:8443)",
      type: optional(string),
    }),
    retain: option({
      long: "retain",
      short: "r",
      description: "Number of function revisions to retain",
      defaultValue: () => 10,
      type: number,
    }),
  },
  handler: (args) => {
    const output: OutputOptions = {
      schema: {},
    };

    if (args.typesout) {
      output.dtspath = args.typesout;
    }

    if (args.namesout) {
      output.fnspath = args.namesout;
    }

    if (args.schemaout) {
      output.schema.path = args.schemaout;
    }

    if (args.push) {
      const push: PushSchemaOptions = args.pushkey
        ? { key: args.pushkey }
        : { endpoint: args.endpoint };
      if (args.retain) {
        push.retainRevisions = args.retain;
      }

      output.schema.push = push;
    }

    fs.readFile(
      typeof require !== "undefined"
        ? require.resolve("fauna-schema-tools/wasm")
        : import.meta.resolve("fauna-schema-tools/wasm"),
    ).then(async (w) => {
      init(w);

      await (args.watch ? watch : build)(
        [args.schemapath, ...args.schemapaths],
        output,
      );
    });
  },
});

const app = subcommands({
  name: "fauna-schema-tools",
  cmds: { link },
});

run(app, process.argv.slice(2));
