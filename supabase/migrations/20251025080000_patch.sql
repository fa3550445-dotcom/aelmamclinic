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

---------------------------
-- 7) إجراءات مساعدة للإدارة (RPC)
---------------------------

CREATE OR REPLACE FUNCTION public.admin_list_clinics()
RETURNS TABLE (
  id uuid,
  name text,
  frozen boolean,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_email text := lower(coalesce(claims->>'email', ''));
  super_admin_email text := 'aelmam.app@gmail.com';
BEGIN
  IF NOT (fn_is_super_admin() = true OR caller_email = lower(super_admin_email)) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  RETURN QUERY
  SELECT a.id, a.name, a.frozen, a.created_at
  FROM public.accounts a
  ORDER BY a.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_clinics() FROM public;
GRANT EXECUTE ON FUNCTION public.admin_list_clinics() TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_clinic_frozen(
  p_account_id uuid,
  p_frozen boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_email text := lower(coalesce(claims->>'email', ''));
  super_admin_email text := 'aelmam.app@gmail.com';
  updated_id uuid;
BEGIN
  IF p_account_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account_id is required');
  END IF;

  IF NOT (fn_is_super_admin() = true OR caller_email = lower(super_admin_email)) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  UPDATE public.accounts
     SET frozen = coalesce(p_frozen, false)
   WHERE id = p_account_id
   RETURNING id INTO updated_id;

  IF updated_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account not found');
  END IF;

  RETURN jsonb_build_object('ok', true, 'account_id', updated_id::text, 'frozen', coalesce(p_frozen, false));
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_clinic_frozen(uuid, boolean) FROM public;
GRANT EXECUTE ON FUNCTION public.admin_set_clinic_frozen(uuid, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_delete_clinic(
  p_account_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_email text := lower(coalesce(claims->>'email', ''));
  super_admin_email text := 'aelmam.app@gmail.com';
  deleted_id uuid;
BEGIN
  IF p_account_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account_id is required');
  END IF;

  IF NOT (fn_is_super_admin() = true OR caller_email = lower(super_admin_email)) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  DELETE FROM public.accounts
   WHERE id = p_account_id
   RETURNING id INTO deleted_id;

  IF deleted_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account not found');
  END IF;

  RETURN jsonb_build_object('ok', true, 'account_id', deleted_id::text);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_delete_clinic(uuid) FROM public;
GRANT EXECUTE ON FUNCTION public.admin_delete_clinic(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_create_owner_full(
  p_clinic_name text,
  p_owner_email text,
  p_owner_password text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_email text := lower(coalesce(claims->>'email', ''));
  super_admin_email text := 'aelmam.app@gmail.com';
  owner_uid uuid;
  account_id uuid;
BEGIN
  IF coalesce(trim(p_clinic_name), '') = '' OR coalesce(trim(p_owner_email), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'clinic_name and owner_email are required');
  END IF;

  IF NOT (fn_is_super_admin() = true OR caller_email = lower(super_admin_email)) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  SELECT id
    INTO owner_uid
  FROM auth.users
  WHERE lower(email) = lower(p_owner_email)
  ORDER BY created_at DESC
  LIMIT 1;

  IF owner_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'owner user not found');
  END IF;

  INSERT INTO public.accounts(name, frozen)
  VALUES (p_clinic_name, false)
  RETURNING id INTO account_id;

  PERFORM public.admin_attach_employee(account_id, owner_uid, 'owner');

  UPDATE public.account_users au
     SET email = lower(p_owner_email)
   WHERE au.account_id = account_id
     AND au.user_uid = owner_uid;

  RETURN jsonb_build_object('ok', true, 'account_id', account_id::text, 'owner_uid', owner_uid::text);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_create_owner_full(text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.admin_create_owner_full(text, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_create_employee_full(
  p_account uuid,
  p_email text,
  p_password text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub', '')::uuid;
  caller_email text := lower(coalesce(claims->>'email', ''));
  super_admin_email text := 'aelmam.app@gmail.com';
  can_manage boolean;
  employee_uid uuid;
BEGIN
  IF p_account IS NULL OR coalesce(trim(p_email), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account and email are required');
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.account_users au
    WHERE au.account_id = p_account
      AND au.user_uid = caller_uid
      AND au.role IN ('owner', 'admin')
      AND coalesce(au.disabled, false) = false
  ) INTO can_manage;

  IF NOT (fn_is_super_admin() = true OR can_manage OR caller_email = lower(super_admin_email)) THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  SELECT id
    INTO employee_uid
  FROM auth.users
  WHERE lower(email) = lower(p_email)
  ORDER BY created_at DESC
  LIMIT 1;

  IF employee_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'user not found');
  END IF;

  PERFORM public.admin_attach_employee(p_account, employee_uid, 'employee');

  UPDATE public.account_users
     SET email = coalesce(email, lower(p_email))
   WHERE account_id = p_account
     AND user_uid = employee_uid;

  RETURN jsonb_build_object('ok', true, 'account_id', p_account::text, 'user_uid', employee_uid::text);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_create_employee_full(uuid, text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.admin_create_employee_full(uuid, text, text) TO authenticated;
