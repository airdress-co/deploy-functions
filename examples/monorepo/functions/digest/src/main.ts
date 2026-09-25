// Summarise a request. `label` comes from the owner's configuration, which
// differs between the two deployments of this one directory.

import { describe } from "./format.ts";

declare const airdress: { config: { label?: string } };

export default async function digest(req: Request): Promise<Response> {
  const text = await req.text();
  const label = airdress.config.label ?? "digest";
  console.log(label, req.method, text.length);
  return Response.json({ label, summary: describe(req.method, text) });
}
