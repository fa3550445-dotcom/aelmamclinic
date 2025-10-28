-- 20251027091000_seed_super_admin.sql
-- Seed default super admin email.

INSERT INTO public.super_admins(email)
VALUES ('aelmam.app@gmail.com')
ON CONFLICT (email) DO NOTHING;
