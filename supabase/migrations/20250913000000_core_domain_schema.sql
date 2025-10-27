-- 20250922090000_core_domain_schema.sql
-- يزيد من اكتمال مخطط Supabase ليواكب نماذج/مزامنة التطبيق.
-- يعتمد على بنية تماثل ما يستخدمه التطبيق محليًا (parity v3) مع أعمدة triplet.

-- تجهيزات عامة ---------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- حسابات العيادات ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  frozen boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.accounts IS 'عيادات/حسابات التطبيق';

CREATE TABLE IF NOT EXISTS public.super_admins (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  account_id uuid,
  device_id text,
  local_id bigint,
  email text UNIQUE,
  user_uid uuid UNIQUE
);

CREATE TABLE IF NOT EXISTS public.account_users (
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  user_uid uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'employee',
  disabled boolean NOT NULL DEFAULT false,
  email text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT '',
  local_id bigint,
  PRIMARY KEY (account_id, user_uid)
);
CREATE INDEX IF NOT EXISTS account_users_account_idx ON public.account_users(account_id);
CREATE INDEX IF NOT EXISTS account_users_user_idx ON public.account_users(user_uid);
CREATE INDEX IF NOT EXISTS account_users_role_idx ON public.account_users(role);

-- سجلات التدقيق ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id uuid,
  actor_uid uuid,
  actor_email text,
  table_name text,
  op text,
  row_pk text,
  before_row jsonb,
  after_row jsonb,
  diff jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS audit_logs_account_created_idx
  ON public.audit_logs(account_id, created_at);
CREATE INDEX IF NOT EXISTS audit_logs_table_name_idx
  ON public.audit_logs(table_name);

-- الجداول التشغيلية ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.patients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  device_id text NOT NULL DEFAULT '',
  name text,
  age smallint,
  diagnosis text,
  phone_number text,
  register_date date,
  paid_amount numeric NOT NULL DEFAULT 0,
  remaining numeric NOT NULL DEFAULT 0,
  health_status text,
  notes text,
  preferences text,
  doctor_id uuid,
  doctor_name text,
  doctor_specialization text,
  service_type text,
  service_id uuid,
  service_name text,
  service_cost numeric,
  doctor_share numeric NOT NULL DEFAULT 0,
  doctor_input numeric NOT NULL DEFAULT 0,
  tower_share numeric NOT NULL DEFAULT 0,
  department_share numeric NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  is_deleted boolean NOT NULL DEFAULT false
);

CREATE TABLE IF NOT EXISTS public.returns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  date timestamptz,
  patient_name text,
  phone_number text,
  diagnosis text,
  remaining double precision,
  age integer,
  doctor text,
  notes text,
  device_id text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.consumptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  patient_id text,
  item_id text,
  quantity integer,
  date timestamptz,
  amount double precision,
  note text,
  device_id text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.drugs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  name text NOT NULL,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uix_drugs_account_lower_name
  ON public.drugs(account_id, lower(name));

