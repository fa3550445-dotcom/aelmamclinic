-- chat_group_invitations: تقرير أعمدة/فهارس/سياسات RLS وصلاحيات
-- شغّل هذا الملف في SQL Editor داخل Supabase (أو عبر psql إن رغبت)

-- وجود الجدول
select to_regclass('public.chat_group_invitations') as table_exists;

-- الأعمدة
select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema='public' and table_name='chat_group_invitations'
order by ordinal_position;

-- الفهارس
select indexname, indexdef
from pg_indexes
where schemaname='public' and tablename='chat_group_invitations'
order by indexname;

-- هل RLS مفعّل؟
select c.relrowsecurity as rls_enabled
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname='public' and c.relname='chat_group_invitations';

-- سياسات RLS
select policyname, cmd, qual, with_check
from pg_policies
where schemaname='public' and tablename='chat_group_invitations'
order by policyname;

-- صلاحيات الجدول (GRANTs)
select grantee, privilege_type
from information_schema.role_table_grants
where table_schema='public' and table_name='chat_group_invitations'
order by grantee, privilege_type;

-- ملاحظات:
-- 1) إذا ما ظهر أي Policy، فالهجرة ما انطبقت: راجع 20251105012000_chat_group_invitations.sql
-- 2) لو عندك psql وتبي تشغيل آلي: اضبط متغير DATABASE_URL ثم psql -f هذا الملف.
