// index.ts
// Edge Function: admin__create_clinic_owner
// - يتحقق أن المتصل سوبر أدمن
// - يضمن وجود مستخدم للمالك (ينشئه إن لزم)
// - يستدعي RPC: admin_bootstrap_clinic_for_email(clinic_name, owner_email)

import { serve } from "https://deno.land/std@0.223.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type Body = { clinic_name?: string; owner_email?: string; owner_password?: string };

const SUPABASE_URL =
  Deno.env.get("SUPABASE_URL") ?? `https://${Deno.env.get("PROJECT_REF")}.supabase.co`;
const ANON_KEY =
  Deno.env.get("ANON_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_ROLE_KEY =
  Deno.env.get("SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SUPER_ADMIN_EMAIL = (Deno.env.get("SUPER_ADMIN_EMAIL") ?? "").toLowerCase();
const ADMIN_INTERNAL_TOKEN = Deno.env.get("ADMIN_INTERNAL_TOKEN") ?? "";

function json(status: number, payload: unknown) {
  return new Response(JSON.stringify(payload, null, 2), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

serve(async (req) => {
  try {
    // 0) فحص الهيدر الداخلي (للاختبار لو JWT موقّف)
    const internal = req.headers.get("x-admin-internal-token");
    if (internal) {
      if (internal !== ADMIN_INTERNAL_TOKEN || !ADMIN_INTERNAL_TOKEN) {
        return json(401, { error: "bad internal token" });
      }
    }

    // 1) استخرج Authorization إن وجد
    const auth = req.headers.get("authorization") ?? "";
    const hasBearer = /^bearer /i.test(auth);

    // 2) أنشئ كلايينتات
    const userClient = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: auth } },
    });
    const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    // 3) تحقق أن المتصل سوبر أدمن
    if (!internal) {
      if (!hasBearer) return json(401, { error: "missing bearer" });

      const { data: ures, error: uerr } = await userClient.auth.getUser();
      if (uerr || !ures?.user) return json(401, { error: "invalid jwt", details: uerr?.message });

      // طريقتان: بالبريد أو بعضوية الجدول
      const userEmail = (ures.user.email ?? "").toLowerCase();

      let isSuper = false;
      if (SUPER_ADMIN_EMAIL && userEmail === SUPER_ADMIN_EMAIL) {
        isSuper = true;
      } else {
        const { data: rows, error: qerr } = await adminClient
          .from("super_admins")
          .select("user_uid")
          .eq("user_uid", ures.user.id)
          .limit(1);
        if (qerr) return json(500, { error: "superadmins query failed", details: qerr.message });
        isSuper = (rows?.length ?? 0) > 0;
      }
      if (!isSuper) return json(403, { error: "not a super admin" });
    }

    // 4) جسد الطلب
    const body = (await req.json().catch(() => ({}))) as Body;
    const clinic_name = (body.clinic_name ?? "").trim();
    const owner_email = (body.owner_email ?? "").trim().toLowerCase();
    const owner_password = (body.owner_password ?? "").trim();

    if (!clinic_name || !owner_email) {
      return json(400, { error: "clinic_name and owner_email are required" });
    }

    // 5) ضَمَنْ وجود المستخدم (إن لم يوجد، أنشئه)
    //    نحاول createUser؛ إن كان موجودًا أصلًا نتجاهل الخطأ ونكمل.
    if (!SERVICE_ROLE_KEY) return json(500, { error: "missing SERVICE_ROLE_KEY env" });

    const { data: cu, error: cuerr } = await adminClient.auth.admin.createUser({
      email: owner_email,
      password: owner_password || crypto.randomUUID(),
      email_confirm: true,
    });

    if (cuerr) {
      // إذا كان المستخدم موجودًا، نتجاهل، وإلا نعيد الخطأ.
      const msg = cuerr.message?.toLowerCase() ?? "";
      const already =
        msg.includes("already registered") ||
        msg.includes("user already exists") ||
        msg.includes("duplicate");
      if (!already) {
        return json(500, { error: "createUser failed", details: cuerr.message });
      }
    }

    // 6) نادِ الـ RPC المسؤول عن bootstrap
    //   ملاحظة: تعتمد على أسماء المعاملات في الدالة في DB (clinic_name, owner_email).
    const { data: rpc, error: rerr } = await adminClient.rpc(
      "admin_bootstrap_clinic_for_email",
      { clinic_name, owner_email },
    );

    if (rerr) {
      return json(500, { error: "rpc admin_bootstrap_clinic_for_email failed", details: rerr.message });
    }

    return json(200, { ok: true, result: rpc });
  } catch (e) {
    return json(500, { error: `${e}` });
  }
});
