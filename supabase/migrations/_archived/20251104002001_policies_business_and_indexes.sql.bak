-- Archived placeholder migration (disabled from active sequence on 2025-11-05).
-- Original contents retained for reference only; do NOT re-enable without reconciling
-- with the live schema used by lib/.

-- Migration: 20251104002001_policies_business_and_indexes.sql
-- Purpose: Create core business tables, indexes, helper functions, RLS policies and lightweight seeds
-- NOTE: Review and adapt column names/types to match exact usages in lib/*.dart before pushing.
-- After adding this file run: supabase db push --env-file supabase/.env.production
-- and then run smoke tests (login as owner/employee/super_admin, open chat, repo items, alerts, patients).

-- 0) Ensure extension for UUID generation exists (used for gen_random_uuid)
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 1) accounts (clinics / business accounts)
CREATE TABLE IF NOT EXISTS public.accounts (
  id text PRIMARY KEY,
  name text NOT NULL,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- 2) roles table (seedable)
CREATE TABLE IF NOT EXISTS public.roles (
  id text PRIMARY KEY,  -- e.g. 'owner','employee','super_admin'
  title text NOT NULL
);

-- 3) account_memberships: link auth users -> accounts with role
CREATE TABLE IF NOT EXISTS public.account_memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id text NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,                       -- should match auth.users.id
  role_id text NOT NULL REFERENCES public.roles(id),
  created_at timestamptz DEFAULT now(),
  UNIQUE(account_id, user_id)
);

-- 4) patients
CREATE TABLE IF NOT EXISTS public.patients (
  id serial PRIMARY KEY,
  account_id text REFERENCES public.accounts(id) ON DELETE CASCADE,
  name text NOT NULL,
  phone text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_by uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- 5) chat_conversations
CREATE TABLE IF NOT EXISTS public.chat_conversations (
  id text PRIMARY KEY,
  account_id text REFERENCES public.accounts(id) ON DELETE SET NULL, -- nullable for global/system convs
  is_group boolean DEFAULT false,
  title text,
  created_by uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  last_msg_at timestamptz,
  last_msg_snippet text
);

-- 6) chat_messages
CREATE TABLE IF NOT EXISTS public.chat_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id text NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  sender_id uuid,        -- auth.users.id
  body text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);

-- 7) repository_items
CREATE TABLE IF NOT EXISTS public.repository_items (
  id serial PRIMARY KEY,
  account_id text REFERENCES public.accounts(id) ON DELETE CASCADE,
  code text,
  name text NOT NULL,
  quantity numeric DEFAULT 0,
  unit text,
  price numeric,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- 8) purchases_consumptions
CREATE TABLE IF NOT EXISTS public.purchases_consumptions (
  id serial PRIMARY KEY,
  account_id text REFERENCES public.accounts(id) ON DELETE CASCADE,
  item_id int REFERENCES public.repository_items(id) ON DELETE SET NULL,
  type text NOT NULL, -- 'purchase' | 'consumption'
  qty numeric NOT NULL,
  unit_price numeric,
  created_by uuid,
  created_at timestamptz DEFAULT now()
);

-- 9) alerts table
CREATE TABLE IF NOT EXISTS public.alerts (
  id serial PRIMARY KEY,
  account_id text REFERENCES public.accounts(id) ON DELETE CASCADE,
  title text NOT NULL,
  body text,
  level text DEFAULT 'info',
  created_by uuid,
  created_at timestamptz DEFAULT now(),
  expires_at timestamptz
);

-- 10) indexes for performance
CREATE INDEX IF NOT EXISTS idx_accounts_name ON public.accounts (lower(name));
CREATE INDEX IF NOT EXISTS idx_account_memberships_account_id ON public.account_memberships (account_id);
CREATE INDEX IF NOT EXISTS idx_patients_account_id ON public.patients (account_id);
CREATE INDEX IF NOT EXISTS idx_chat_conversations_account_id ON public.chat_conversations (account_id);
CREATE INDEX IF NOT EXISTS idx_chat_conversations_last_msg_at ON public.chat_conversations (last_msg_at);
CREATE INDEX IF NOT EXISTS idx_chat_messages_conv_created ON public.chat_messages (conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_repo_items_account_id ON public.repository_items (account_id);
CREATE INDEX IF NOT EXISTS idx_purchases_account_id ON public.purchases_consumptions (account_id);
CREATE INDEX IF NOT EXISTS idx_alerts_account_id ON public.alerts (account_id);

-- 11) Enable Row Level Security on sensitive tables
ALTER TABLE IF EXISTS public.patients ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.chat_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.chat_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.repository_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.purchases_consumptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.account_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.accounts ENABLE ROW LEVEL SECURITY;

-- 12) Helper functions for auth checks
-- 12.a) is_super_admin reads jwt.claims.role if present
CREATE OR REPLACE FUNCTION public.is_super_admin() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT (current_setting('jwt.claims.role', true) = 'super_admin')
$$;

-- 12.b) returns role_id for given account and user, or NULL
CREATE OR REPLACE FUNCTION public.user_role_for_account(p_account_id text, p_user_id uuid)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT role_id FROM public.account_memberships
   WHERE account_id = p_account_id AND user_id = p_user_id
   LIMIT 1;
$$;

-- 13) RLS policies
-- 13.a) patients policies
CREATE POLICY patients_select_for_account ON public.patients
  FOR SELECT USING (
    public.is_super_admin() OR
    (account_id IS NOT NULL AND public.user_role_for_account(account_id, current_setting('jwt.claims.sub')::uuid) IS NOT NULL)
  );

CREATE POLICY patients_insert_for_account ON public.patients
  FOR INSERT WITH CHECK (
    public.is_super_admin() OR
    (account_id IS NOT NULL AND public.user_role_for_account(account_id, current_setting('jwt.claims.sub')::uuid) IS NOT NULL)
  );

CREATE POLICY patients_update_for_account ON public.patients
  FOR UPDATE USING (
    public.is_super_admin() OR
    (account_id IS NOT NULL AND public.user_role_for_account(account_id, current_setting('jwt.claims.sub')::uuid) IS NOT NULL)
  );

CREATE POLICY patients_delete_for_account ON public.patients
  FOR DELETE USING (
    public.is_super_admin() OR
    (account_id IS NOT NULL AND public.user_role_for_account(account_id, current_setting('jwt.claims.sub')::uuid) IS NOT NULL)
  );

-- 13.b) chat_conversations policies
CREATE POLICY chat_conversations_select_for_members ON public.chat_conversations
  FOR SELECT USING (
    public.is_super_admin() OR
    EXISTS (
      SELECT 1 FROM public.account_memberships am
       WHERE am.account_id = chat_conversations.account_id
         AND am.user_id = current_setting('jwt.claims.sub')::uuid
    )
  );

CREATE POLICY chat_conversations_insert_for_admins ON public.chat_conversations
  FOR INSERT WITH CHECK (
    public.is_super_admin() OR
    EXISTS (
      SELECT 1 FROM public.account_memberships am
       WHERE am.account_id = chat_conversations.account_id
         AND am.user_id = current_setting('jwt.claims.sub')::uuid
         AND am.role_id IN ('owner','super_admin')
    )
  );

-- Additional policies (chat_messages, repository_items, purchases_consumptions, alerts, account_memberships, accounts)
-- omitted for brevity in this archived copy.

-- 14) Trigger helpers
CREATE OR REPLACE FUNCTION public.trigger_set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'set_updated_at_trigger_patients') THEN
    CREATE TRIGGER set_updated_at_trigger_patients
      BEFORE UPDATE ON public.patients
      FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'set_updated_at_trigger_repo_items') THEN
    CREATE TRIGGER set_updated_at_trigger_repo_items
      BEFORE UPDATE ON public.repository_items
      FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'set_updated_at_trigger_accounts') THEN
    CREATE TRIGGER set_updated_at_trigger_accounts
      BEFORE UPDATE ON public.accounts
      FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();
  END IF;
END$$;

-- 15) Seed common roles (idempotent)
INSERT INTO public.roles (id, title) VALUES
  ('owner', 'Owner')
  ON CONFLICT (id) DO NOTHING;

INSERT INTO public.roles (id, title) VALUES
  ('employee', 'Employee')
  ON CONFLICT (id) DO NOTHING;

INSERT INTO public.roles (id, title) VALUES
  ('super_admin', 'Super Admin')
  ON CONFLICT (id) DO NOTHING;

-- 16) Notes & post-deploy checklist (as SQL comment):
--  - Ensure auth.jwt.claims.role contains 'super_admin' for super admin users OR maintain a separate admin mapping.
--  - If your client depends on specific column names/types not present here (e.g., chat_conversations.id as uuid),
--    adapt the definitions accordingly.
--  - Create storage buckets (e.g., 'chat-attachments') via supabase CLI or dashboard and set bucket policies appropriate to RLS.
--  - If you rely on RPCs like admin_bootstrap_clinic_for_email or admin__create_employee, implement them (server-side) after schema push.
--  - If you need to populate an initial account and admin user, use server-side script that calls the service_role key to insert account_memberships and/or auth.users.

-- End of migration.
