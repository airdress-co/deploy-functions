// A second source file: everything under src/ is published together. A
// helper only this function uses lives here; one two functions share is
// either in the Functions SDK or copied into each (see the README).

export function describe(method: string, text: string): string {
  const words = text.trim() === "" ? 0 : text.trim().split(/\s+/).length;
  return `${method}, ${text.length} bytes, ${words} words`;
}
