// supabase/functions/create_employee/index.ts
// ينشئ موظفًا جديدًا داخل حساب معيّن:
// 1) تحقّق أن المستدعي مسجّل دخول ومُفوّض (superAdmin).
// 2) ينشئ مستخدم Auth.
// 3) يربطه بالحساب في account_users.
// 4) يُدرج صفًا في profiles بالـ role=employee (⚠️ مهم لرولز RLS).
// 5) يحدّث app_metadata / user_metadata بـ { account_id, role }.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON_KEY = Deno.env.get("ANON_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SERVICE_ROLE_KEY") ?? "";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    if (req.method !== "POST") {
      return json({ error: "method not allowed" }, 405);
    }

    if (!SUPABASE_URL || !ANON_KEY || !SERVICE_ROLE_KEY) {
      return json({ error: "missing envs" }, 500);
    }

    // مصادقة المستدعي (جلسة التطبيق)
    const authHeader = req.headers.get("Authorization") ?? "";
    const authed = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: userErr } = await authed.auth.getUser();
    if (userErr || !user) return json({ error: "unauthenticated" }, 401);

    // السماح فقط لـ superAdmin (ويُفضّل غير معطّل)
    const service = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: meRole, error: roleErr } = await service
      .from("account_users")
      .select("role, disabled")
      .eq("user_uid", user.id)
      .maybeSingle();

    if (roleErr) throw roleErr;
    const roleValue = String(meRole?.role ?? "");
    if (!meRole || roleValue.toLowerCase() !== "superadmin" || meRole.disabled === true) {
      return json({ error: "forbidden" }, 403);
    }

    // بيانات الإدخال
    const body = await req.json().catch(() => ({} as any));
    const { account_id, email, password } = body as {
      account_id?: string; email?: string; password?: string;
    };
    if (!account_id || !email || !password) {
      return json({ error: "missing fields" }, 400);
    }

    // تحقّق من وجود الحساب وأنه غير مجمّد
    const { data: accountRow, error: accErr } = await service
      .from("accounts")
      .select("id, frozen")
      .eq("id", account_id)
      .maybeSingle();
    if (accErr) throw accErr;
    if (!accountRow) return json({ error: "account not found" }, 404);
    if (accountRow.frozen === true) return json({ error: "account is frozen" }, 409);

    // (1) إنشاء المستخدم عبر Admin API
    const { data: created, error: adminErr } = await service.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    });

    // في حال البريد موجود مسبقًا
    if (adminErr) {
      const msg = adminErr.message ?? String(adminErr);
      if (/already exists|registered/i.test(msg)) {
        return json({ error: "user already exists" }, 409);
      }
      return json({ error: msg }, 400);
    }

    const employeeUid = created.user?.id;
    if (!employeeUid) return json({ error: "createUser returned no id" }, 500);

    // (2) ربطه بالحساب كموظف في account_users
    const { error: linkErr } = await service
      .from("account_users")
      .insert({
        account_id,
        user_uid: employeeUid,
        role: "employee",
        disabled: false,
      });

    if (linkErr) {
      // تراجع عن إنشاء المستخدم إذا فشل الربط
      await service.auth.admin.deleteUser(employeeUid).catch(() => {});
      const msg = linkErr.message ?? String(linkErr);
      const is409 = /duplicate key|unique/i.test(msg);
      return json({ error: msg }, is409 ? 409 : 400);
    }

    // (3) إدراج صف في profiles (⚠️ مهم لعمل RLS)
    const { error: profErr } = await service.from("profiles").insert({
      id: employeeUid,
      role: "employee",
      account_id,
    });
    if (profErr) {
      // تراجع شامل
      await service.from("account_users").delete().match({ account_id, user_uid: employeeUid }).catch(() => {});
      await service.auth.admin.deleteUser(employeeUid).catch(() => {});
      return json({ error: profErr.message ?? "failed to insert profile" }, 500);
    }

    // (4) تحديث ميتاداتا المستخدم ليحمل account_id + role (اختياري لكنه مفيد على العميل)
    await service.auth.admin.updateUserById(employeeUid, {
      app_metadata: { ...(created.user?.app_metadata ?? {}), account_id, role: "employee" },
      user_metadata: { ...(created.user?.user_metadata ?? {}), account_id, role: "employee" },
    }).catch(() => {});

    return json({ ok: true, user_uid: employeeUid });
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    return json({ error: msg }, 500);
  }
});