CREATE TABLE IF NOT EXISTS public.complaints (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  title text,
  description text,
  status text,
  created_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.appointments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  patient_id uuid REFERENCES public.patients(id),
  appointment_time timestamptz,
  status text,
  notes text,
  device_id text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.consumption_types (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  type text,
  device_id text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.medical_services (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  name text,
  cost double precision,
  service_type text,
  device_id text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.employees (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  name text,
  identity_number text,
  phone_number text,
  job_title text,
  address text,
  marital_status text,
  basic_salary double precision,
  final_salary double precision,
  is_doctor boolean,
  device_id text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.doctors (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  employee_id uuid REFERENCES public.employees(id),
  name text,
  specialization text,
  phone_number text,
  start_time timestamptz,
  end_time timestamptz,
  print_counter integer,
  device_id text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.prescriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  patient_id uuid REFERENCES public.patients(id) ON DELETE CASCADE,
  doctor_id uuid REFERENCES public.doctors(id),
  record_date timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.prescription_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  prescription_id uuid REFERENCES public.prescriptions(id) ON DELETE CASCADE,
  drug_id uuid REFERENCES public.drugs(id),
  days integer,
  times_per_day integer,
  device_id text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.service_doctor_share (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  service_id uuid REFERENCES public.medical_services(id) ON DELETE CASCADE,
  doctor_id uuid REFERENCES public.doctors(id) ON DELETE CASCADE,
  share_percentage double precision,
  tower_share_percentage double precision,
  is_hidden boolean,
  device_id text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS service_doctor_share_unique
  ON public.service_doctor_share(account_id, service_id, doctor_id);

CREATE TABLE IF NOT EXISTS public.employees_loans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  employee_id uuid REFERENCES public.employees(id) ON DELETE CASCADE,
  loan_date_time timestamptz,
  final_salary double precision,
  ratio_sum double precision,
  loan_amount double precision,
  leftover double precision,
  device_id text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.employees_salaries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  employee_id uuid REFERENCES public.employees(id) ON DELETE CASCADE,
  year integer,
  month integer,
  final_salary double precision,
  ratio_sum double precision,
  total_loans double precision,
  net_pay double precision,
  is_paid boolean,
  payment_date timestamptz,
  device_id text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.employees_discounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  employee_id uuid REFERENCES public.employees(id) ON DELETE CASCADE,
  discount_date_time timestamptz,
  amount double precision,
  notes text,
  device_id text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.item_types (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  name text,
  device_id text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS item_types_unique_name
  ON public.item_types(account_id, lower(name));

CREATE TABLE IF NOT EXISTS public.items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  type_id uuid REFERENCES public.item_types(id) ON DELETE SET NULL,
  name text,
  stock double precision,
  price double precision,
  created_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS items_unique_type_name
  ON public.items(account_id, type_id, lower(name));

CREATE TABLE IF NOT EXISTS public.purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  date timestamptz,
  item_id uuid REFERENCES public.items(id) ON DELETE SET NULL,
  quantity integer,
  total double precision,
  created_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.alert_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  item_id uuid REFERENCES public.items(id) ON DELETE SET NULL,
  threshold double precision,
  notify_time timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  device_id text NOT NULL DEFAULT '',
  is_enabled boolean NOT NULL DEFAULT true,
  last_triggered timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.financial_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  transaction_type text,
  operation text,
  amount double precision,
  employee_id text,
  description text,
  modification_details text,
  "timestamp" timestamptz,
  device_id text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.patient_services (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  local_id bigint,
  patient_id uuid REFERENCES public.patients(id) ON DELETE CASCADE,
  service_id uuid REFERENCES public.medical_services(id) ON DELETE SET NULL,
  device_id text NOT NULL DEFAULT '',
  service_name text NOT NULL DEFAULT '',
  service_cost numeric NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- صلاحيات الميزات لكل موظف ---------------------------------------------------
CREATE TABLE IF NOT EXISTS public.account_feature_permissions (
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  user_uid uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  allowed_features text[] NOT NULL DEFAULT ARRAY[]::text[],
  can_create boolean NOT NULL DEFAULT true,
  can_update boolean NOT NULL DEFAULT true,
  can_delete boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, user_uid)
);
CREATE INDEX IF NOT EXISTS account_feature_permissions_account_idx
  ON public.account_feature_permissions(account_id);

-- جدول سجلات التدقيق ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  actor_uid uuid,
  actor_email text,
  table_name text NOT NULL,
  op text NOT NULL,
  row_pk text,
  before_row jsonb,
  after_row jsonb,
  diff jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS audit_logs_account_created_idx
  ON public.audit_logs(account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS audit_logs_table_idx
  ON public.audit_logs(table_name);

-- الفهارس العامة على triplet --------------------------------------------------
DO $$
DECLARE
  tbl text;
BEGIN
  FOR tbl IN SELECT unnest(ARRAY[
    'patients','returns','consumptions','drugs','prescriptions','prescription_items',
    'complaints','appointments','doctors','consumption_types','medical_services',
    'service_doctor_share','employees','employees_loans','employees_salaries',
    'employees_discounts','item_types','items','purchases','alert_settings',
    'financial_logs','patient_services','account_users','super_admins'
  ]) LOOP
    EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS %I_account_device_local_idx ON public.%I (account_id, device_id, local_id)', tbl, tbl);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I_account_idx ON public.%I (account_id)', tbl, tbl);
  END LOOP;
END $$;

-- دالة تعيين updated_at -------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- تجهيز تريغر سجلات التدقيق --------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_audit_logs_set_created_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.created_at = COALESCE(NEW.created_at, now());
  END IF;
  -- TODO: إرفاق تسجيل العمليات التفصيلي عند تجهيز نظام التدقيق الكامل.
  RETURN NEW;
END;
$$;

DO $$
DECLARE
  tbl text;
BEGIN
  FOR tbl IN SELECT unnest(ARRAY[
    'account_users','account_feature_permissions','patients','returns','consumptions','drugs','prescriptions','prescription_items',
    'complaints','appointments','doctors','consumption_types','medical_services',
    'service_doctor_share','employees','employees_loans','employees_salaries',
    'employees_discounts','item_types','items','purchases','alert_settings',
    'financial_logs','patient_services'
  ]) LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I_set_updated_at ON public.%I', tbl, tbl);
    EXECUTE format('CREATE TRIGGER %I_set_updated_at BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at()', tbl, tbl);
  END LOOP;
END $$;

DROP TRIGGER IF EXISTS account_feature_permissions_set_updated_at
  ON public.account_feature_permissions;
CREATE TRIGGER account_feature_permissions_set_updated_at
BEFORE UPDATE ON public.account_feature_permissions
FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at();

-- تمكين الصلاحيات و RLS ------------------------------------------------------
DO $$
DECLARE
  tbl text;
BEGIN
  FOR tbl IN SELECT unnest(ARRAY[
    'patients','returns','consumptions','drugs','prescriptions','prescription_items',
    'complaints','appointments','doctors','consumption_types','medical_services',
    'service_doctor_share','employees','employees_loans','employees_salaries',
    'employees_discounts','item_types','items','purchases','alert_settings',
    'financial_logs','patient_services'
  ]) LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', tbl);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', tbl);
  END LOOP;
END $$;

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.audit_logs TO authenticated;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='audit_logs' AND policyname='audit_logs_select'
  ) THEN
    CREATE POLICY audit_logs_select ON public.audit_logs
      FOR SELECT TO authenticated
      USING (
        fn_is_super_admin() = true OR (
          audit_logs.account_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.account_users au
            WHERE au.account_id = audit_logs.account_id
              AND au.user_uid::text = auth.uid()::text
              AND au.disabled IS NOT TRUE
          )
        )
      );
  END IF;
END $$;

ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_users ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.accounts TO authenticated;
GRANT SELECT ON public.account_users TO authenticated;

ALTER TABLE public.account_feature_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.account_feature_permissions TO authenticated;
GRANT SELECT ON public.audit_logs TO authenticated;

DO $$
DECLARE
  tbl text;
  policy text;
  cond text;
  cond_template constant text := 'fn_is_super_admin() = true OR EXISTS (SELECT 1 FROM public.account_users au WHERE au.account_id = %I.account_id AND au.user_uid::text = auth.uid()::text AND au.disabled IS NOT TRUE)';
BEGIN
  FOR tbl IN SELECT unnest(ARRAY[
    'patients','returns','consumptions','drugs','prescriptions','prescription_items',
    'complaints','appointments','doctors','consumption_types','medical_services',
    'service_doctor_share','employees','employees_loans','employees_salaries',
    'employees_discounts','item_types','items','purchases','alert_settings',
    'financial_logs','patient_services'
  ]) LOOP
    cond := format(cond_template, tbl);
    policy := tbl || '_select_own';
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename=tbl AND policyname=policy
    ) THEN
      EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT USING (' || cond || ')', policy, tbl, tbl);
    END IF;

    policy := tbl || '_insert_own';
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename=tbl AND policyname=policy
    ) THEN
      EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT WITH CHECK (' || cond || ')', policy, tbl, tbl);
    END IF;

    policy := tbl || '_update_own';
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename=tbl AND policyname=policy
    ) THEN
      EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE USING (' || cond || ') WITH CHECK (' || cond || ')', policy, tbl, tbl);
    END IF;

    policy := tbl || '_delete_own';
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename=tbl AND policyname=policy
    ) THEN
      EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE USING (' || cond || ')', policy, tbl, tbl);
    END IF;
  END LOOP;
