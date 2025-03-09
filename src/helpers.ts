import { fql, type QueryArgument } from "fauna";

export type FunctionHelper<Args extends QueryArgument[] = QueryArgument[]> =
  ReturnType<typeof fql> & {
    (...args: Args): ReturnType<typeof fql>;
    name: string;
  };

export function createFunctionHelper<
  Args extends QueryArgument[] = QueryArgument[],
>(name: string): FunctionHelper<Args> {
  const q = fql([name]);
  return Object.setPrototypeOf(
    Object.defineProperty(
      (...args: Args) =>
        fql(
          [
            "",
            "(",
            ...(args.length ? new Array(args.length - 1).fill(",") : []),
            ")",
          ],
          q,
          ...args,
        ),
      "name",
      {
        value: name,
      },
    ),
    { __proto__: q.constructor.prototype, name, encode: q.encode.bind(q) },
  ) as any;
}
