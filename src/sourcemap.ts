import type { SourceMapConsumer } from "source-map";

const codeSnippetBlockLinePattern = /^[\s\d]+\|/;

function isCodeSnippetLine(line: string): boolean {
  return codeSnippetBlockLinePattern.test(line);
}

/**
 * split the error message by the boundaries of code snippets and text messages
 */
function* splitSections(
  message: string,
): Generator<{ lines: string[]; isCodeSnippetSection: boolean }> {
  let pos = 0;

  let currentSectionIsCodeSnippet = isCodeSnippetLine(message);
  const sectionLines = [];
  while (pos < message.length) {
    let index = message.indexOf("\n", pos);
    if (index === -1) {
      index = message.length;
    }

    const line = message.slice(pos, index);
    if (currentSectionIsCodeSnippet !== isCodeSnippetLine(line)) {
      yield {
        lines: Array.from(sectionLines),
        isCodeSnippetSection: currentSectionIsCodeSnippet,
      };
      sectionLines.splice(0, sectionLines.length);
      currentSectionIsCodeSnippet = !currentSectionIsCodeSnippet;
    }

    sectionLines.push(line);
    pos = index + 1;
  }

  if (sectionLines.length) {
    yield {
      lines: Array.from(sectionLines),
      isCodeSnippetSection: currentSectionIsCodeSnippet,
    };
  }
}

const errorLocationPattern = /at (\w+\.fsl):(\d+):(\d+)/;

function fixLineErrorLocation(
  sourcemaps: Map<string, SourceMapConsumer>,
  line: string,
): [SourceMapConsumer, string] | undefined {
  const match = errorLocationPattern.exec(line);
  if (!match) {
    return;
  }

  const smc = sourcemaps.get(match[1]);
  if (!smc) {
    return;
  }

  const original = smc.originalPositionFor({
    line: Number.parseInt(match[2]),
    column: Number.parseInt(match[3]) - 1,
  });

  if (
    original.source === null ||
    original.line === null ||
    original.column === null
  ) {
    return;
  }

  return [
    smc,
    `${line.slice(0, match.index)}at ${original.source}:${original.line}:${original.column + 1}${line.slice(match.index + match[0].length)}`,
  ];
}

function* fixTextMessageErrorLocations(
  sourcemaps: Map<string, SourceMapConsumer>,
  lines: Iterable<string>,
): Iterable<SourceMapConsumer | string> {
  for (const line of lines) {
    yield* fixLineErrorLocation(sourcemaps, line) ?? [line];
  }
}

function isUnderscoreLine(line: string): boolean {
  return Boolean(line.match(/^[\s\|_]+\^+/));
}

const hashedFuncNamePattern = /([\w\d]+)_[a-f0-9]{40}/;

function* replaceCodeSnippetFunctionNames(
  lines: Iterable<string>,
): Generator<string> {
  let cutNextUnderlineRanges: Array<[number, number]> | null = null;
  for (const line of lines) {
    let pos = 0;
    let newline = "";

    if (cutNextUnderlineRanges && isUnderscoreLine(line)) {
      for (const [start, end] of cutNextUnderlineRanges) {
        newline += line.slice(pos, start);
        pos = end;
      }

      cutNextUnderlineRanges = null;
    } else {
      cutNextUnderlineRanges = null;

      const removedRanges: Array<[number, number]> = [];
      while (pos < line.length) {
        const match = hashedFuncNamePattern.exec(line.slice(pos));
        if (!match) {
          break;
        }

        newline += line.slice(pos, pos + match.index) + match[1];
        pos += match.index;
        removedRanges.push([pos + match[1].length, pos + match[0].length]);
        pos += match[0].length;
      }

      if (removedRanges.length) {
        cutNextUnderlineRanges = removedRanges;
      }
    }

    yield newline + line.slice(pos);
  }
}

const codeSnippetNumberedLinePattern = /^\s*?\d+(\s*?\|)/;

function* fixCodeSnippetLineNumbers(
  smc: SourceMapConsumer,
  lines: Iterable<string>,
): Generator<string> {
  // TODO: handle line number inconsistencies with non-`fauna-schema-tools format`ed code snippets
  //       (e.g. code snipped returned by the db are formatted, but the original files may not be)

  let lineNumberOffset: number | null = null;
  for (const line of lines) {
    const match = codeSnippetNumberedLinePattern.exec(line);
    if (!match) {
      yield line;
      continue;
    }

    const suffix = match[1];
    const rest = line.slice(match[0].length);

    const lineNumberStr = line.slice(0, match[0].length - suffix.length);
    const lineNumber = Number.parseInt(lineNumberStr);
    if (lineNumberOffset === null) {
      let codeLine = rest.slice(1); // there is always a leading space
      if (codeLine.startsWith("|")) {
        // there is a arrow, adding another 2 chars before the real code line
        codeLine = codeLine.slice(2);
      }

      const original = smc.originalPositionFor({
        line: lineNumber,
        column: codeLine.length - codeLine.trimStart().length,
      });
      lineNumberOffset = original.line - lineNumber;
    }

    yield (lineNumber + lineNumberOffset)
      .toString()
      .padStart(lineNumberStr.length) +
      suffix +
      rest;
  }
}

