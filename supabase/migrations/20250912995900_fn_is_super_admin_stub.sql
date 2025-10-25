create or replace function public.fn_is_super_admin()
returns boolean
language sql
stable
security definer
as $$ select false $$;
