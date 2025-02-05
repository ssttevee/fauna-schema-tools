import * as fs from "node:fs/promises";
import { DeclarationType, RoleMemberType, Schema } from "./schema";
import { SourceMapConsumer } from "source-map";
import * as path from "node:path";
import globParent from "glob-parent";
import anymatch from "anymatch";

export { init, Schema } from "./schema";

export type PushSchemaOptions = {
  retainRevisions?: number;
  tempdir?: string;
} & (
  | { key: string }
  | { secret: string }
  | { endpoint: string; key?: string }
  | { endpoint: string; secret?: string }
);

const sourceMapComment =
  "//# sourceMappingURL=data:application/json;charset=utf-8;base64,";

async function loadSourceMapFromComment(
  content: string,
): Promise<[string, SourceMapConsumer | null]> {
  const index = content.indexOf(sourceMapComment);
  if (index === -1) {
    return [content, null];
  }

  const end = content.indexOf("\n", index);

  return [
    content.slice(0, index),
    await new SourceMapConsumer(
      atob(
        content.slice(
          index + sourceMapComment.length,
          end === -1 ? undefined : end,
        ),
      ),
    ),
  ];
}

const errorLocationPattern = /at (\w+\.fsl):(\d+):(\d+)/;

function fixErrorReferences(
  sourcemaps: Map<string, SourceMapConsumer>,
  message: string,
): string {
  let out = "";
  let pos = 0;
  while (true) {
    const match = errorLocationPattern.exec(message.slice(pos));
    if (!match) {
      break;
    }

    const smc = sourcemaps.get(match[1]);
    if (!smc) {
      out += message.slice(pos, pos + match.index + match[0].length);
      pos += match.index + match[0].length;
      continue;
    }

    const line = Number.parseInt(match[2]);
    const original = smc.originalPositionFor({
      line,
      column: Number.parseInt(match[3]) - 1,
    });

    if (
      original.source === null ||
      original.line === null ||
      original.column === null
    ) {
      out += message.slice(pos, pos + match.index + match[0].length);
      pos += match.index + match[0].length;
      continue;
    }

    out += message.slice(pos, pos + match.index);
    out += `at ${original.source}:${original.line}:${original.column + 1}`;
    pos += match.index + match[0].length;

    const nextMatch = errorLocationPattern.exec(message.slice(pos));
    const snippet = message.slice(
      pos,
      nextMatch ? pos + nextMatch.index : undefined,
    );

    let i = 0;
    let snippetpos = 0;
    let snippetresult = "";
    while (true) {
      const l = line + i;
      const match = snippet.slice(snippetpos).match(new RegExp(`${l} \\|`));
      if (!match) {
        break;
      }

      snippetresult += snippet.slice(snippetpos, match.index);
      snippetresult += `${(original.line + i).toString().padEnd(l.toString().length)} |`;
      snippetpos += match.index + match[0].length;

      i += 1;
    }

    if (snippetpos < snippet.length) {
      snippetresult += snippet.slice(snippetpos);
    }

    out += snippet;
    if (nextMatch) {
      pos += nextMatch.index;
    } else {
      pos = message.length;
    }
  }

  return out + message.slice(pos);
}

async function pullSchemaFile(
  endpoint: string,
  key: string,
  filename: string,
  destdir: string,
): Promise<Schema | null> {
  const res = await fetch(
    new URL(`/schema/1/files/${encodeURIComponent(filename)}`, endpoint),
    {
      method: "GET",
      headers: { Authorization: `Bearer ${key}` },
    },
  );

  if (res.status === 404) {
    return null;
  }

  const json = await res.json();
  if (json.error) {
    throw new Error(`failed to fetch ${filename}: ${json.error.message}`);
  }

  const diskpath = path.join(destdir, filename);
  writeIfChanged(diskpath, json.content);
  return Schema.parse(json.content, diskpath);
}