function* fixErrorReferencesBySection(
  sourcemaps: Map<string, SourceMapConsumer>,
  message: string,
): Iterable<string> {
  let smc: SourceMapConsumer | null = null;
  for (const section of splitSections(message)) {
    if (section.isCodeSnippetSection) {
      let fixedLines = replaceCodeSnippetFunctionNames(section.lines);
      if (smc) {
        fixedLines = fixCodeSnippetLineNumbers(smc, fixedLines);
      }

      yield* fixedLines;
    } else {
      for (const lineOrSmc of fixTextMessageErrorLocations(
        sourcemaps,
        section.lines,
      )) {
        if (typeof lineOrSmc === "string") {
          yield lineOrSmc;
        } else {
          smc = lineOrSmc;
        }
      }
    }
  }
}

export function fixErrorReferences(
  sourcemaps: Map<string, SourceMapConsumer>,
  message: string,
): string {
  return Array.from(fixErrorReferencesBySection(sourcemaps, message)).join(
    "\n",
  );
}

const details = `error: Unknown type \`void\`
at src/fql/functions/publishEvent.fsl:1:76
    |
116 | function publishEvent_95ed4d7d8b3e89c8228766c14ec01abcca73312d(event: "created" | "updated" | "deleted", doc: Any): void {
    |                                                                                                                     ^^^^
    |
error: Function was not called with enough arguments. Expected 2, received 1
at src/fql/functions/matchPrivilegeRequest.fsl:7:25
  |
83 |             publishEvent_95ed4d7d8b3e89c8228766c14ec01abcca73312d('asdf')
  |                                                                  ^^^^^^^^
  |
error: Type \`({ includes: A => B, ... } & { includes: C => D, ... } & { includes: E => F, ... }, A & { any: (C & { every: (E => F) => D, ... } => D) => Any, ... }) => B | false\` is not a subtype of \`(userPrivileges: Array<String> | Null, wantedPrivileges: Array<String | Array<String>>) => Boolean\`
at src/fql/functions/matchPrivilegeRequest.fsl:1:1
   |
78 |   function matchPrivilegeRequest_825dc9be3dac2df2d2679a67b53877ecc92ecb4c(userPrivileges: Array<String> | Null, wantedPrivileges: Array<Array<String> | String>): Boolean {
   |  _^
79 | |     if (userPrivileges isa Array) {
80 | |         if (wantedPrivileges isa String) {
81 | |             userPrivileges!.includes(wantedPrivileges)
82 | |         } else if (wantedPrivileges isa Array) {
83 | |             publishEvent_95ed4d7d8b3e89c8228766c14ec01abcca73312d('asdf')
84 | |             wantedPrivileges.any(
85 | |                 (wantedPrivilege) => {
86 | |                     if (wantedPrivilege isa String) {
87 | |                         userPrivileges!.includes(wantedPrivilege)
88 | |                     } else if (wantedPrivilege isa Array) {
89 | |                         wantedPrivilege.every((privilege) => userPrivileges!.includes(privilege))
90 | |                     } else {
91 | |                         abort("invalid wantedPrivileges input")
92 | |                     }
93 | |                 },
94 | |             )
95 | |         } else {
96 | |             abort("invalid wantedPrivileges input")
97 | |         }
98 | |     } else {
99 | |         false
100 | |     }
101 | | }
   | |_^
   |
cause: Type \`Array<String | Array<String>>\` is not a subtype of \`String\`
  |
78 | function matchPrivilegeRequest_825dc9be3dac2df2d2679a67b53877ecc92ecb4c(userPrivileges: Array<String> | Null, wantedPrivileges: Array<Array<String> | String>): Boolean {
  |                                                                                                                                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  |
cause: Type \`Array<String>\` is not a subtype of \`String\`
  |
78 | function matchPrivilegeRequest_825dc9be3dac2df2d2679a67b53877ecc92ecb4c(userPrivileges: Array<String> | Null, wantedPrivileges: Array<Array<String> | String>): Boolean {
  |                                                                                                                                       ^^^^^^^^^^^^^
  |
cause: Type \`String\` does not have field \`every\`
at src/fql/functions/matchPrivilegeRequest.fsl:13:41
  |
89 |                         wantedPrivilege.every((privilege) => userPrivileges!.includes(privilege))
  |                                         ^^^^^
  |
hint: Type \`String\` inferred here
  |
78 | function matchPrivilegeRequest_825dc9be3dac2df2d2679a67b53877ecc92ecb4c(userPrivileges: Array<String> | Null, wantedPrivileges: Array<Array<String> | String>): Boolean {
  |                                                                                                                                                       ^^^^^^
  |
`;
