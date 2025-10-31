-- 20251105010000_accounts_rls.sql
-- Ensure accounts/account_users expose only permitted rows while remaining
-- queryable by authenticated users (owners, employees, super admins).

ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_users ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON public.accounts TO authenticated;
GRANT SELECT ON public.account_users TO authenticated;

DROP POLICY IF EXISTS accounts_select_members ON public.accounts;
CREATE POLICY accounts_select_members
ON public.accounts
FOR SELECT
TO authenticated
USING (
  fn_is_super_admin() = true
  OR fn_is_account_member(accounts.id)
);

DROP POLICY IF EXISTS account_users_select ON public.account_users;
CREATE POLICY account_users_select
ON public.account_users
FOR SELECT
TO authenticated
USING (
  fn_is_super_admin() = true
  OR account_users.user_uid::text = auth.uid()::text
  OR fn_is_account_member(account_users.account_id)
);

