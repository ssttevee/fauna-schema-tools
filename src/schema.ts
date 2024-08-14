import { OpaqueStruct } from "zbind";
import * as zig from "./zig";

export function init(source?: WebAssembly.Module | BufferSource | string) {
  zig.$init(source);
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

    let schema = schemas[0];
    for (const other of schemas.slice(1)) {
      const result = zig.mergeSchemas(schema.#data, other.#data);
      if (!result) {
        throw new Error("Failed to merge schemas");
      }

      schema.#data = result;
    }

    return schema;
  }

  public static parse(strSchema: string, filename?: string): Schema {
    const tree = zig.parseSchemaTree(strSchema, filename || null);
    if (!tree) {
      throw new Error("Failed to parse schema");
    }

    return new Schema(tree);
  }

  private constructor(data: OpaqueStruct) {
    this.#data = data;
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

  public mergeRoles(): void {
    const tree = zig.mergeRoles(this.#data);
    if (!tree) {
      throw new Error("Failed to merge roles");
    }

    this.#data = tree;
  }

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

  public toString(): string {
    const str = zig.printCanonicalTree(this.#data);
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
