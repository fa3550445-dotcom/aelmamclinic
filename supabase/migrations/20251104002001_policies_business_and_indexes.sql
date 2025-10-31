-- أ) تفعيل RLS + سياسات عضوية على employees
ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='employees' AND policyname='employees_select_by_membership'
  ) THEN
    CREATE POLICY employees_select_by_membership
    ON public.employees
    FOR SELECT TO authenticated
    USING (
      public.fn_is_super_admin() = true OR EXISTS (
        SELECT 1 FROM public.account_users au
        WHERE au.account_id = employees.account_id
          AND au.user_uid = auth.uid()
          AND COALESCE(au.disabled,false) = false
      )
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='employees' AND policyname='employees_write_by_owner_or_super'
  ) THEN
    CREATE POLICY employees_write_by_owner_or_super
    ON public.employees
    FOR ALL TO authenticated
    USING (
      public.fn_is_super_admin() = true OR EXISTS (
        SELECT 1 FROM public.account_users au
        WHERE au.account_id = employees.account_id
          AND au.user_uid = auth.uid()
          AND lower(au.role) IN ('owner','admin')
          AND COALESCE(au.disabled,false) = false
      )
    )
    WITH CHECK (
      public.fn_is_super_admin() = true OR EXISTS (
        SELECT 1 FROM public.account_users au
        WHERE au.account_id = employees.account_id
          AND au.user_uid = auth.uid()
          AND lower(au.role) IN ('owner','admin')
          AND COALESCE(au.disabled,false) = false
      )
    );
  END IF;
END$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.employees TO authenticated;

CREATE UNIQUE INDEX IF NOT EXISTS employees_uix_account_device_local
  ON public.employees(account_id, device_id, local_id)
  WHERE account_id IS NOT NULL AND device_id IS NOT NULL AND local_id IS NOT NULL;

-- ب) تفعيل RLS + سياسات عضوية على doctors
ALTER TABLE public.doctors ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='doctors' AND policyname='doctors_select_by_membership'
  ) THEN
    CREATE POLICY doctors_select_by_membership
    ON public.doctors
    FOR SELECT TO authenticated
    USING (
      public.fn_is_super_admin() = true OR EXISTS (
        SELECT 1 FROM public.account_users au
        WHERE au.account_id = doctors.account_id
          AND au.user_uid = auth.uid()
          AND COALESCE(au.disabled,false) = false
      )
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='doctors' AND policyname='doctors_write_by_owner_or_super'
  ) THEN
    CREATE POLICY doctors_write_by_owner_or_super
    ON public.doctors
    FOR ALL TO authenticated
    USING (
      public.fn_is_super_admin() = true OR EXISTS (
        SELECT 1 FROM public.account_users au
        WHERE au.account_id = doctors.account_id
          AND au.user_uid = auth.uid()
          AND lower(au.role) IN ('owner','admin')
          AND COALESCE(au.disabled,false) = false
      )
    )
    WITH CHECK (
      public.fn_is_super_admin() = true OR EXISTS (
        SELECT 1 FROM public.account_users au
        WHERE au.account_id = doctors.account_id
          AND au.user_uid = auth.uid()
          AND lower(au.role) IN ('owner','admin')
          AND COALESCE(au.disabled,false) = false
      )
    );
  END IF;
END$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.doctors TO authenticated;

CREATE UNIQUE INDEX IF NOT EXISTS doctors_uix_account_device_local
  ON public.doctors(account_id, device_id, local_id)
  WHERE account_id IS NOT NULL AND device_id IS NOT NULL AND local_id IS NOT NULL;

-- ج) FK اختياري لتحسين الدقة في الدردشة
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname='chat_messages_patient_fk' AND conrelid='public.chat_messages'::regclass
  ) THEN
    ALTER TABLE public.chat_messages
      ADD CONSTRAINT chat_messages_patient_fk
      FOREIGN KEY (patient_id)
      REFERENCES public.patients(id)
      ON DELETE SET NULL;
  END IF;
END$$;

-- د) تأكيد security_invoker على View العيادات (clinics) إن لم يكن مضبوطًا
DO $$
BEGIN
  PERFORM 1
  FROM pg_views
  WHERE schemaname='public' AND viewname='clinics';
  IF FOUND THEN
    ALTER VIEW public.clinics SET (security_invoker = true);
  END IF;
END$$;
