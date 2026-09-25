// A second source file: everything under src/ is published together.

export function describe(method: string, text: string): string {
  const words = text.trim() === "" ? 0 : text.trim().split(/\s+/).length;
  return `${method}, ${text.length} bytes, ${words} words`;
}
