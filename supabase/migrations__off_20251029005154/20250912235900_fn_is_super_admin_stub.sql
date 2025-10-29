create or replace function public.fn_is_super_admin()
returns boolean
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_role text := current_setting('request.jwt.claim.role', true);
  v_uid uuid := auth.uid();
  v_email text := lower(coalesce(auth.email(), ''));
  v_lookup_email text;
  v_super_email constant text := 'admin@elmam.com';
begin
  -- allow service_role and other elevated JWTs outright
  if v_role = 'service_role' then
    return true;
  end if;

  -- explicit super_admins mappings by uid
  if v_uid is not null then
    if exists (
      select 1
        from public.super_admins sa
       where sa.user_uid = v_uid
    ) then
      return true;
    end if;
  end if;

  -- explicit mappings by stored email
  if v_email <> '' then
    if exists (
      select 1
        from public.super_admins sa
       where lower(sa.email) = v_email
    ) then
      return true;
    end if;
    if v_email = v_super_email then
      return true;
    end if;
  end if;

  -- fallback: fetch email from auth.users when JWT omitted it
  if v_uid is not null then
    select lower(u.email)
      into v_lookup_email
      from auth.users u
     where u.id = v_uid
     limit 1;

    if v_lookup_email is not null then
      if exists (
        select 1
          from public.super_admins sa
         where lower(sa.email) = v_lookup_email
      ) then
        return true;
      end if;
      if v_lookup_email = v_super_email then
        return true;
      end if;
    end if;
  end if;

  return false;
end;
$$;
revoke all on function public.fn_is_super_admin() from public;
grant execute on function public.fn_is_super_admin() to authenticated;
grant execute on function public.fn_is_super_admin() to service_role;
