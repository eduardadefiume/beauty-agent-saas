import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
};

const ACTION_RPC = {
  list: "site_list_tenants",
  load: "site_load_configuration",
  save: "site_replace_configuration",
  publish: "site_publish_configuration",
} as const;

type Action = keyof typeof ACTION_RPC;

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function safeEqual(left: string, right: string): boolean {
  const encoder = new TextEncoder();
  const leftBytes = encoder.encode(left);
  const rightBytes = encoder.encode(right);
  const size = Math.max(leftBytes.length, rightBytes.length);
  let difference = leftBytes.length ^ rightBytes.length;

  for (let index = 0; index < size; index += 1) {
    difference |= (leftBytes[index] ?? 0) ^ (rightBytes[index] ?? 0);
  }

  return difference === 0;
}

Deno.serve(async (request: Request) => {
  if (request.method !== "POST") {
    return json(405, { error: "METHOD_NOT_ALLOWED" });
  }

  const expectedToken = Deno.env.get("SITE_CONFIGURATOR_TOKEN") ?? "";
  const suppliedToken = request.headers.get("x-sites-backend-token") ?? "";

  if (!expectedToken || !safeEqual(expectedToken, suppliedToken)) {
    return json(401, { error: "UNAUTHORIZED" });
  }

  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > 262_144) {
    return json(413, { error: "PAYLOAD_TOO_LARGE" });
  }

  let input: Record<string, unknown>;
  try {
    input = await request.json();
  } catch {
    return json(400, { error: "INVALID_JSON" });
  }

  const action = input.action;
  const siteProjectId = input.siteProjectId;
  const userEmail = input.userEmail;
  const tenantId = input.tenantId;

  if (
    typeof action !== "string" ||
    !(action in ACTION_RPC) ||
    typeof siteProjectId !== "string" ||
    typeof userEmail !== "string" ||
    userEmail.length > 320
  ) {
    return json(400, { error: "INVALID_REQUEST" });
  }

  if (action !== "list" && typeof tenantId !== "string") {
    return json(400, { error: "TENANT_REQUIRED" });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

  if (!supabaseUrl || !serviceRoleKey) {
    return json(503, { error: "SERVICE_NOT_CONFIGURED" });
  }

  const common = {
    target_site_project_id: siteProjectId,
    target_email: userEmail,
  };
  let rpcBody: Record<string, unknown>;

  switch (action as Action) {
    case "list":
      rpcBody = common;
      break;
    case "load":
      rpcBody = { ...common, target_tenant_id: tenantId };
      break;
    case "save":
      if (
        !Number.isInteger(input.expectedRevision) ||
        typeof input.payload !== "object" ||
        input.payload === null
      ) {
        return json(400, { error: "INVALID_SAVE_REQUEST" });
      }
      rpcBody = {
        ...common,
        target_tenant_id: tenantId,
        expected_revision: input.expectedRevision,
        payload: input.payload,
      };
      break;
    case "publish":
      if (!Number.isInteger(input.expectedRevision)) {
        return json(400, { error: "INVALID_PUBLISH_REQUEST" });
      }
      rpcBody = {
        ...common,
        target_tenant_id: tenantId,
        expected_revision: input.expectedRevision,
        target_correlation_id: crypto.randomUUID(),
      };
      break;
  }

  const response = await fetch(
    `${supabaseUrl}/rest/v1/rpc/${ACTION_RPC[action as Action]}`,
    {
      method: "POST",
      headers: {
        apikey: serviceRoleKey,
        authorization: `Bearer ${serviceRoleKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(rpcBody),
    },
  );

  if (!response.ok) {
    const failure = await response.json().catch(() => ({})) as {
      code?: string;
      message?: string;
    };
    const status =
      failure.code === "42501" ? 403 :
      failure.code === "40001" ? 409 :
      failure.code === "23514" ? 422 :
      response.status >= 400 && response.status < 500 ? response.status : 502;

    return json(status, {
      error: failure.message ?? "DATABASE_REQUEST_FAILED",
      code: failure.code ?? null,
    });
  }

  return json(200, { data: await response.json() });
});
