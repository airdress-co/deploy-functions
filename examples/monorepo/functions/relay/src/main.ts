// Relay a webhook to another operator: forward the body as a POST and
// answer with the peer's status. The host refuses any URL outside the
// function's granted `http.hosts` before a connection is made.

declare const airdress: { config: { target?: string } };

export default async function relay(req: Request): Promise<Response> {
  const target = airdress.config.target;
  if (!target) {
    return new Response("no target configured", { status: 500 });
  }
  const body = new Uint8Array(await req.arrayBuffer());
  const upstream = await fetch(target, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body,
  });
  return new Response(`upstream ${upstream.status}`, { status: upstream.status });
}
