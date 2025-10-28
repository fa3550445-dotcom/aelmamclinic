// supabase/functions/admin__delete_clinic/index.ts
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { serve } from "jsr:@supabase/functions-js";
import { createClient } from "@supabase/supabase-js";

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

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    if (req.method !== "POST") {
      return json({ ok: false, message: "Method not allowed" }, 405);
    }

    const { account_id, clinicId } =
      (await req.json()) as { account_id?: string; clinicId?: string };
    const target: string | undefined = account_id ?? clinicId;
    if (!target) return json({ ok: false, message: "missing account_id/clinicId" }, 400);

    // مصادقة المستدعي بجلسته (ANON + Authorization)
    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: me, error: meErr } = await userClient.auth.getUser();
    if (meErr || !me?.user) return json({ ok: false, message: "unauthenticated" }, 401);

    if ((me.user.email ?? "").toLowerCase() !== SUPER_ADMIN_EMAIL) {
      return json({ ok: false, message: "not allowed" }, 401);
    }

    // تنفيذ بالحساب الخدمي (Service Role) داخل الوظيفة فقط
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { error } = await admin.from("accounts").delete().eq("id", target);
    if (error) throw error;

    return json({ ok: true });
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    return json({ ok: false, message: msg }, 500);
  }
});