async function pullRevisionsAndRoles(
  endpoint: string,
  key: string,
  destdir: string,
): Promise<{ revisions: Schema[]; roles?: Schema; [Symbol.dispose](): void }> {
  const filesResponse = await fetch(new URL("/schema/1/files", endpoint), {
    method: "GET",
    headers: { Authorization: `Bearer ${key}` },
  });
  const files: {
    files: Array<{ filename: string }>;
    error?: { message: string };
  } = await filesResponse.json();
  if (files.error) {
    throw new Error(files.error.message);
  }

  await fs.rm(destdir, { force: true, recursive: true });

  const revisions = await Promise.all(
    files.files
      .flatMap((file) =>
        Array.from(file.filename.match(/^functions_(\d+)\.fsl$/) ?? []).slice(
          1,
        ),
      )
      .map((revision) => Number.parseInt(revision, 10))
      .sort()
      .map((revision) =>
        pullSchemaFile(endpoint, key, `functions_${revision}.fsl`, destdir),
      ),
  );

  const roles = await pullSchemaFile(endpoint, key, "roles.fsl", destdir);

  return {
    revisions,
    roles,

    [Symbol.dispose](): void {
      for (const revision of this.revisions) {
        revision.free();
      }

      if (this.roles) {
        this.roles.free();
      }
    },
  };
}

async function appendSchemaToBody(
  body: FormData,
  sourcemaps: Map<string, SourceMapConsumer>,
  schema: Schema,
  name: string,
): Promise<void> {
  const fullcontent = schema.toString({ sourceMapFilename: name });
  const [content, smc] = await loadSourceMapFromComment(fullcontent);
  body.set(name, content);
  sourcemaps.set(name, smc);
}

export class PushSchemaError extends Error {
  constructor(
    message: string,
    private readonly _details: string,
    private readonly sourcemaps: Map<string, SourceMapConsumer>,
  ) {
    super(message);
  }

  public get details(): string {
    return fixErrorReferences(this.sourcemaps, this._details);
  }
}

export class PushSchemaValidationError extends PushSchemaError {
  constructor(details: string, sourcemaps: Map<string, SourceMapConsumer>) {
    super("Validation failed", details, sourcemaps);
  }
}

export class PushSchemaUpdateError extends PushSchemaError {
  constructor(details: string, sourcemaps: Map<string, SourceMapConsumer>) {
    super("Update failed", details, sourcemaps);
  }
}

export interface PushSchemaResult {
  validationMs: number;
  diff?: string;
  updateMs?: number;
}

export async function pushSchema(
  schema: Schema,
  options: PushSchemaOptions,
): Promise<PushSchemaResult> {
  const tempdir = options.tempdir || ".fst";
  const endpoint =
    (options as { endpoint?: string }).endpoint || "https://db.fauna.com";
  const key =
    (options as { key?: string }).key ||
    (options as { secret?: string }).secret ||
    "";
  const retain = options.retainRevisions ?? 10;

  await fs.rm(tempdir, { recursive: true, force: true });

  const body = new FormData();
  const sourcemaps = new Map<string, SourceMapConsumer>();

  using accessProviders = schema.filterByType(DeclarationType.ACCESS_PROVIDER);
  using collections = schema.filterByType(DeclarationType.COLLECTION);

  using roles = schema.filterByType(DeclarationType.ROLE);
  const revisions: Schema[] = [];
  try {
    if (retain > 0) {
      const saved = await pullRevisionsAndRoles(
        endpoint,
        key,
        path.join(tempdir, "pulled"),
      );

      const functions = schema.filterByType(DeclarationType.FUNCTION);

      // remove all current functions from previous revisions
      for (const { type, name } of functions.declarations) {
        if (type !== DeclarationType.FUNCTION) {
          throw new Error("unreachable");
        }

        for (const revision of saved.revisions) {
          revision.removeDeclaration(type, name);
        }
      }

      revisions.push(...saved.revisions);

      if (saved.roles) {
        // remove all references to resources other than retained functions
        const retainedFunctionNames = new Set(
          revisions.flatMap((s) =>
            s.declarations
              .filter((d) => d.type === DeclarationType.FUNCTION)
              .map((d) => d.name),
          ),
        );

        for (const decl of saved.roles.declarations) {
          if (decl.type !== DeclarationType.ROLE) {
            console.warn(
              `found ${decl.type} in pulled roles.fsl? removing it just in case...`,
            );
            saved.roles.removeDeclaration(decl.type, decl.name);
            continue;
          }

          for (const resource of decl.resources) {
            if (
              resource.type !== RoleMemberType.PRIVILEGES ||
              !retainedFunctionNames.has(resource.name)
            ) {
              saved.roles.removeRolesResource(resource.type, resource.name);
            }
          }
        }

        roles.merge(saved.roles).mergeRoles();
      }

      // add new functions to the latest revision and remove the last one if it exceeds the limit
      revisions.unshift(functions);

      while (revisions.length > retain) {
        using culledFunctions = revisions.pop();
        for (const { type, name } of culledFunctions.declarations) {
          if (type !== DeclarationType.FUNCTION) {
            continue;
          }

          roles.removeRolesResource(RoleMemberType.PRIVILEGES, name);
        }
      }
    } else {
      revisions.unshift(schema.filterByType(DeclarationType.FUNCTION));
    }

    if (accessProviders.length) {
      await appendSchemaToBody(
        body,
        sourcemaps,
        accessProviders,
        "access_providers.fsl",
      );
    }
    if (collections.length) {
      await appendSchemaToBody(
        body,
        sourcemaps,
        collections,
        "collections.fsl",
      );
    }
    if (roles.length) {
      await appendSchemaToBody(body, sourcemaps, roles, "roles.fsl");
    }

    for (const [i, revision] of revisions
      .filter((schema) => schema.length)
      .entries()) {
      appendSchemaToBody(body, sourcemaps, revision, `functions_${i}.fsl`);
    }
  } finally {
    for (const revision of revisions) {
      revision.free();
    }
  }

  for (const [filename, content] of body.entries()) {
    await writeIfChanged(
      path.join(tempdir, "pushing", filename),
      content as string,
    );
  }

  const validationStart = Date.now();
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
    throw new PushSchemaValidationError(validation.error.message, sourcemaps);
  }

  const result: PushSchemaResult = {
    validationMs: Date.now() - validationStart,
    diff: validation.diff,
  };

  if (validation.diff) {
    const updateStart = Date.now();
    const updateResponse = await fetch(
      new URL(`/schema/1/update?version=${validation.version}`, endpoint),
      {
        method: "POST",
        headers: { Authorization: `Bearer ${key}` },
        body,
      },
    );

    const json = await updateResponse.json();
    if (json.error) {
      throw new PushSchemaUpdateError(json.error.message, sourcemaps);
    }

    result.updateMs = Date.now() - updateStart;
  }

  await fs.rm(tempdir, { recursive: true, force: true });

  return result;
}