END $$;

-- RLS خاصة بالحسابات/المستخدمين ---------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='accounts' AND policyname='accounts_select'
  ) THEN
    CREATE POLICY accounts_select ON public.accounts
    FOR SELECT TO authenticated
    USING (
      fn_is_super_admin() = true OR EXISTS (
        SELECT 1 FROM public.account_users au
        WHERE au.account_id = accounts.id
          AND au.user_uid::text = auth.uid()::text
          AND au.disabled IS NOT TRUE
      )
    );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='account_users' AND policyname='account_users_select'
  ) THEN
    CREATE POLICY account_users_select ON public.account_users
    FOR SELECT TO authenticated
    USING (
      fn_is_super_admin() = true OR account_users.user_uid::text = auth.uid()::text
      OR EXISTS (
        SELECT 1 FROM public.account_users au
        WHERE au.account_id = account_users.account_id
          AND au.user_uid::text = auth.uid()::text
          AND au.disabled IS NOT TRUE
      )
    );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='account_feature_permissions' AND policyname='account_feature_permissions_select'
  ) THEN
    CREATE POLICY account_feature_permissions_select ON public.account_feature_permissions
      FOR SELECT TO authenticated
      USING (
        fn_is_super_admin() = true
        OR user_uid::text = auth.uid()::text
        OR EXISTS (
          SELECT 1 FROM public.account_users au
          WHERE au.account_id = account_feature_permissions.account_id
            AND au.user_uid::text = auth.uid()::text
            AND coalesce(au.disabled, false) = false
            AND lower(coalesce(au.role,'')) IN ('owner','admin','superadmin')
        )
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='account_feature_permissions' AND policyname='account_feature_permissions_insert'
  ) THEN
    CREATE POLICY account_feature_permissions_insert ON public.account_feature_permissions
      FOR INSERT TO authenticated
      WITH CHECK (
        fn_is_super_admin() = true
        OR EXISTS (
          SELECT 1 FROM public.account_users au
          WHERE au.account_id = account_feature_permissions.account_id
            AND au.user_uid::text = auth.uid()::text
            AND coalesce(au.disabled, false) = false
            AND lower(coalesce(au.role,'')) IN ('owner','admin','superadmin')
        )
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='account_feature_permissions' AND policyname='account_feature_permissions_update'
  ) THEN
    CREATE POLICY account_feature_permissions_update ON public.account_feature_permissions
      FOR UPDATE TO authenticated
      USING (
        fn_is_super_admin() = true
        OR EXISTS (
          SELECT 1 FROM public.account_users au
          WHERE au.account_id = account_feature_permissions.account_id
            AND au.user_uid::text = auth.uid()::text
            AND coalesce(au.disabled, false) = false
            AND lower(coalesce(au.role,'')) IN ('owner','admin','superadmin')
        )
      )
      WITH CHECK (
        fn_is_super_admin() = true
        OR EXISTS (
          SELECT 1 FROM public.account_users au
          WHERE au.account_id = account_feature_permissions.account_id
            AND au.user_uid::text = auth.uid()::text
            AND coalesce(au.disabled, false) = false
            AND lower(coalesce(au.role,'')) IN ('owner','admin','superadmin')
        )
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='account_feature_permissions' AND policyname='account_feature_permissions_delete'
  ) THEN
    CREATE POLICY account_feature_permissions_delete ON public.account_feature_permissions
      FOR DELETE TO authenticated
      USING (
        fn_is_super_admin() = true
        OR EXISTS (
          SELECT 1 FROM public.account_users au
          WHERE au.account_id = account_feature_permissions.account_id
            AND au.user_uid::text = auth.uid()::text
            AND coalesce(au.disabled, false) = false
            AND lower(coalesce(au.role,'')) IN ('owner','admin','superadmin')
        )
      );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='audit_logs' AND policyname='audit_logs_select_admins'
  ) THEN
    CREATE POLICY audit_logs_select_admins ON public.audit_logs
      FOR SELECT TO authenticated
      USING (
        fn_is_super_admin() = true
        OR EXISTS (
          SELECT 1 FROM public.account_users au
          WHERE au.account_id = audit_logs.account_id
            AND au.user_uid::text = auth.uid()::text
            AND coalesce(au.disabled, false) = false
            AND lower(coalesce(au.role,'')) IN ('owner','admin','superadmin')
        )
      );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='account_users' AND policyname='account_users_mutate'
  ) THEN
    CREATE POLICY account_users_mutate ON public.account_users
    FOR ALL TO authenticated
    USING (fn_is_super_admin() = true)
    WITH CHECK (fn_is_super_admin() = true);
  END IF;
