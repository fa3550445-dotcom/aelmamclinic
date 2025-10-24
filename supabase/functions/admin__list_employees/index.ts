// supabase/functions/admin__list_employees/index.ts
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("ANON_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SERVICE_ROLE_KEY") ?? "";
if (!SERVICE_ROLE_KEY) throw new Error("Missing SUPABASE_SERVICE_ROLE_KEY / SERVICE_ROLE_KEY env");
const SUPER_ADMIN_EMAIL = (Deno.env.get("SUPER_ADMIN_EMAIL") ?? "aelmam.app@gmail.com").toLowerCase();

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    if (req.method !== "POST") {
      return json({ ok: false, message: "Method not allowed" }, 405);
    }

    const { account_id } = await req.json();
    if (!account_id) return json({ ok: false, message: "missing account_id" }, 400);

    // مصادقة المستدعي
    const authed = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: me, error: meErr } = await authed.auth.getUser();
    if (meErr || !me?.user) return json({ ok: false, message: "unauthenticated" }, 401);

    const email = (me.user.email ?? "").toLowerCase();

    // السماحية: سوبر أدمن أو Owner/Admin على الحساب وغير معطّل
    let allowed = email === SUPER_ADMIN_EMAIL;
    if (!allowed) {
      const { data: membership } = await authed
        .from("account_users")
        .select("role, disabled")
        .eq("account_id", account_id)
        .eq("user_uid", me.user.id)
        .in("role", ["owner", "admin"])
        .maybeSingle();
      allowed = !!membership && membership.disabled !== true;
    }

    if (!allowed) return json({ ok: false, message: "forbidden" }, 403);

    // الأفضل: عبر RPC (يحترم RLS ويُعيد البريد)
    const { data: viaRpc, error: rpcErr } = await authed.rpc("list_employees_with_email", {
      p_account: account_id,
    });

    if (!rpcErr && Array.isArray(viaRpc)) {
      // توحيد المخرجات
      const out = viaRpc.map((r: any) => ({
        uid: r.user_uid,
        email: r.email ?? "",
        role: r.role ?? "",
        disabled: !!r.disabled,
        created_at: r.created_at ?? null,
      }));
      // ترتيب بسيط
      out.sort((a, b) => a.email.toLowerCase().localeCompare(b.email.toLowerCase()));
      return json(out, 200);
    }

    // Fallback (يتطلّب Service Role): جمع emails يدويًا
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: rows, error } = await admin
      .from("account_users")
      .select("user_uid, role, disabled, created_at")
      .eq("account_id", account_id);

    if (error) throw error;

    const { data: list } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
    const emails = new Map<string, string>();
    for (const u of list?.users ?? []) {
      if (u?.id && u?.email) emails.set(u.id, String(u.email));
    }

    const out = (rows ?? [])
      .map((r: any) => ({
        uid: r.user_uid,
        email: emails.get(r.user_uid) ?? "",
        role: r.role ?? "",
        disabled: !!r.disabled,
        created_at: r.created_at ?? null,
      }))
      .filter((x) => x.uid);

    out.sort((a, b) => a.email.toLowerCase().localeCompare(b.email.toLowerCase()));
    return json(out, 200);
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    return json({ ok: false, message: msg }, 500);
  }
});
