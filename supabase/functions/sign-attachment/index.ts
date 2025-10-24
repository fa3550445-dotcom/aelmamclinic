// Edge Function: sign-attachment
// يتحقق أن المستخدم مشارك في المحادثة ثم يوقّع مسار ملف من bucket chat-attachments

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY =
  Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SERVICE_ROLE_KEY") ?? "";

const ALLOW_ANY_BUCKET = false;
const CHAT_BUCKET = "chat-attachments";

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: cors });
}

function validatePath(p: string) {
  if (!p || typeof p !== "string") return false;
  if (p.startsWith("/") || p.includes("..")) return false;
  const parts = p.split("/").filter(Boolean);
  // expected: attachments/<conversationId>/<messageId>/<file>
  return parts.length >= 4 && parts.every((s) => s.length > 0);
}

function getConversationIdFromPath(p: string): string | null {
  const parts = p.split("/").filter(Boolean);
  return parts.length >= 2 ? parts[1] : null;
}

serve(async (req) => {
  try {
    if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
    if (req.method !== "POST") return json(405, { error: "Method not allowed" });

    // sanity: envs
    if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !SUPABASE_ANON_KEY) {
      return json(500, {
        error: "Missing function env vars",
        missing: {
          SUPABASE_URL: !!SUPABASE_URL,
          SUPABASE_ANON_KEY: !!SUPABASE_ANON_KEY,
          SUPABASE_SERVICE_ROLE_KEY: !!SUPABASE_SERVICE_ROLE_KEY,
        },
      });
    }

    const authHeader = req.headers.get("Authorization") ?? "";
    const jwt = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : null;
    if (!jwt) return json(401, { error: "Missing Authorization" });

    const { bucket, path, expiresIn } = (await req.json().catch(() => ({}))) as {
      bucket?: string;
      path?: string;
      expiresIn?: number;
    };

    if (!bucket || !path) return json(400, { error: "Missing bucket/path" });
    if (!ALLOW_ANY_BUCKET && bucket !== CHAT_BUCKET)
      return json(403, { error: `Signing is restricted to bucket "${CHAT_BUCKET}"` });
    if (!validatePath(path)) return json(400, { error: "Invalid path format" });

    // user client (RLS-aware)
    const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
    });

    const { data: me, error: meErr } = await userClient.auth.getUser();
    if (meErr || !me?.user?.id) return json(401, { error: "Not authenticated" });
    const uid = me.user.id;

    const convId = getConversationIdFromPath(path);
    if (!convId) return json(400, { error: "Cannot infer conversation_id" });

    // check participant
    const { data: part } = await userClient
      .from("chat_participants")
      .select("conversation_id")
      .eq("conversation_id", convId)
      .eq("user_uid", uid)
      .limit(1)
      .maybeSingle();

    let isSuper = false;
    if (!part) {
      const { data: au } = await userClient
        .from("account_users")
        .select("role")
        .eq("user_uid", uid)
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle();
      isSuper = (au?.role || "").toString().toLowerCase() === "superadmin";
    }
    if (!part && !isSuper) return json(403, { error: "Not allowed to sign this attachment" });

    // admin client (Service Role) for signing
    const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const ttl = Number.isFinite(expiresIn as number)
      ? Math.max(60, Math.min(60 * 60 * 24, Number(expiresIn)))
      : 15 * 60;

    const { data: signed, error: signErr } = await adminClient
      .storage.from(bucket)
      .createSignedUrl(path, ttl);

    if (signErr || !signed?.signedUrl) {
      // أعطِ تلميحًا بدون إفشاء أسرار
      return json(400, { error: "Failed to create signed URL", hint: "check function secrets" });
    }

    return json(200, {
      ok: true,
      bucket,
      path,
      signedUrl: signed.signedUrl, // URL مطلق
      expiresIn: ttl,
    });
  } catch (e) {
    return json(500, { error: "Internal error" });
  }
});
