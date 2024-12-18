import * as fs from "node:fs/promises";
import { DeclarationType, Schema } from "./schema";
import { SourceMapConsumer } from "source-map";
import * as path from "node:path";

export { init, Schema } from "./schema";

export type PushSchemaOptions = {
  retainRevisions?: number;
  tempdir?: string;
} & ({ key: string } | { endpoint: string; key?: string });

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

export async function pushSchema(
  schema: Schema,
  options: PushSchemaOptions,
): Promise<void> {
  const tempdir = options.tempdir || ".fst";
  const endpoint =
    (options as { endpoint?: string }).endpoint || "https://db.fauna.com";
  const key = options.key || "";
  const retain = options.retainRevisions || 10;

  await fs.rm(tempdir, { recursive: true, force: true });

  using saved = await pullRevisionsAndRoles(
    endpoint,
    key,
    path.join(tempdir, "pulled"),
  );

  using accessProviders = schema.filterByType(DeclarationType.ACCESS_PROVIDER);
  using collections = schema.filterByType(DeclarationType.COLLECTION);

  // remove all current functions from previous revisions
  const functions = schema.filterByType(DeclarationType.FUNCTION);
  for (const { type, name } of functions.declarations) {
    if (type !== DeclarationType.FUNCTION) {
      continue;
    }

    for (const revision of saved.revisions) {
      revision.removeDeclaration(type, name);
    }

    saved.roles?.removeRolesResource(name);
  }

  using roles = saved.roles
    ? Schema.merge([
        saved.roles.clone(),
        schema.filterByType(DeclarationType.ROLE),
      ]).mergeRoles()
    : schema.filterByType(DeclarationType.ROLE);

  // add new functions to the latest revision and remove the last one if it exceeds the limit
  saved.revisions.unshift(functions);
  while (saved.revisions.length > retain) {
    using culledFunctions = saved.revisions.pop();
    for (const { type, name } of culledFunctions.declarations) {
      if (type !== DeclarationType.FUNCTION) {
        continue;
      }

      roles.removeRolesResource(name);
    }
  }

  const body = new FormData();
  const sourcemaps = new Map<string, SourceMapConsumer>();

  if (accessProviders.length) {
    await appendSchemaToBody(
      body,
      sourcemaps,
      accessProviders,
      "access_providers.fsl",
    );
  }
  if (collections.length) {
    await appendSchemaToBody(body, sourcemaps, collections, "collections.fsl");
  }
  if (roles.length) {
    await appendSchemaToBody(body, sourcemaps, roles, "roles.fsl");
  }

  for (const [i, revision] of saved.revisions
    .filter((schema) => schema.length)
    .entries()) {
    appendSchemaToBody(body, sourcemaps, revision, `functions_${i}.fsl`);
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
    console.error(fixErrorReferences(sourcemaps, validation.error.message));
    throw new Error("Validation failed");
  }

  console.log(`schema validation took ${Date.now() - validationStart}ms`);

  if (validation.diff) {
    console.log(validation.diff);

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
      console.error(fixErrorReferences(sourcemaps, json.error.message));
      throw new Error("Update failed");
    }

    console.log(`update took ${Date.now() - updateStart}ms`);

    console.log(json);
  } else {
    console.log("no schema changes found, skipping update");
  }

  await fs.rm(tempdir, { recursive: true, force: true });
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
