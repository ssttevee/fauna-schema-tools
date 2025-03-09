# fauna-schema-tools

A set of tools for working with FaunaDB schema definitions.

## Commands

### link

Merge schema files and link functions. See [Function Linking](#function-linking) for more information.

```
fauna-schema-tools link
> Merge schema files and link functions

ARGUMENTS:
  <schema path>     - Path to schema files (globs are supported)
  [...schema paths] - Additional paths to schema files

FLAGS:
  --watch, -w - Watch for changes and rebuild
  --push, -p  - Push schema to db
  --help, -h  - show help

OPTIONS:
  --types-out, -t <str>  - Output path for ts types file [optional]
  --names-out, -n <str>  - Output path for ts function names map file [optional]
  --schema-out, -s <str> - Output path for combined fsl file [optional]
  --key, -k <str>        - Fauna key [optional]
  --endpoint, -e <str>   - Fauna endpoint (defaults to https://db.fauna.com if key is set, otherwise https://localhost:8443) [optional]
  --retain, -r <number>  - Number of function revisions to retain [optional]
```

### format

Format schema files.

```
> Format a schema file

ARGUMENTS:
  [...schema paths] - Paths to schema files (globs are supported)

FLAGS:
  --write, -w - Write changes to file
  --help, -h  - show help
```

## Library

When importing the library, the wasm module must be initialized. Depending on your environment, you may need to use different methods to load the wasm file:

```ts
import { init } from "fauna-schema-tools";
import wasm from "fauna-schema-tools/wasm-embedded";

init(wasm);

// or use a dynamic import
init((await import("fauna-schema-tools/wasm-embedded")).default);

// or even read the wasm file directly!
init(
  await fs.readFile(
    typeof require !== "undefined"
      ? require.resolve("fauna-schema-tools/wasm")
      : import.meta.resolve("fauna-schema-tools/wasm"),
  ),
);

// or somehow preload the module
declare const module: WebAssembly.Module;
init(module);
```

## Function Linking

Function linking allows you to have atomic function names that won't change the behavior of your live application when you update your schema.

This is done by generating a hash based on the function's body and including it in the function's name. All references in the schema to the function are updated to use the new name.

When combined with the `--retain` option, you can safely push schema changes to your database without affecting your live application.

When calling a function from a query in your application, use the `--names-out` option to generate a module that exports the names of the functions. Then it can be used like this:

```ts
import { fql } from "fauna";
import { myFunction } from "./functions_gen";

fql`${myFunction}()`;
```
