// Answer a request: the smallest function there is.
//
// `airdress.config` is the owner's configuration for this function, read at
// each call. `console.log` reaches the function's log.

declare const airdress: { config: { greeting?: string } };

export default function hello(req: Request): Response {
  const greeting = airdress.config.greeting ?? "hello";
  const { pathname } = new URL(req.url);
  console.log("answered", req.method, pathname);
  return Response.json({ greeting, method: req.method, path: pathname });
}
