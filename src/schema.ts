import type { OpaqueStruct } from "zbind";
import * as zig from "./zig";

let initialized = false;

export function init(source?: BufferSource | string) {
  zig.$init(source);
  initialized = true;
}

function assertInitialized(): void {
  if (!initialized) {
    throw new Error("WASM was not initialized");
  }
}

export enum DeclarationType {
  ACCESS_PROVIDER = "access_provider",
  COLLECTION = "collection",
  FUNCTION = "function",
  ROLE = "role",
}

export class Schema {
  #data: OpaqueStruct;

  /**
   * Create a new schema from a list of schemas.
   *
   * NOTE: Schemas passed into this function will be consumed and should not be
   * used afterwards. Do not even call `free` on them.
   *
   * @param schemas - The list of schemas to merge.
   */
  public static merge(schemas: Schema[]): Schema {
    if (!schemas.length) {
      return Schema.parse("");
    }

    return schemas[0].merge(schemas.slice(1));
  }

  public static parse(strSchema: string, filename?: string): Schema {
    assertInitialized();

    const tree = zig.parseSchemaTree(strSchema, filename || null);
    if (!tree) {
      throw new Error("Failed to parse schema");
    }

    return new Schema(tree);
  }

  private constructor(data: OpaqueStruct) {
    this.#data = data;
  }

  public get length(): number {
    return zig.getSchemaTreeLength(this.#data);
  }

  public sort(): void {
    zig.sortSchemaTree(this.#data);
  }

  public linkFunctions(): Record<string, string> {
    const json = zig.linkFunctions(this.#data);
    if (!json) {
      throw new Error("Failed to link functions");
    }

    try {
      return JSON.parse(json.toString());
    } finally {
      zig.freeBytes(json);
    }
  }

  public merge(schemas: Schema | Schema[]): this {
    for (const other of Array.isArray(schemas) ? schemas : [schemas]) {
      const tree = zig.mergeSchemas(this.#data, other.#data);
      if (!tree) {
        throw new Error("Failed to merge schemas");
      }

      this.#data = tree;
    }

    return this;
  }

  public mergeRoles(): this {
    const tree = zig.mergeRoles(this.#data);
    if (!tree) {
      throw new Error("Failed to merge roles");
    }

    this.#data = tree;

    return this;
  }

  /**
   * Returns the type definitions as a string that can be written to a file.
   */
  public getTypescriptDefinitions(): string {
    const str = zig.generateTypescriptDefinitions(this.#data);
    if (!str) {
      throw new Error("Failed to generate typescript definitions");
    }

    try {
      return str.toString();
    } finally {
      zig.freeBytes(str);
    }
  }

  /**
   * Creates a new schema using only declarations of the specified type from the current schema.
   */
  public filterByType(type: DeclarationType): Schema {
    const tree = zig.filterSchemaTreeByType(this.#data, type);
    if (!tree) {
      throw new Error("Failed to filter schema by type");
    }

    return new Schema(tree);
  }

  /**
   * Removes a declaration by type and name.
   *
   * @returns {boolean} - Whether the declaration was removed.
   */
  public removeDeclaration(type: DeclarationType, name: string): boolean {
    const beforeLength = this.length;
    this.#data = zig.removeSchemaTreeDeclaration(this.#data, type, name);
    return this.length !== beforeLength;
  }

  /**
   * Removes references to a resource from all role declarations.
   */
  public removeRolesResource(resourceName: string): void {
    zig.removeSchemaTreeRolesResource(this.#data, resourceName);
  }

  public get declarations(): Array<{
    type: DeclarationType;
    name: string;
    resources?: string[];
  }> {
    const json = zig.listSchemaTreeDeclarations(this.#data);
    if (!json) {
      throw new Error("Failed to list declarations");
    }

    try {
      return JSON.parse(json.toString());
    } finally {
      zig.freeBytes(json);
    }
  }

  /**
   * Convert the schema to a string.
   * @param mangledNames - A map of mangled names to their original names. This is the same as the output of `linkFunctions`.
   */
  public toString(options?: {
    sourceMapFilename?: string;
    mangledNames?: Record<string, string>;
    sources?: Record<string, string>;
  }): string {
    const str = zig.printCanonicalTree(
      this.#data,
      options?.sourceMapFilename || null,
      options?.sourceMapFilename && options?.mangledNames
        ? JSON.stringify(options.mangledNames)
        : null,
      options?.sourceMapFilename && options?.sources
        ? JSON.stringify(options.sources)
        : null,
    );
    if (!str) {
      throw new Error("Failed to print canonical tree");
    }

    try {
      return str.toString();
    } finally {
      zig.freeBytes(str);
    }
  }

  public free(): void {
    zig.deinitSchemaTree(this.#data);
  }

  public [Symbol.dispose](): void {
    this.free();
  }

  public clone(): Schema {
    const tree = zig.cloneSchemaTree(this.#data);
    if (!tree) {
      throw new Error("Failed to clone schema");
    }

    return new Schema(tree);
  }
}