END $$;

-- عرض clinics ---------------------------------------------------------------
CREATE OR REPLACE VIEW public.clinics AS
SELECT id, name, frozen, created_at
FROM public.accounts;

DO $do$
BEGIN
  EXECUTE $$
    CREATE OR REPLACE FUNCTION public.admin_attach_employee(p_account uuid, p_user_uid uuid, p_role text DEFAULT 'employee')
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = public
    AS $func$
    DECLARE
      exists_row boolean;
      caller_can_manage boolean;
    BEGIN
      IF p_account IS NULL OR p_user_uid IS NULL THEN
        RAISE EXCEPTION 'account_id and user_uid are required';
      END IF;

      IF fn_is_super_admin() = false THEN
        SELECT EXISTS (
                 SELECT 1
                   FROM public.account_users au
                  WHERE au.account_id = p_account
                    AND au.user_uid::text = auth.uid()::text
                    AND COALESCE(au.disabled, false) = false
                    AND lower(COALESCE(au.role, '')) = 'owner'
               )
          INTO caller_can_manage;

        IF NOT COALESCE(caller_can_manage, false) THEN
          RAISE EXCEPTION 'insufficient privileges to manage employees for this account'
            USING ERRCODE = '42501';
        END IF;
      END IF;

      SELECT true INTO exists_row
      FROM public.account_users
      WHERE account_id = p_account
        AND user_uid = p_user_uid
      LIMIT 1;

      IF NOT COALESCE(exists_row, false) THEN
        INSERT INTO public.account_users(account_id, user_uid, role, disabled)
        VALUES (p_account, p_user_uid, COALESCE(p_role, 'employee'), false);
      ELSE
        UPDATE public.account_users
           SET disabled = false,
               role = COALESCE(p_role, role),
               updated_at = now()
         WHERE account_id = p_account
           AND user_uid = p_user_uid;
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'profiles'
      ) THEN
        INSERT INTO public.profiles(id, account_id, role, created_at)
        VALUES (p_user_uid, p_account, COALESCE(p_role, 'employee'), now())
        ON CONFLICT (id) DO UPDATE
            SET account_id = EXCLUDED.account_id,
                role = EXCLUDED.role;
      END IF;
    END;
    $func$;
  $$;

  EXECUTE 'REVOKE ALL ON FUNCTION public.admin_attach_employee(uuid, uuid, text) FROM PUBLIC';
  EXECUTE 'REVOKE ALL ON FUNCTION public.admin_attach_employee(uuid, uuid, text) FROM anon';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_attach_employee(uuid, uuid, text) TO authenticated';
  EXECUTE 'GRANT EXECUTE ON FUNCTION public.admin_attach_employee(uuid, uuid, text) TO service_role';
