// Relay a webhook to another operator: forward the body as a POST and
// answer with the peer's status. The host refuses any URL outside the
// function's granted `http.hosts` before a connection is made.

import { config } from "@airdress/functions/config";
import { http, HttpError } from "@airdress/functions/http";

export default async function relay(req: Request): Promise<Response> {
  const target = config.string("target");
  if (!target) {
    return new Response("no target configured", { status: 500 });
  }
  const body = new Uint8Array(await req.arrayBuffer());
  try {
    // Any status is the peer's answer to relay back, so none is an error.
    const upstream = await http.request({
      method: "POST",
      url: target,
      headers: { "content-type": "application/json" },
      body,
      expectOk: false,
      timeoutMs: 3_000,
    });
    return new Response(`upstream ${upstream.status}`, { status: upstream.status });
  } catch (e) {
    // The kind only: an error never carries the body.
    return new Response(`upstream error: ${e instanceof HttpError ? e.kind : "other"}`, {
      status: 502,
    });
  }
}
