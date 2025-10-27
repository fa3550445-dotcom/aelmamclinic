// supabase/functions/create_employee/index.ts
// ينشئ موظفًا جديدًا داخل حساب معيّن:
// 1) تحقّق أن المستدعي مسجّل دخول ومُفوّض (سوبر أدمن أو مدير حساب).
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

    // بيانات الإدخال
    const body = await req.json().catch(() => ({} as any));
    const { account_id, email, password } = body as {
      account_id?: string;
      email?: string;
      password?: string | null;
    };
    if (!account_id || !email) {
      return json({ error: "missing fields" }, 400);
    }

    const service = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    // السماح للسوبر أدمن أو مالكي الحساب ومدرائه
    const { data: superFlag, error: superErr } = await authed.rpc("fn_is_super_admin");
    if (superErr) throw superErr;

    let canManage = superFlag === true;
    if (!canManage) {
      const { data: managerRow, error: managerErr } = await service
        .from("account_users")
        .select("role, disabled")
        .eq("account_id", account_id)
        .eq("user_uid", user.id)
        .maybeSingle();
      if (managerErr) throw managerErr;

      const roleValue = String(managerRow?.role ?? "").toLowerCase();
      const allowedRoles = new Set(["owner", "admin", "superadmin"]);
      if (managerRow && allowedRoles.has(roleValue) && managerRow.disabled !== true) {
        canManage = true;
      }
    }

    if (!canManage) {
      return json({ error: "forbidden" }, 403);
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
    const normalizedPassword = typeof password === "string" && password.length >= 6 ? password : null;
    let employeeUid: string | null = null;
    let newlyCreated = false;
    let sourceUser: {
      id?: string;
      app_metadata?: Record<string, unknown>;
      user_metadata?: Record<string, unknown>;
    } | null = null;

    if (normalizedPassword) {
      const { data: created, error: adminErr } = await service.auth.admin.createUser({
        email,
        password: normalizedPassword,
        email_confirm: true,
      });

      if (adminErr) {
        const msg = adminErr.message ?? String(adminErr);
        if (!/already exists|registered/i.test(msg)) {
          return json({ error: msg }, 400);
        }
      } else if (created?.user?.id) {
        employeeUid = created.user.id;
        newlyCreated = true;
        sourceUser = created.user;
      }
    }

    if (!employeeUid) {
      const { data: existing, error: existingErr } = await service.auth.admin.getUserByEmail(email);
      if (existingErr || !existing?.user?.id) {
        if (normalizedPassword) {
          return json({ error: existingErr?.message ?? "failed to reuse employee" }, 409);
        }
        return json({ error: "password required to create new user" }, 400);
      }
      employeeUid = existing.user.id;
      sourceUser = existing.user;
    }

    if (!employeeUid) {
      return json({ error: "failed to resolve employee id" }, 500);
    }

      const { data: existingLink, error: fetchLinkErr } = await service
        .from("account_users")
        .select("role, disabled, email")
        .eq("account_id", account_id)
        .eq("user_uid", employeeUid)
        .maybeSingle();
    if (fetchLinkErr) throw fetchLinkErr;

    let insertedAccountLink = false;
    if (!existingLink) {
      const { error: linkErr } = await service
        .from("account_users")
        .insert({
          account_id,
          user_uid: employeeUid,
          role: "employee",
          disabled: false,
          email,
        });
      if (linkErr) {
        if (newlyCreated) {
          await service.auth.admin.deleteUser(employeeUid).catch(() => {});
        }
        const msg = linkErr.message ?? String(linkErr);
        const is409 = /duplicate key|unique/i.test(msg);
        return json({ error: msg }, is409 ? 409 : 400);
      }
      insertedAccountLink = true;
    } else if (existingLink.disabled === true) {
      const { error: reactivateErr } = await service
        .from("account_users")
        .update({ disabled: false, role: existingLink.role ?? "employee", email })
        .eq("account_id", account_id)
        .eq("user_uid", employeeUid);
      if (reactivateErr) {
        if (newlyCreated) {
          await service.auth.admin.deleteUser(employeeUid).catch(() => {});
        }
        return json({ error: reactivateErr.message ?? "failed to reactivate account user" }, 400);
      }
    } else if (existingLink.email !== email) {
      await service
        .from("account_users")
        .update({ email })
        .eq("account_id", account_id)
        .eq("user_uid", employeeUid)
        .catch(() => {});
    }

    // (3) إدراج أو تحديث صف في profiles (⚠️ مهم لعمل RLS)
    const { error: profErr } = await service.from("profiles").upsert({
      id: employeeUid,
      role: "employee",
      account_id,
    }, { onConflict: "id" });
    if (profErr) {
      if (insertedAccountLink) {
        await service.from("account_users").delete().match({ account_id, user_uid: employeeUid }).catch(() => {});
      }
      if (newlyCreated) {
        await service.auth.admin.deleteUser(employeeUid).catch(() => {});
      }
      return json({ error: profErr.message ?? "failed to upsert profile" }, 500);
    }

    // (4) تحديث ميتاداتا المستخدم ليحمل account_id + role (اختياري لكنه مفيد على العميل)
    const baseAppMeta = sourceUser?.app_metadata ?? {};
    const baseUserMeta = sourceUser?.user_metadata ?? {};
    await service.auth.admin.updateUserById(employeeUid, {
      app_metadata: { ...baseAppMeta, account_id, role: "employee" },
      user_metadata: { ...baseUserMeta, account_id, role: "employee" },
    }).catch(() => {});

    return json({ ok: true, user_uid: employeeUid, reused: newlyCreated ? false : true });
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    return json({ error: msg }, 500);
  }
});
