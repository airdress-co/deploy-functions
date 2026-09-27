// Answer a request: the smallest function there is.
//
// `config` reads the owner's configuration for this function at each call;
// `log` writes to the function's log. Both are modules of the Airdress
// Functions SDK, which function.json pins ("sdk": "1.0.0") and the operator
// serves compiled in — nothing is installed from npm.

import { config } from "@airdress/functions/config";
import { log } from "@airdress/functions/log";

export default function hello(req: Request): Response {
  const greeting = config.string("greeting", { default: "hello" });
  const { pathname } = new URL(req.url);
  log.info("answered", { method: req.method, path: pathname });
  return Response.json({ greeting, method: req.method, path: pathname });
}
