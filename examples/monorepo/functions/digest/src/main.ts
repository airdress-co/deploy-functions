// Summarise a request. `label` comes from the owner's configuration, which
// differs between the two deployments of this one directory.

import { config } from "@airdress/functions/config";
import { log } from "@airdress/functions/log";
import { describe } from "./format.ts";

export default async function digest(req: Request): Promise<Response> {
  const text = await req.text();
  const label = config.string("label", { default: "digest" });
  log.info(label, { method: req.method, bytes: text.length });
  return Response.json({ label, summary: describe(req.method, text) });
}