export async function writeIfChanged(
  filepath: string,
  content: string,
): Promise<boolean> {
  const fullpath = path.resolve(filepath);
  try {
    await fs.mkdir(path.dirname(fullpath), { recursive: true });
    const prevContent = await fs.readFile(fullpath);
    if (prevContent.toString() === content) {
      return false;
    }
  } catch (err) {
    if (err.code !== "ENOENT") {
      throw err;
    }
  }

  await fs.writeFile(fullpath, content);

  return true;
}

export function mergeSchemas(
  schemas: Iterable<Schema>,
): [mergedSchema: Schema, mangledNames: Record<string, string>] {
  const merged = Schema.merge(Array.from(schemas, (schema) => schema.clone()));

  const mangledNames = merged.linkFunctions();
  merged.mergeRoles();
  merged.sort();

  return [merged, mangledNames];
}

export async function loadSchemas(
  schemapaths: string | string[],
): Promise<Schema[]> {
  const matches = anymatch(schemapaths);
  return await Promise.all(
    (
      await Promise.all(
        Array.from(
          new Set(
            (Array.isArray(schemapaths) ? schemapaths : [schemapaths]).map(
              (p) => globParent(p),
            ),
          ),
          async (p) =>
            (await fs.readdir(p, { withFileTypes: true, recursive: true })).map(
              (entry) => path.join(entry.parentPath, entry.name),
            ),
        ),
      )
    )
      .flat()
      .filter((p) => matches(p))
      .map(async (p) => Schema.parse(await fs.readFile(p, "utf8"), p)),
  );
}

export async function pushMergedSchemas(
  schemapaths: string | string[],
  options: PushSchemaOptions,
): Promise<number> {
  const schemas = await loadSchemas(schemapaths);
  if (schemas.length === 0) {
    return 0;
  }

  try {
    const [mergedSchema] = mergeSchemas(schemas);
    try {
      await pushSchema(mergedSchema, options);
    } finally {
      mergedSchema.free();
    }
  } finally {
    for (const schema of schemas) {
      schema.free();
    }
  }

  return schemas.length;
}
