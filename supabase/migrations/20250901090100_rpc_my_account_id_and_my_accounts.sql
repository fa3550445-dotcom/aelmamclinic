--//C:\Users\zidan\AndroidStudioProjects\aelmamclinic\supabase\migrations\20250901090100_rpc_my_account_id_and_my_accounts.sql
-- my_account_id() و my_accounts()
-- يوفّر account_id الافتراضي و/أو كل الحسابات المرتبطة بالمستخدم الحالي.

create or replace function public.my_account_id()
returns uuid
language sql
security definer
set search_path = public
as $$
  select account_id
  from public.account_users
  where user_uid = auth.uid()
    and coalesce(disabled, false) = false
  order by created_at desc
  limit 1;
$$;

revoke all on function public.my_account_id() from public;
grant execute on function public.my_account_id() to authenticated;

create or replace function public.my_accounts()
returns setof uuid
language sql
security definer
set search_path = public
as $$
  select account_id
  from public.account_users
  where user_uid = auth.uid()
    and coalesce(disabled, false) = false
  order by created_at desc;
$$;

revoke all on function public.my_accounts() from public;
grant execute on function public.my_accounts() to authenticated;