END;
$do$;

CREATE OR REPLACE FUNCTION public.admin_bootstrap_clinic_for_email(clinic_name text, owner_email text, owner_role text DEFAULT 'owner')
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  owner_uid uuid;
  acc_id uuid;
BEGIN
  IF fn_is_super_admin() = false THEN
    RAISE EXCEPTION 'not allowed';
  END IF;

  IF clinic_name IS NULL OR length(trim(clinic_name)) = 0 THEN
    RAISE EXCEPTION 'clinic_name is required';
  END IF;

  IF owner_email IS NULL OR length(trim(owner_email)) = 0 THEN
    RAISE EXCEPTION 'owner_email is required';
  END IF;

  SELECT id INTO owner_uid
  FROM auth.users
  WHERE lower(email) = lower(owner_email)
  ORDER BY created_at DESC
  LIMIT 1;

  IF owner_uid IS NULL THEN
    RAISE EXCEPTION 'owner with email % not found in auth.users', owner_email;
  END IF;

  INSERT INTO public.accounts(name, frozen)
  VALUES (clinic_name, false)
  RETURNING id INTO acc_id;

  PERFORM public.admin_attach_employee(acc_id, owner_uid, COALESCE(owner_role, 'owner'));

  RETURN acc_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_bootstrap_clinic_for_email(text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_attach_employee(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_bootstrap_clinic_for_email(text, text, text) TO authenticated;

-- RPC مساعدة لإدارة الهوية والحسابات -----------------------------------------
CREATE OR REPLACE FUNCTION public.my_profile()
RETURNS TABLE (
  account_id uuid,
  role text,
  email text,
  is_super_admin boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text;
  v_account uuid;
  v_role text;
BEGIN
  IF v_uid IS NULL THEN
    RETURN;
  END IF;

  SELECT u.email INTO v_email
  FROM auth.users u
  WHERE u.id = v_uid;

  SELECT p.account_id, p.role
    INTO v_account, v_role
  FROM public.profiles p
  WHERE p.id = v_uid
  LIMIT 1;

  IF v_account IS NULL OR v_role IS NULL THEN
    SELECT au.account_id, au.role
      INTO v_account, v_role
    FROM public.account_users au
    WHERE au.user_uid = v_uid
      AND coalesce(au.disabled, false) = false
    ORDER BY au.created_at DESC NULLS LAST
    LIMIT 1;
  END IF;

  IF v_role IS NULL AND fn_is_super_admin() THEN
    v_role := 'superadmin';
  END IF;

  RETURN QUERY
  SELECT v_account,
         v_role,
         v_email,
         fn_is_super_admin();
END;
$$;

GRANT EXECUTE ON FUNCTION public.my_profile() TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_profile() TO service_role;

CREATE OR REPLACE FUNCTION public.my_feature_permissions(p_account uuid)
RETURNS TABLE (
  account_id uuid,
  user_uid uuid,
  allowed_features text[],
  can_create boolean,
  can_update boolean,
  can_delete boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_account uuid := p_account;
  v_allowed text[];
  v_can_create boolean := true;
  v_can_update boolean := true;
  v_can_delete boolean := true;
BEGIN
  IF v_uid IS NULL THEN
    RETURN;
  END IF;

  IF v_account IS NULL THEN
    SELECT au.account_id
      INTO v_account
    FROM public.account_users au
    WHERE au.user_uid = v_uid
      AND coalesce(au.disabled, false) = false
    ORDER BY au.created_at DESC NULLS LAST
    LIMIT 1;
  END IF;

  IF v_account IS NULL THEN
    RETURN QUERY SELECT NULL::uuid, v_uid, ARRAY[]::text[], true, true, true;
    RETURN;
  END IF;

  IF fn_is_super_admin() = false THEN
    PERFORM 1
    FROM public.account_users au
    WHERE au.account_id = v_account
      AND au.user_uid = v_uid
      AND coalesce(au.disabled, false) = false;

    IF NOT FOUND THEN
      RETURN QUERY SELECT v_account, v_uid, ARRAY[]::text[], true, true, true;
      RETURN;
    END IF;
  END IF;

  SELECT afp.allowed_features,
         afp.can_create,
         afp.can_update,
         afp.can_delete
    INTO v_allowed, v_can_create, v_can_update, v_can_delete
  FROM public.account_feature_permissions afp
  WHERE afp.account_id = v_account
    AND afp.user_uid = v_uid
  LIMIT 1;

  RETURN QUERY SELECT v_account,
                         v_uid,
                         coalesce(v_allowed, ARRAY[]::text[]),
                         coalesce(v_can_create, true),
                         coalesce(v_can_update, true),
                         coalesce(v_can_delete, true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.my_feature_permissions(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_feature_permissions(uuid) TO service_role;

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
  v_clinic text := nullif(trim(p_clinic_name), '');
  v_email text := nullif(lower(trim(p_owner_email)), '');
  v_uid uuid;
  v_account uuid;
BEGIN
  IF fn_is_super_admin() = false THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF v_clinic IS NULL THEN
    RAISE EXCEPTION 'clinic_name is required';
  END IF;

  IF v_email IS NULL THEN
    RAISE EXCEPTION 'owner_email is required';
  END IF;

  SELECT u.id
    INTO v_uid
  FROM auth.users u
  WHERE lower(u.email) = v_email
  ORDER BY u.created_at DESC
  LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'owner email % not found in auth.users', v_email;
  END IF;

  v_account := public.admin_bootstrap_clinic_for_email(v_clinic, v_email, 'owner');

  RETURN jsonb_build_object(
    'ok', true,
    'account_id', v_account,
    'owner_uid', v_uid
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_create_owner_full(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_owner_full(text, text, text) TO service_role;

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
  v_account uuid := p_account;
  v_email text := nullif(lower(trim(p_email)), '');
  v_uid uuid;
BEGIN
  IF fn_is_super_admin() = false THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF v_account IS NULL THEN
    RAISE EXCEPTION 'account_id is required';
  END IF;

  IF v_email IS NULL THEN
    RAISE EXCEPTION 'email is required';
  END IF;

  SELECT u.id
    INTO v_uid
  FROM auth.users u
  WHERE lower(u.email) = v_email
  ORDER BY u.created_at DESC
  LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'employee email % not found in auth.users', v_email;
  END IF;

  PERFORM public.admin_attach_employee(v_account, v_uid, 'employee');

  UPDATE public.account_users
     SET email = v_email
   WHERE account_id = v_account
     AND user_uid = v_uid;

  RETURN jsonb_build_object(
    'ok', true,
    'account_id', v_account,
    'user_uid', v_uid
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_create_employee_full(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_employee_full(uuid, text, text) TO service_role;

CREATE OR REPLACE FUNCTION public.admin_list_clinics()
RETURNS TABLE (
  id uuid,
  name text,
  frozen boolean,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF fn_is_super_admin() = false THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  RETURN QUERY
  SELECT a.id, a.name, a.frozen, a.created_at
  FROM public.accounts a
  ORDER BY a.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_list_clinics() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_clinics() TO service_role;

CREATE OR REPLACE FUNCTION public.admin_set_clinic_frozen(p_account_id uuid, p_frozen boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF fn_is_super_admin() = false THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_account_id IS NULL THEN
    RAISE EXCEPTION 'account_id is required';
  END IF;

  UPDATE public.accounts
     SET frozen = coalesce(p_frozen, true)
   WHERE id = p_account_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_set_clinic_frozen(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_clinic_frozen(uuid, boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.admin_delete_clinic(p_account_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF fn_is_super_admin() = false THEN
    RAISE EXCEPTION 'forbidden';
  END IF;

  IF p_account_id IS NULL THEN
    RAISE EXCEPTION 'account_id is required';
  END IF;

  DELETE FROM public.accounts
   WHERE id = p_account_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_delete_clinic(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_clinic(uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
