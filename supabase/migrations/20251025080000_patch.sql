---------------------------
-- 1) إصلاح العروض: security_invoker
---------------------------
ALTER VIEW public.v_chat_last_message                 SET (security_invoker = true);
ALTER VIEW public.v_chat_messages_with_attachments    SET (security_invoker = true);
ALTER VIEW public.v_chat_reads_for_me                 SET (security_invoker = true);
ALTER VIEW public.v_chat_conversations_for_me         SET (security_invoker = true);
ALTER VIEW public.clinics                             SET (security_invoker = true);

---------------------------
-- 2) super_admins: تفعيل RLS + سياسات
---------------------------
ALTER TABLE public.super_admins ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='super_admins' AND policyname='super_admins_select_self'
  ) THEN
    CREATE POLICY super_admins_select_self
    ON public.super_admins
    FOR SELECT
    TO authenticated
    USING (user_uid = auth.uid());
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='super_admins' AND policyname='super_admins_read_service'
  ) THEN
    CREATE POLICY super_admins_read_service
    ON public.super_admins
    FOR SELECT
    TO service_role
    USING (true);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='super_admins' AND policyname='super_admins_write_service'
  ) THEN
    CREATE POLICY super_admins_write_service
    ON public.super_admins
    FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);
  END IF;
END$$;

---------------------------
-- 3) إنشاء جدول account_feature_permissions إن كان مفقودًا
---------------------------
CREATE TABLE IF NOT EXISTS public.account_feature_permissions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id       uuid NOT NULL,
  user_uid         uuid NOT NULL,
  allowed_features text[] NOT NULL DEFAULT '{}',
  can_create       boolean NOT NULL DEFAULT true,
  can_update       boolean NOT NULL DEFAULT true,
  can_delete       boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS account_feature_permissions_uix
  ON public.account_feature_permissions (account_id, user_uid);

-- (اختياري) علاقات مرجعية إن كانت موجودة لديك
-- ALTER TABLE public.account_feature_permissions
--   ADD CONSTRAINT account_feature_permissions_account_fk
--   FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE CASCADE;

ALTER TABLE public.account_feature_permissions ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  -- قراءة المالك/العضو أو السوبر أدمن
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='account_feature_permissions' AND policyname='afp_select_members'
  ) THEN
    CREATE POLICY afp_select_members
    ON public.account_feature_permissions
    FOR SELECT
    TO authenticated
    USING (
      EXISTS (
        SELECT 1 FROM public.account_users au
        WHERE au.account_id = account_feature_permissions.account_id
          AND au.user_uid   = auth.uid()
      )
      OR EXISTS (SELECT 1 FROM public.super_admins sa WHERE sa.user_uid = auth.uid())
    );
  END IF;

  -- كتابة عبر service_role فقط
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='account_feature_permissions' AND policyname='afp_write_service'
  ) THEN
    CREATE POLICY afp_write_service
    ON public.account_feature_permissions
    FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);
  END IF;
END$$;

---------------------------
-- 4) RPCs مطلوبة من الواجهة
---------------------------

-- يعيد الملف الشخصي للحساب الحالي
CREATE OR REPLACE FUNCTION public.my_profile()
RETURNS TABLE (
  user_uid   uuid,
  email      text,
  account_id uuid,
  role       text,
  disabled   boolean
)
LANGUAGE sql
SECURITY INVOKER
STABLE
AS $$
  SELECT u.id,
         u.email,
         au.account_id,
         au.role::text,
         au.disabled
  FROM auth.users u
  JOIN public.account_users au ON au.user_uid = u.id
  WHERE u.id = auth.uid()
  LIMIT 1;
$$;

-- أذونات الميزات للمستخدم داخل حسابه الحالي
CREATE OR REPLACE FUNCTION public.my_feature_permissions()
RETURNS TABLE (
  account_id       uuid,
  allowed_features text[],
  can_create       boolean,
  can_update       boolean,
  can_delete       boolean
)
LANGUAGE sql
SECURITY INVOKER
STABLE
AS $$
  SELECT
    coalesce(afp.account_id, au.account_id) as account_id,
    coalesce(afp.allowed_features, '{}')    as allowed_features,
    coalesce(afp.can_create, true)          as can_create,
    coalesce(afp.can_update, true)          as can_update,
    coalesce(afp.can_delete, true)          as can_delete
  FROM public.account_users au
  LEFT JOIN public.account_feature_permissions afp
    ON afp.account_id = au.account_id AND afp.user_uid = au.user_uid
  WHERE au.user_uid = auth.uid()
  LIMIT 1;
$$;

---------------------------
-- 5) Storage: bucket وسياسات مرفقات الدردشة
---------------------------
INSERT INTO storage.buckets (id, name, public)
VALUES ('chat-attachments','chat-attachments', false)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects' AND policyname='chat_read_by_participants'
  ) THEN
    CREATE POLICY chat_read_by_participants
    ON storage.objects
    FOR SELECT
    TO authenticated
    USING (
      bucket_id = 'chat-attachments'
      AND EXISTS (
        SELECT 1
        FROM public.chat_attachments a
        JOIN public.chat_messages m ON m.id = a.message_id
        JOIN public.chat_participants p ON p.conversation_id = m.conversation_id
        WHERE a.bucket = 'chat-attachments'
          AND a.path   = storage.objects.name
          AND p.user_uid = auth.uid()
      )
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects' AND policyname='chat_write_service_only'
  ) THEN
    CREATE POLICY chat_write_service_only
    ON storage.objects
    FOR ALL
    TO service_role
    USING (bucket_id = 'chat-attachments')
    WITH CHECK (bucket_id = 'chat-attachments');
  END IF;
END$$;

---------------------------
-- 6) نشر Realtime لكل جداول public (تدريجيًا)
---------------------------
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='public' LOOP
    EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE IF NOT EXISTS public.%I', r.tablename);
  END LOOP;
END$$;
