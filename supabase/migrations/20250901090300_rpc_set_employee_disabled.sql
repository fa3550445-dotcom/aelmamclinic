--//C:\Users\zidan\AndroidStudioProjects\aelmamclinic\supabase\migrations\20250901090300_rpc_set_employee_disabled.sql

-- تمكين/تعطيل موظف ضمن حساب معيّن.
-- سماحية الاستدعاء: owner/admin على الحساب أو السوبر أدمن.

drop function if exists public.set_employee_disabled(uuid, uuid, boolean);

create or replace function public.set_employee_disabled(
  p_account uuid,
  p_user_uid uuid,
  p_disabled boolean
)
returns void as $$
declare
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub','')::uuid;
  caller_email text := lower(coalesce(claims->>'email',''));
  super_admin_email text := 'aelmam.app@gmail.com';
  can_manage boolean;
begin
  select exists (
    select 1
    from public.account_users
    where account_id = p_account
      and user_uid = caller_uid
      and role in ('owner','admin')
      and coalesce(disabled,false) = false
  ) into can_manage;

  if not (can_manage or caller_email = lower(super_admin_email)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  update public.account_users
     set disabled = coalesce(p_disabled, false)
   where account_id = p_account
     and user_uid = p_user_uid;

  -- اختياري: عكس الحالة على profiles (لو موجود)
  update public.profiles
     set role = case when p_disabled then 'disabled' else coalesce(role, 'employee') end,
         account_id = coalesce(account_id, p_account)
   where id = p_user_uid;
end;
$$ language plpgsql
security definer
set search_path = public, auth;

revoke all on function public.set_employee_disabled(uuid, uuid, boolean) from public;
grant execute on function public.set_employee_disabled(uuid, uuid, boolean) to authenticated;
