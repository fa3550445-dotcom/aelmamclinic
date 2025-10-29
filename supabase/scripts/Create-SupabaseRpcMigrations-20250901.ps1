$Dir = "supabase/migrations"
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

$TS1 = "20250901090100"
$TS2 = "20250901090200"
$TS3 = "20250901090300"
$TS4 = "20250901090400"

# 1) my_account_id + my_accounts
@'
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
'@ | Set-Content -Encoding UTF8 -Path "$Dir/${TS1}_rpc_my_account_id_and_my_accounts.sql"

# 2) list_employees_with_email
@'
-- تُرجع موظفي الحساب مع البريد الإلكتروني (تعتمد على auth.users + account_users)
-- سماحية الاستدعاء: owner/admin على نفس الحساب، أو السوبر أدمن بالبريد المحدد.

drop function if exists public.list_employees_with_email(uuid);

create or replace function public.list_employees_with_email(p_account uuid)
returns table(
  user_uid uuid,
  email text,
  role text,
  disabled boolean,
  created_at timestamptz
) as $$
declare
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub','')::uuid;
  caller_email text := lower(coalesce(claims->>'email',''));
  super_admin_email text := 'admin@elmam.com';
  can_manage boolean;
begin
  -- تحقق الصلاحيات: (owner/admin) على الحساب أو سوبر أدمن بالبريد
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

  return query
  select
    au.user_uid,
    u.email,
    au.role,
    coalesce(au.disabled,false) as disabled,
    au.created_at
  from public.account_users au
  left join auth.users u on u.id = au.user_uid
  where au.account_id = p_account
  order by au.created_at desc;
end;
$$ language plpgsql
security definer
set search_path = public, auth;

revoke all on function public.list_employees_with_email(uuid) from public;
grant execute on function public.list_employees_with_email(uuid) to authenticated;
'@ | Set-Content -Encoding UTF8 -Path "$Dir/${TS2}_rpc_list_employees_with_email.sql"

# 3) set_employee_disabled
@'
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
  super_admin_email text := 'admin@elmam.com';
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
'@ | Set-Content -Encoding UTF8 -Path "$Dir/${TS3}_rpc_set_employee_disabled.sql"

# 4) delete_employee
@'
-- حذف ربط موظف بالحساب (لا يحذف مستخدم auth).
-- سماحية الاستدعاء: owner/admin على الحساب أو السوبر أدمن.

drop function if exists public.delete_employee(uuid, uuid);

create or replace function public.delete_employee(
  p_account uuid,
  p_user_uid uuid
)
returns void as $$
declare
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub','')::uuid;
  caller_email text := lower(coalesce(claims->>'email',''));
  super_admin_email text := 'admin@elmam.com';
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

  delete from public.account_users
   where account_id = p_account
     and user_uid = p_user_uid;

  -- اختياري: وسم البروفايل كـ "removed" بدلاً من الحذف
  update public.profiles
     set role = 'removed'
   where id = p_user_uid
     and coalesce(account_id, p_account) = p_account;
end;
$$ language plpgsql
security definer
set search_path = public, auth;

revoke all on function public.delete_employee(uuid, uuid) from public;
grant execute on function public.delete_employee(uuid, uuid) to authenticated;
'@ | Set-Content -Encoding UTF8 -Path "$Dir/${TS4}_rpc_delete_employee.sql"

Write-Host "✅ Created SQL migrations under: $Dir"
Get-ChildItem "$Dir\20250901*.sql" | ForEach-Object { Write-Host " - " $_.Name }
