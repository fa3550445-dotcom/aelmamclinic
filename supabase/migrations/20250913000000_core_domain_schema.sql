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
    'account_users','patients','returns','consumptions','drugs','prescriptions','prescription_items',
    'complaints','appointments','doctors','consumption_types','medical_services',
    'service_doctor_share','employees','employees_loans','employees_salaries',
    'employees_discounts','item_types','items','purchases','alert_settings',
    'financial_logs','patient_services'
  ]) LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I_set_updated_at ON public.%I', tbl, tbl);
    EXECUTE format('CREATE TRIGGER %I_set_updated_at BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.tg_set_updated_at()', tbl, tbl);
  END LOOP;
END $$;

DROP TRIGGER IF EXISTS audit_logs_set_created_at ON public.audit_logs;
CREATE TRIGGER audit_logs_set_created_at
  BEFORE INSERT ON public.audit_logs
  FOR EACH ROW
  EXECUTE FUNCTION public.tg_audit_logs_set_created_at();

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

-- إجراءات خدمية --------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_attach_employee(p_account uuid, p_user_uid uuid, p_role text DEFAULT 'employee')
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  exists_row boolean;
BEGIN
  IF p_account IS NULL OR p_user_uid IS NULL THEN
    RAISE EXCEPTION 'account_id and user_uid are required';
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
    WHERE table_schema='public' AND table_name='profiles'
  ) THEN
    INSERT INTO public.profiles(id, account_id, role, created_at)
    VALUES (p_user_uid, p_account, COALESCE(p_role, 'employee'), now())
    ON CONFLICT (id) DO UPDATE
        SET account_id = EXCLUDED.account_id,
            role = EXCLUDED.role;
  END IF;
END;
$$;

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

GRANT EXECUTE ON FUNCTION public.admin_attach_employee(uuid, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_bootstrap_clinic_for_email(text, text, text) TO service_role;
