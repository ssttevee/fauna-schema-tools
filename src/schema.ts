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
  public static from(schemas: Schema[]): Schema {
    if (!schemas.length) {
      return new Schema("");
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

  public constructor(strSchema: string) {
    const tree = zig.parseSchemaTree(strSchema);
    if (!tree) {
      throw new Error("Failed to parse schema");
    }

    this.#data = tree;
  }

  public linkFunctions(): void {
    if (!zig.linkFunctions(this.#data)) {
      throw new Error("Failed to link functions");
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
}
