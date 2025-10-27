

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE SCHEMA IF NOT EXISTS "storage";


ALTER SCHEMA "storage" OWNER TO "supabase_admin";


CREATE TYPE "storage"."buckettype" AS ENUM (
    'STANDARD',
    'ANALYTICS'
);


ALTER TYPE "storage"."buckettype" OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "public"."admin_attach_employee"("p_account" "uuid", "p_user_uid" "uuid", "p_role" "text" DEFAULT 'employee'::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
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


ALTER FUNCTION "public"."admin_attach_employee"("p_account" "uuid", "p_user_uid" "uuid", "p_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_bootstrap_clinic_for_email"("clinic_name" "text", "owner_email" "text", "owner_role" "text" DEFAULT 'owner'::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
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


ALTER FUNCTION "public"."admin_bootstrap_clinic_for_email"("clinic_name" "text", "owner_email" "text", "owner_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."chat_conversation_id_from_path"("_name" "text") RETURNS "uuid"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  -- نلتقط UUID من الجزء بعد attachments/
  -- مثال: attachments/123e4567-e89b-12d3-a456-426614174000/...
  select case
           when regexp_match(_name,
             '^attachments/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/'
           ) is null
           then null
           else ((regexp_match(_name,
             '^attachments/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/'
           ))[1])::uuid
         end
$$;


ALTER FUNCTION "public"."chat_conversation_id_from_path"("_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_employee"("p_account" "uuid", "p_user_uid" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
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

  delete from public.account_users
   where account_id = p_account
     and user_uid = p_user_uid;

  -- اختياري: وسم البروفايل كـ "removed" بدلاً من الحذف
  update public.profiles
     set role = 'removed'
   where id = p_user_uid
     and coalesce(account_id, p_account) = p_account;
end;
$$;


ALTER FUNCTION "public"."delete_employee"("p_account" "uuid", "p_user_uid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_chat_messages_touch_last_msg"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_cid uuid;
BEGIN
  v_cid := COALESCE(NEW.conversation_id, OLD.conversation_id);
  PERFORM public.fn_chat_refresh_last_msg(v_cid);
  RETURN COALESCE(NEW, OLD);
END;
$$;


ALTER FUNCTION "public"."fn_chat_messages_touch_last_msg"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_chat_refresh_last_msg"("p_conversation_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_last_at    timestamptz;
  v_last_kind  text;
  v_last_body  text;
  v_snippet    text;
BEGIN
  -- اجلب أحدث رسالة غير محذوفة
  SELECT m.created_at, m.kind::text, m.body
    INTO v_last_at, v_last_kind, v_last_body
  FROM public.chat_messages m
  WHERE m.conversation_id = p_conversation_id
    AND COALESCE(m.deleted, false) = false
  ORDER BY m.created_at DESC
  LIMIT 1;

  IF v_last_at IS NULL THEN
    -- لا رسائل (أو كلها محذوفة)
    UPDATE public.chat_conversations
       SET last_msg_at = NULL,
           last_msg_snippet = NULL
     WHERE id = p_conversation_id;
    RETURN;
  END IF;

  -- ابنِ الـ snippet
  IF lower(coalesce(v_last_kind,'')) LIKE '%image%' OR lower(coalesce(v_last_kind,'')) = 'image' THEN
    v_snippet := '📷 صورة';
  ELSE
    -- نص: تقليم للمسافات والأسطر ثم قص إلى 64 وإضافة "…"
    v_last_body := btrim(coalesce(v_last_body, ''));
    IF v_last_body = '' THEN
      v_snippet := 'رسالة';
    ELSE
      IF length(v_last_body) > 64 THEN
        v_snippet := substring(v_last_body from 1 for 64) || '…';
      ELSE
        v_snippet := v_last_body;
      END IF;
    END IF;
  END IF;

  -- حدّث المحادثة
  UPDATE public.chat_conversations
     SET last_msg_at      = v_last_at,
         last_msg_snippet = v_snippet
   WHERE id = p_conversation_id;
END;
$$;


ALTER FUNCTION "public"."fn_chat_refresh_last_msg"("p_conversation_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_is_super_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  SELECT EXISTS (
           SELECT 1
           FROM public.super_admins s
           WHERE s.user_uid::text = auth.uid()::text
         )
      OR EXISTS (
           SELECT 1
           FROM public.account_users au
           WHERE au.user_uid::text = auth.uid()::text
             AND lower(au.role) = 'superadmin'
         );
$$;


ALTER FUNCTION "public"."fn_is_super_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_my_latest_account_id"() RETURNS "text"
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
  acc text;
BEGIN
  SELECT au.account_id::text
    INTO acc
  FROM public.account_users au
  WHERE au.user_uid::text = auth.uid()::text
  ORDER BY au.created_at DESC NULLS LAST
  LIMIT 1;

  RETURN acc;
END;
$$;


ALTER FUNCTION "public"."fn_my_latest_account_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_sign_chat_attachment"("p_bucket" "text", "p_path" "text", "p_expires_in" integer DEFAULT 900) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_message_id    uuid;
  v_conversation  uuid;
  v_has_access    boolean;
  v_signed_url    text;
BEGIN
  -- تحقق أن هذا المسار مسجّل كمرفق دردشة
  SELECT a.message_id
    INTO v_message_id
  FROM public.chat_attachments a
  WHERE a.bucket = p_bucket
    AND a.path   = p_path
  LIMIT 1;

  IF v_message_id IS NULL THEN
    RAISE EXCEPTION 'Attachment not found' USING ERRCODE = 'no_data_found';
  END IF;

  -- اجلب محادثته
  SELECT m.conversation_id
    INTO v_conversation
  FROM public.chat_messages m
  WHERE m.id = v_message_id;

  IF v_conversation IS NULL THEN
    RAISE EXCEPTION 'Message not found for attachment' USING ERRCODE = 'no_data_found';
  END IF;

  -- تحقّق أن المستخدم الحالي عضو في المحادثة
  SELECT EXISTS(
    SELECT 1
    FROM public.chat_participants p
    WHERE p.conversation_id = v_conversation
      AND p.user_uid = auth.uid()
  ) INTO v_has_access;

  IF NOT v_has_access THEN
    RAISE EXCEPTION 'Forbidden' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- أنشئ الرابط الموقّع عبر دالة التخزين
  -- ملاحظة: بعض منصّات Supabase توفّر storage.create_signed_url كدالة SQL.
  -- إن لم تكن متاحة في بيئتك، استخدم Edge Function بديل.
  BEGIN
    v_signed_url := storage.create_signed_url(p_bucket, p_path, p_expires_in);
  EXCEPTION WHEN undefined_function THEN
    -- لو لم تتوفر الدالة في هذه البيئة، نرمي خطأ واضحًا.
    RAISE EXCEPTION
      'storage.create_signed_url is not available on this instance. Use the Edge Function instead.'
      USING ERRCODE = 'feature_not_supported';
  END;

  RETURN jsonb_build_object(
    'signedUrl', v_signed_url,
    'url',       v_signed_url  -- للتوافق مع بعض العملاء
  );
END;
$$;


ALTER FUNCTION "public"."fn_sign_chat_attachment"("p_bucket" "text", "p_path" "text", "p_expires_in" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."fn_sign_chat_attachment"("p_bucket" "text", "p_path" "text", "p_expires_in" integer) IS 'Generates a signed URL for a chat attachment after verifying the caller is a participant in the conversation.';



CREATE OR REPLACE FUNCTION "public"."get_enum_types"() RETURNS TABLE("name" "text", "labels" "text"[])
    LANGUAGE "sql" STABLE
    AS $$
  select t.typname::text as name,
         array_agg(e.enumlabel order by e.enumsortorder)::text[] as labels
  from pg_type t
  join pg_enum e on e.enumtypid = t.oid
  join pg_namespace n on n.oid = t.typnamespace
  where n.nspname in ('public')
  group by t.typname
  order by t.typname;
$$;


ALTER FUNCTION "public"."get_enum_types"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_schema_info"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE
    AS $$
with tbls as (
  select table_schema, table_name
  from information_schema.tables
  where table_schema in ('public') and table_type = 'BASE TABLE'
),
cols as (
  select table_schema, table_name, column_name, data_type, udt_name,
         is_nullable, is_generated, column_default, ordinal_position
  from information_schema.columns
  where table_schema in ('public')
),
pks as (
  select kcu.table_schema, kcu.table_name, kcu.column_name, kcu.ordinal_position
  from information_schema.table_constraints tc
  join information_schema.key_column_usage kcu
    on tc.constraint_name = kcu.constraint_name
   and tc.table_schema   = kcu.table_schema
  where tc.constraint_type = 'PRIMARY KEY'
    and tc.table_schema in ('public')
),
fks as (
  select tc.table_schema,
         tc.table_name,
         kcu.column_name,
         ccu.table_schema as foreign_table_schema,
         ccu.table_name   as foreign_table_name,
         ccu.column_name  as foreign_column_name
  from information_schema.table_constraints tc
  join information_schema.key_column_usage kcu
    on tc.constraint_name = kcu.constraint_name
   and tc.table_schema   = kcu.table_schema
  join information_schema.constraint_column_usage ccu
    on ccu.constraint_name = tc.constraint_name
   and ccu.table_schema   = tc.table_schema
  where tc.constraint_type = 'FOREIGN KEY'
    and tc.table_schema in ('public')
),
enums as (
  select name, labels from public.get_enum_types()
)
select jsonb_build_object(
  'tables', (
    select coalesce(
      jsonb_agg(jsonb_build_object('schema', s.table_schema, 'name', s.table_name)),
      '[]'::jsonb
    )
    from (
      select distinct t.table_schema, t.table_name
      from tbls t
      order by t.table_schema, t.table_name
    ) s
  ),
  'columns', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'schema', c.table_schema,
      'table',  c.table_name,
      'name',   c.column_name,
      'data_type', c.data_type,
      'udt_name',  c.udt_name,
      'is_nullable', c.is_nullable = 'YES',
      'is_generated', c.is_generated,
      'default', c.column_default
    ) order by c.table_schema, c.table_name, c.ordinal_position), '[]'::jsonb)
    from cols c
  ),
  'primary_keys', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'schema', p.table_schema, 'table', p.table_name, 'column', p.column_name
    ) order by p.table_schema, p.table_name, p.column_name), '[]'::jsonb)
    from pks p
  ),
  'foreign_keys', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'schema', f.table_schema, 'table', f.table_name, 'column', f.column_name,
      'foreign_schema', f.foreign_table_schema,
      'foreign_table',  f.foreign_table_name,
      'foreign_column', f.foreign_column_name
    ) order by f.table_schema, f.table_name, f.column_name), '[]'::jsonb)
    from fks f
  ),
  'enums', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'name', e.name, 'labels', e.labels
    )), '[]'::jsonb)
    from enums e
  )
);
$$;


ALTER FUNCTION "public"."get_schema_info"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_employees_with_email"("p_account" "uuid") RETURNS TABLE("user_uid" "uuid", "email" "text", "role" "text", "disabled" boolean, "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
declare
  claims jsonb := coalesce(current_setting('request.jwt.claims', true)::jsonb, '{}'::jsonb);
  caller_uid uuid := nullif(claims->>'sub','')::uuid;
  caller_email text := lower(coalesce(claims->>'email',''));
  super_admin_email text := 'aelmam.app@gmail.com';
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
$$;


ALTER FUNCTION "public"."list_employees_with_email"("p_account" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."my_account_id"() RETURNS "uuid"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select account_id
  from public.account_users
  where user_uid = auth.uid()
    and coalesce(disabled, false) = false
  order by created_at desc
  limit 1;
$$;


ALTER FUNCTION "public"."my_account_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."my_accounts"() RETURNS SETOF "uuid"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select account_id
  from public.account_users
  where user_uid = auth.uid()
    and coalesce(disabled, false) = false
  order by created_at desc;
$$;


ALTER FUNCTION "public"."my_accounts"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_employee_disabled"("p_account" "uuid", "p_user_uid" "uuid", "p_disabled" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
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
$$;


ALTER FUNCTION "public"."set_employee_disabled"("p_account" "uuid", "p_user_uid" "uuid", "p_disabled" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_profiles_set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."tg_profiles_set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."tg_set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_touch_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at := now();
  return new;
end
$$;


ALTER FUNCTION "public"."tg_touch_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "storage"."add_prefixes"("_bucket_id" "text", "_name" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    prefixes text[];
BEGIN
    prefixes := "storage"."get_prefixes"("_name");

    IF array_length(prefixes, 1) > 0 THEN
        INSERT INTO storage.prefixes (name, bucket_id)
        SELECT UNNEST(prefixes) as name, "_bucket_id" ON CONFLICT DO NOTHING;
    END IF;
END;
$$;


ALTER FUNCTION "storage"."add_prefixes"("_bucket_id" "text", "_name" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."can_insert_object"("bucketid" "text", "name" "text", "owner" "uuid", "metadata" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  INSERT INTO "storage"."objects" ("bucket_id", "name", "owner", "metadata") VALUES (bucketid, name, owner, metadata);
  -- hack to rollback the successful insert
  RAISE sqlstate 'PT200' using
  message = 'ROLLBACK',
  detail = 'rollback successful insert';
END
$$;


ALTER FUNCTION "storage"."can_insert_object"("bucketid" "text", "name" "text", "owner" "uuid", "metadata" "jsonb") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."delete_leaf_prefixes"("bucket_ids" "text"[], "names" "text"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_rows_deleted integer;
BEGIN
    LOOP
        WITH candidates AS (
            SELECT DISTINCT
                t.bucket_id,
                unnest(storage.get_prefixes(t.name)) AS name
            FROM unnest(bucket_ids, names) AS t(bucket_id, name)
        ),
        uniq AS (
             SELECT
                 bucket_id,
                 name,
                 storage.get_level(name) AS level
             FROM candidates
             WHERE name <> ''
             GROUP BY bucket_id, name
        ),
        leaf AS (
             SELECT
                 p.bucket_id,
                 p.name,
                 p.level
             FROM storage.prefixes AS p
                  JOIN uniq AS u
                       ON u.bucket_id = p.bucket_id
                           AND u.name = p.name
                           AND u.level = p.level
             WHERE NOT EXISTS (
                 SELECT 1
                 FROM storage.objects AS o
                 WHERE o.bucket_id = p.bucket_id
                   AND o.level = p.level + 1
                   AND o.name COLLATE "C" LIKE p.name || '/%'
             )
             AND NOT EXISTS (
                 SELECT 1
                 FROM storage.prefixes AS c
                 WHERE c.bucket_id = p.bucket_id
                   AND c.level = p.level + 1
                   AND c.name COLLATE "C" LIKE p.name || '/%'
             )
        )
        DELETE
        FROM storage.prefixes AS p
            USING leaf AS l
        WHERE p.bucket_id = l.bucket_id
          AND p.name = l.name
          AND p.level = l.level;

        GET DIAGNOSTICS v_rows_deleted = ROW_COUNT;
        EXIT WHEN v_rows_deleted = 0;
    END LOOP;
END;
$$;


ALTER FUNCTION "storage"."delete_leaf_prefixes"("bucket_ids" "text"[], "names" "text"[]) OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."delete_prefix"("_bucket_id" "text", "_name" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    -- Check if we can delete the prefix
    IF EXISTS(
        SELECT FROM "storage"."prefixes"
        WHERE "prefixes"."bucket_id" = "_bucket_id"
          AND level = "storage"."get_level"("_name") + 1
          AND "prefixes"."name" COLLATE "C" LIKE "_name" || '/%'
        LIMIT 1
    )
    OR EXISTS(
        SELECT FROM "storage"."objects"
        WHERE "objects"."bucket_id" = "_bucket_id"
          AND "storage"."get_level"("objects"."name") = "storage"."get_level"("_name") + 1
          AND "objects"."name" COLLATE "C" LIKE "_name" || '/%'
        LIMIT 1
    ) THEN
    -- There are sub-objects, skip deletion
    RETURN false;
    ELSE
        DELETE FROM "storage"."prefixes"
        WHERE "prefixes"."bucket_id" = "_bucket_id"
          AND level = "storage"."get_level"("_name")
          AND "prefixes"."name" = "_name";
        RETURN true;
    END IF;
END;
$$;


ALTER FUNCTION "storage"."delete_prefix"("_bucket_id" "text", "_name" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."delete_prefix_hierarchy_trigger"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    prefix text;
BEGIN
    prefix := "storage"."get_prefix"(OLD."name");

    IF coalesce(prefix, '') != '' THEN
        PERFORM "storage"."delete_prefix"(OLD."bucket_id", prefix);
    END IF;

    RETURN OLD;
END;
$$;


ALTER FUNCTION "storage"."delete_prefix_hierarchy_trigger"() OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."enforce_bucket_name_length"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
    if length(new.name) > 100 then
        raise exception 'bucket name "%" is too long (% characters). Max is 100.', new.name, length(new.name);
    end if;
    return new;
end;
$$;


ALTER FUNCTION "storage"."enforce_bucket_name_length"() OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."extension"("name" "text") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
DECLARE
    _parts text[];
    _filename text;
BEGIN
    SELECT string_to_array(name, '/') INTO _parts;
    SELECT _parts[array_length(_parts,1)] INTO _filename;
    RETURN reverse(split_part(reverse(_filename), '.', 1));
END
$$;


ALTER FUNCTION "storage"."extension"("name" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."filename"("name" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
_parts text[];
BEGIN
	select string_to_array(name, '/') into _parts;
	return _parts[array_length(_parts,1)];
END
$$;


ALTER FUNCTION "storage"."filename"("name" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."foldername"("name" "text") RETURNS "text"[]
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
DECLARE
    _parts text[];
BEGIN
    -- Split on "/" to get path segments
    SELECT string_to_array(name, '/') INTO _parts;
    -- Return everything except the last segment
    RETURN _parts[1 : array_length(_parts,1) - 1];
END
$$;


ALTER FUNCTION "storage"."foldername"("name" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."get_level"("name" "text") RETURNS integer
    LANGUAGE "sql" IMMUTABLE STRICT
    AS $$
SELECT array_length(string_to_array("name", '/'), 1);
$$;


ALTER FUNCTION "storage"."get_level"("name" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."get_prefix"("name" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE STRICT
    AS $_$
SELECT
    CASE WHEN strpos("name", '/') > 0 THEN
             regexp_replace("name", '[\/]{1}[^\/]+\/?$', '')
         ELSE
             ''
        END;
$_$;


ALTER FUNCTION "storage"."get_prefix"("name" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."get_prefixes"("name" "text") RETURNS "text"[]
    LANGUAGE "plpgsql" IMMUTABLE STRICT
    AS $$
DECLARE
    parts text[];
    prefixes text[];
    prefix text;
BEGIN
    -- Split the name into parts by '/'
    parts := string_to_array("name", '/');
    prefixes := '{}';

    -- Construct the prefixes, stopping one level below the last part
    FOR i IN 1..array_length(parts, 1) - 1 LOOP
            prefix := array_to_string(parts[1:i], '/');
            prefixes := array_append(prefixes, prefix);
    END LOOP;

    RETURN prefixes;
END;
$$;


ALTER FUNCTION "storage"."get_prefixes"("name" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."get_size_by_bucket"() RETURNS TABLE("size" bigint, "bucket_id" "text")
    LANGUAGE "plpgsql" STABLE
    AS $$
BEGIN
    return query
        select sum((metadata->>'size')::bigint) as size, obj.bucket_id
        from "storage".objects as obj
        group by obj.bucket_id;
END
$$;


ALTER FUNCTION "storage"."get_size_by_bucket"() OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."list_multipart_uploads_with_delimiter"("bucket_id" "text", "prefix_param" "text", "delimiter_param" "text", "max_keys" integer DEFAULT 100, "next_key_token" "text" DEFAULT ''::"text", "next_upload_token" "text" DEFAULT ''::"text") RETURNS TABLE("key" "text", "id" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql"
    AS $_$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT DISTINCT ON(key COLLATE "C") * from (
            SELECT
                CASE
                    WHEN position($2 IN substring(key from length($1) + 1)) > 0 THEN
                        substring(key from 1 for length($1) + position($2 IN substring(key from length($1) + 1)))
                    ELSE
                        key
                END AS key, id, created_at
            FROM
                storage.s3_multipart_uploads
            WHERE
                bucket_id = $5 AND
                key ILIKE $1 || ''%'' AND
                CASE
                    WHEN $4 != '''' AND $6 = '''' THEN
                        CASE
                            WHEN position($2 IN substring(key from length($1) + 1)) > 0 THEN
                                substring(key from 1 for length($1) + position($2 IN substring(key from length($1) + 1))) COLLATE "C" > $4
                            ELSE
                                key COLLATE "C" > $4
                            END
                    ELSE
                        true
                END AND
                CASE
                    WHEN $6 != '''' THEN
                        id COLLATE "C" > $6
                    ELSE
                        true
                    END
            ORDER BY
                key COLLATE "C" ASC, created_at ASC) as e order by key COLLATE "C" LIMIT $3'
        USING prefix_param, delimiter_param, max_keys, next_key_token, bucket_id, next_upload_token;
END;
$_$;


ALTER FUNCTION "storage"."list_multipart_uploads_with_delimiter"("bucket_id" "text", "prefix_param" "text", "delimiter_param" "text", "max_keys" integer, "next_key_token" "text", "next_upload_token" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."list_objects_with_delimiter"("bucket_id" "text", "prefix_param" "text", "delimiter_param" "text", "max_keys" integer DEFAULT 100, "start_after" "text" DEFAULT ''::"text", "next_token" "text" DEFAULT ''::"text") RETURNS TABLE("name" "text", "id" "uuid", "metadata" "jsonb", "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql"
    AS $_$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT DISTINCT ON(name COLLATE "C") * from (
            SELECT
                CASE
                    WHEN position($2 IN substring(name from length($1) + 1)) > 0 THEN
                        substring(name from 1 for length($1) + position($2 IN substring(name from length($1) + 1)))
                    ELSE
                        name
                END AS name, id, metadata, updated_at
            FROM
                storage.objects
            WHERE
                bucket_id = $5 AND
                name ILIKE $1 || ''%'' AND
                CASE
                    WHEN $6 != '''' THEN
                    name COLLATE "C" > $6
                ELSE true END
                AND CASE
                    WHEN $4 != '''' THEN
                        CASE
                            WHEN position($2 IN substring(name from length($1) + 1)) > 0 THEN
                                substring(name from 1 for length($1) + position($2 IN substring(name from length($1) + 1))) COLLATE "C" > $4
                            ELSE
                                name COLLATE "C" > $4
                            END
                    ELSE
                        true
                END
            ORDER BY
                name COLLATE "C" ASC) as e order by name COLLATE "C" LIMIT $3'
        USING prefix_param, delimiter_param, max_keys, next_token, bucket_id, start_after;
END;
$_$;


ALTER FUNCTION "storage"."list_objects_with_delimiter"("bucket_id" "text", "prefix_param" "text", "delimiter_param" "text", "max_keys" integer, "start_after" "text", "next_token" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."lock_top_prefixes"("bucket_ids" "text"[], "names" "text"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_bucket text;
    v_top text;
BEGIN
    FOR v_bucket, v_top IN
        SELECT DISTINCT t.bucket_id,
            split_part(t.name, '/', 1) AS top
        FROM unnest(bucket_ids, names) AS t(bucket_id, name)
        WHERE t.name <> ''
        ORDER BY 1, 2
        LOOP
            PERFORM pg_advisory_xact_lock(hashtextextended(v_bucket || '/' || v_top, 0));
        END LOOP;
END;
$$;


ALTER FUNCTION "storage"."lock_top_prefixes"("bucket_ids" "text"[], "names" "text"[]) OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."objects_delete_cleanup"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_bucket_ids text[];
    v_names      text[];
BEGIN
    IF current_setting('storage.gc.prefixes', true) = '1' THEN
        RETURN NULL;
    END IF;

    PERFORM set_config('storage.gc.prefixes', '1', true);

    SELECT COALESCE(array_agg(d.bucket_id), '{}'),
           COALESCE(array_agg(d.name), '{}')
    INTO v_bucket_ids, v_names
    FROM deleted AS d
    WHERE d.name <> '';

    PERFORM storage.lock_top_prefixes(v_bucket_ids, v_names);
    PERFORM storage.delete_leaf_prefixes(v_bucket_ids, v_names);

    RETURN NULL;
END;
$$;


ALTER FUNCTION "storage"."objects_delete_cleanup"() OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."objects_insert_prefix_trigger"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    PERFORM "storage"."add_prefixes"(NEW."bucket_id", NEW."name");
    NEW.level := "storage"."get_level"(NEW."name");

    RETURN NEW;
END;
$$;


ALTER FUNCTION "storage"."objects_insert_prefix_trigger"() OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."objects_update_cleanup"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    -- NEW - OLD (destinations to create prefixes for)
    v_add_bucket_ids text[];
    v_add_names      text[];

    -- OLD - NEW (sources to prune)
    v_src_bucket_ids text[];
    v_src_names      text[];
BEGIN
    IF TG_OP <> 'UPDATE' THEN
        RETURN NULL;
    END IF;

    -- 1) Compute NEW−OLD (added paths) and OLD−NEW (moved-away paths)
    WITH added AS (
        SELECT n.bucket_id, n.name
        FROM new_rows n
        WHERE n.name <> '' AND position('/' in n.name) > 0
        EXCEPT
        SELECT o.bucket_id, o.name FROM old_rows o WHERE o.name <> ''
    ),
    moved AS (
         SELECT o.bucket_id, o.name
         FROM old_rows o
         WHERE o.name <> ''
         EXCEPT
         SELECT n.bucket_id, n.name FROM new_rows n WHERE n.name <> ''
    )
    SELECT
        -- arrays for ADDED (dest) in stable order
        COALESCE( (SELECT array_agg(a.bucket_id ORDER BY a.bucket_id, a.name) FROM added a), '{}' ),
        COALESCE( (SELECT array_agg(a.name      ORDER BY a.bucket_id, a.name) FROM added a), '{}' ),
        -- arrays for MOVED (src) in stable order
        COALESCE( (SELECT array_agg(m.bucket_id ORDER BY m.bucket_id, m.name) FROM moved m), '{}' ),
        COALESCE( (SELECT array_agg(m.name      ORDER BY m.bucket_id, m.name) FROM moved m), '{}' )
    INTO v_add_bucket_ids, v_add_names, v_src_bucket_ids, v_src_names;

    -- Nothing to do?
    IF (array_length(v_add_bucket_ids, 1) IS NULL) AND (array_length(v_src_bucket_ids, 1) IS NULL) THEN
        RETURN NULL;
    END IF;

    -- 2) Take per-(bucket, top) locks: ALL prefixes in consistent global order to prevent deadlocks
    DECLARE
        v_all_bucket_ids text[];
        v_all_names text[];
    BEGIN
        -- Combine source and destination arrays for consistent lock ordering
        v_all_bucket_ids := COALESCE(v_src_bucket_ids, '{}') || COALESCE(v_add_bucket_ids, '{}');
        v_all_names := COALESCE(v_src_names, '{}') || COALESCE(v_add_names, '{}');

        -- Single lock call ensures consistent global ordering across all transactions
        IF array_length(v_all_bucket_ids, 1) IS NOT NULL THEN
            PERFORM storage.lock_top_prefixes(v_all_bucket_ids, v_all_names);
        END IF;
    END;

    -- 3) Create destination prefixes (NEW−OLD) BEFORE pruning sources
    IF array_length(v_add_bucket_ids, 1) IS NOT NULL THEN
        WITH candidates AS (
            SELECT DISTINCT t.bucket_id, unnest(storage.get_prefixes(t.name)) AS name
            FROM unnest(v_add_bucket_ids, v_add_names) AS t(bucket_id, name)
            WHERE name <> ''
        )
        INSERT INTO storage.prefixes (bucket_id, name)
        SELECT c.bucket_id, c.name
        FROM candidates c
        ON CONFLICT DO NOTHING;
    END IF;

    -- 4) Prune source prefixes bottom-up for OLD−NEW
    IF array_length(v_src_bucket_ids, 1) IS NOT NULL THEN
        -- re-entrancy guard so DELETE on prefixes won't recurse
        IF current_setting('storage.gc.prefixes', true) <> '1' THEN
            PERFORM set_config('storage.gc.prefixes', '1', true);
        END IF;

        PERFORM storage.delete_leaf_prefixes(v_src_bucket_ids, v_src_names);
    END IF;

    RETURN NULL;
END;
$$;


ALTER FUNCTION "storage"."objects_update_cleanup"() OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."objects_update_level_trigger"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- Ensure this is an update operation and the name has changed
    IF TG_OP = 'UPDATE' AND (NEW."name" <> OLD."name" OR NEW."bucket_id" <> OLD."bucket_id") THEN
        -- Set the new level
        NEW."level" := "storage"."get_level"(NEW."name");
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "storage"."objects_update_level_trigger"() OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."objects_update_prefix_trigger"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    old_prefixes TEXT[];
BEGIN
    -- Ensure this is an update operation and the name has changed
    IF TG_OP = 'UPDATE' AND (NEW."name" <> OLD."name" OR NEW."bucket_id" <> OLD."bucket_id") THEN
        -- Retrieve old prefixes
        old_prefixes := "storage"."get_prefixes"(OLD."name");

        -- Remove old prefixes that are only used by this object
        WITH all_prefixes as (
            SELECT unnest(old_prefixes) as prefix
        ),
        can_delete_prefixes as (
             SELECT prefix
             FROM all_prefixes
             WHERE NOT EXISTS (
                 SELECT 1 FROM "storage"."objects"
                 WHERE "bucket_id" = OLD."bucket_id"
                   AND "name" <> OLD."name"
                   AND "name" LIKE (prefix || '%')
             )
         )
        DELETE FROM "storage"."prefixes" WHERE name IN (SELECT prefix FROM can_delete_prefixes);

        -- Add new prefixes
        PERFORM "storage"."add_prefixes"(NEW."bucket_id", NEW."name");
    END IF;
    -- Set the new level
    NEW."level" := "storage"."get_level"(NEW."name");

    RETURN NEW;
END;
$$;


ALTER FUNCTION "storage"."objects_update_prefix_trigger"() OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."operation"() RETURNS "text"
    LANGUAGE "plpgsql" STABLE
    AS $$
BEGIN
    RETURN current_setting('storage.operation', true);
END;
$$;


ALTER FUNCTION "storage"."operation"() OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."prefixes_delete_cleanup"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    v_bucket_ids text[];
    v_names      text[];
BEGIN
    IF current_setting('storage.gc.prefixes', true) = '1' THEN
        RETURN NULL;
    END IF;

    PERFORM set_config('storage.gc.prefixes', '1', true);

    SELECT COALESCE(array_agg(d.bucket_id), '{}'),
           COALESCE(array_agg(d.name), '{}')
    INTO v_bucket_ids, v_names
    FROM deleted AS d
    WHERE d.name <> '';

    PERFORM storage.lock_top_prefixes(v_bucket_ids, v_names);
    PERFORM storage.delete_leaf_prefixes(v_bucket_ids, v_names);

    RETURN NULL;
END;
$$;


ALTER FUNCTION "storage"."prefixes_delete_cleanup"() OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."prefixes_insert_trigger"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    PERFORM "storage"."add_prefixes"(NEW."bucket_id", NEW."name");
    RETURN NEW;
END;
$$;


ALTER FUNCTION "storage"."prefixes_insert_trigger"() OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."search"("prefix" "text", "bucketname" "text", "limits" integer DEFAULT 100, "levels" integer DEFAULT 1, "offsets" integer DEFAULT 0, "search" "text" DEFAULT ''::"text", "sortcolumn" "text" DEFAULT 'name'::"text", "sortorder" "text" DEFAULT 'asc'::"text") RETURNS TABLE("name" "text", "id" "uuid", "updated_at" timestamp with time zone, "created_at" timestamp with time zone, "last_accessed_at" timestamp with time zone, "metadata" "jsonb")
    LANGUAGE "plpgsql"
    AS $$
declare
    can_bypass_rls BOOLEAN;
begin
    SELECT rolbypassrls
    INTO can_bypass_rls
    FROM pg_roles
    WHERE rolname = coalesce(nullif(current_setting('role', true), 'none'), current_user);

    IF can_bypass_rls THEN
        RETURN QUERY SELECT * FROM storage.search_v1_optimised(prefix, bucketname, limits, levels, offsets, search, sortcolumn, sortorder);
    ELSE
        RETURN QUERY SELECT * FROM storage.search_legacy_v1(prefix, bucketname, limits, levels, offsets, search, sortcolumn, sortorder);
    END IF;
end;
$$;


ALTER FUNCTION "storage"."search"("prefix" "text", "bucketname" "text", "limits" integer, "levels" integer, "offsets" integer, "search" "text", "sortcolumn" "text", "sortorder" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."search_legacy_v1"("prefix" "text", "bucketname" "text", "limits" integer DEFAULT 100, "levels" integer DEFAULT 1, "offsets" integer DEFAULT 0, "search" "text" DEFAULT ''::"text", "sortcolumn" "text" DEFAULT 'name'::"text", "sortorder" "text" DEFAULT 'asc'::"text") RETURNS TABLE("name" "text", "id" "uuid", "updated_at" timestamp with time zone, "created_at" timestamp with time zone, "last_accessed_at" timestamp with time zone, "metadata" "jsonb")
    LANGUAGE "plpgsql" STABLE
    AS $_$
declare
    v_order_by text;
    v_sort_order text;
begin
    case
        when sortcolumn = 'name' then
            v_order_by = 'name';
        when sortcolumn = 'updated_at' then
            v_order_by = 'updated_at';
        when sortcolumn = 'created_at' then
            v_order_by = 'created_at';
        when sortcolumn = 'last_accessed_at' then
            v_order_by = 'last_accessed_at';
        else
            v_order_by = 'name';
        end case;

    case
        when sortorder = 'asc' then
            v_sort_order = 'asc';
        when sortorder = 'desc' then
            v_sort_order = 'desc';
        else
            v_sort_order = 'asc';
        end case;

    v_order_by = v_order_by || ' ' || v_sort_order;

    return query execute
        'with folders as (
           select path_tokens[$1] as folder
           from storage.objects
             where objects.name ilike $2 || $3 || ''%''
               and bucket_id = $4
               and array_length(objects.path_tokens, 1) <> $1
           group by folder
           order by folder ' || v_sort_order || '
     )
     (select folder as "name",
            null as id,
            null as updated_at,
            null as created_at,
            null as last_accessed_at,
            null as metadata from folders)
     union all
     (select path_tokens[$1] as "name",
            id,
            updated_at,
            created_at,
            last_accessed_at,
            metadata
     from storage.objects
     where objects.name ilike $2 || $3 || ''%''
       and bucket_id = $4
       and array_length(objects.path_tokens, 1) = $1
     order by ' || v_order_by || ')
     limit $5
     offset $6' using levels, prefix, search, bucketname, limits, offsets;
end;
$_$;


ALTER FUNCTION "storage"."search_legacy_v1"("prefix" "text", "bucketname" "text", "limits" integer, "levels" integer, "offsets" integer, "search" "text", "sortcolumn" "text", "sortorder" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."search_v1_optimised"("prefix" "text", "bucketname" "text", "limits" integer DEFAULT 100, "levels" integer DEFAULT 1, "offsets" integer DEFAULT 0, "search" "text" DEFAULT ''::"text", "sortcolumn" "text" DEFAULT 'name'::"text", "sortorder" "text" DEFAULT 'asc'::"text") RETURNS TABLE("name" "text", "id" "uuid", "updated_at" timestamp with time zone, "created_at" timestamp with time zone, "last_accessed_at" timestamp with time zone, "metadata" "jsonb")
    LANGUAGE "plpgsql" STABLE
    AS $_$
declare
    v_order_by text;
    v_sort_order text;
begin
    case
        when sortcolumn = 'name' then
            v_order_by = 'name';
        when sortcolumn = 'updated_at' then
            v_order_by = 'updated_at';
        when sortcolumn = 'created_at' then
            v_order_by = 'created_at';
        when sortcolumn = 'last_accessed_at' then
            v_order_by = 'last_accessed_at';
        else
            v_order_by = 'name';
        end case;

    case
        when sortorder = 'asc' then
            v_sort_order = 'asc';
        when sortorder = 'desc' then
            v_sort_order = 'desc';
        else
            v_sort_order = 'asc';
        end case;

    v_order_by = v_order_by || ' ' || v_sort_order;

    return query execute
        'with folders as (
           select (string_to_array(name, ''/''))[level] as name
           from storage.prefixes
             where lower(prefixes.name) like lower($2 || $3) || ''%''
               and bucket_id = $4
               and level = $1
           order by name ' || v_sort_order || '
     )
     (select name,
            null as id,
            null as updated_at,
            null as created_at,
            null as last_accessed_at,
            null as metadata from folders)
     union all
     (select path_tokens[level] as "name",
            id,
            updated_at,
            created_at,
            last_accessed_at,
            metadata
     from storage.objects
     where lower(objects.name) like lower($2 || $3) || ''%''
       and bucket_id = $4
       and level = $1
     order by ' || v_order_by || ')
     limit $5
     offset $6' using levels, prefix, search, bucketname, limits, offsets;
end;
$_$;


ALTER FUNCTION "storage"."search_v1_optimised"("prefix" "text", "bucketname" "text", "limits" integer, "levels" integer, "offsets" integer, "search" "text", "sortcolumn" "text", "sortorder" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."search_v2"("prefix" "text", "bucket_name" "text", "limits" integer DEFAULT 100, "levels" integer DEFAULT 1, "start_after" "text" DEFAULT ''::"text", "sort_order" "text" DEFAULT 'asc'::"text", "sort_column" "text" DEFAULT 'name'::"text", "sort_column_after" "text" DEFAULT ''::"text") RETURNS TABLE("key" "text", "name" "text", "id" "uuid", "updated_at" timestamp with time zone, "created_at" timestamp with time zone, "last_accessed_at" timestamp with time zone, "metadata" "jsonb")
    LANGUAGE "plpgsql" STABLE
    AS $_$
DECLARE
    sort_col text;
    sort_ord text;
    cursor_op text;
    cursor_expr text;
    sort_expr text;
BEGIN
    -- Validate sort_order
    sort_ord := lower(sort_order);
    IF sort_ord NOT IN ('asc', 'desc') THEN
        sort_ord := 'asc';
    END IF;

    -- Determine cursor comparison operator
    IF sort_ord = 'asc' THEN
        cursor_op := '>';
    ELSE
        cursor_op := '<';
    END IF;
    
    sort_col := lower(sort_column);
    -- Validate sort column  
    IF sort_col IN ('updated_at', 'created_at') THEN
        cursor_expr := format(
            '($5 = '''' OR ROW(date_trunc(''milliseconds'', %I), name COLLATE "C") %s ROW(COALESCE(NULLIF($6, '''')::timestamptz, ''epoch''::timestamptz), $5))',
            sort_col, cursor_op
        );
        sort_expr := format(
            'COALESCE(date_trunc(''milliseconds'', %I), ''epoch''::timestamptz) %s, name COLLATE "C" %s',
            sort_col, sort_ord, sort_ord
        );
    ELSE
        cursor_expr := format('($5 = '''' OR name COLLATE "C" %s $5)', cursor_op);
        sort_expr := format('name COLLATE "C" %s', sort_ord);
    END IF;

    RETURN QUERY EXECUTE format(
        $sql$
        SELECT * FROM (
            (
                SELECT
                    split_part(name, '/', $4) AS key,
                    name,
                    NULL::uuid AS id,
                    updated_at,
                    created_at,
                    NULL::timestamptz AS last_accessed_at,
                    NULL::jsonb AS metadata
                FROM storage.prefixes
                WHERE name COLLATE "C" LIKE $1 || '%%'
                    AND bucket_id = $2
                    AND level = $4
                    AND %s
                ORDER BY %s
                LIMIT $3
            )
            UNION ALL
            (
                SELECT
                    split_part(name, '/', $4) AS key,
                    name,
                    id,
                    updated_at,
                    created_at,
                    last_accessed_at,
                    metadata
                FROM storage.objects
                WHERE name COLLATE "C" LIKE $1 || '%%'
                    AND bucket_id = $2
                    AND level = $4
                    AND %s
                ORDER BY %s
                LIMIT $3
            )
        ) obj
        ORDER BY %s
        LIMIT $3
        $sql$,
        cursor_expr,    -- prefixes WHERE
        sort_expr,      -- prefixes ORDER BY
        cursor_expr,    -- objects WHERE
        sort_expr,      -- objects ORDER BY
        sort_expr       -- final ORDER BY
    )
    USING prefix, bucket_name, limits, levels, start_after, sort_column_after;
END;
$_$;


ALTER FUNCTION "storage"."search_v2"("prefix" "text", "bucket_name" "text", "limits" integer, "levels" integer, "start_after" "text", "sort_order" "text", "sort_column" "text", "sort_column_after" "text") OWNER TO "supabase_storage_admin";


CREATE OR REPLACE FUNCTION "storage"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW; 
END;
$$;


ALTER FUNCTION "storage"."update_updated_at_column"() OWNER TO "supabase_storage_admin";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."account_users" (
    "account_id" "uuid" NOT NULL,
    "user_uid" "uuid" NOT NULL,
    "role" "text" DEFAULT 'employee'::"text" NOT NULL,
    "disabled" boolean DEFAULT false NOT NULL,
    "email" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "local_id" bigint
);


ALTER TABLE "public"."account_users" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."accounts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "frozen" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."accounts" OWNER TO "postgres";


COMMENT ON TABLE "public"."accounts" IS 'عيادات/حسابات التطبيق';



CREATE TABLE IF NOT EXISTS "public"."alert_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "item_id" "uuid",
    "threshold" double precision,
    "notify_time" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "is_enabled" boolean DEFAULT true NOT NULL,
    "last_triggered" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."alert_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."appointments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "patient_id" "uuid",
    "appointment_time" timestamp with time zone,
    "status" "text",
    "notes" "text",
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."appointments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."chat_attachments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "message_id" "uuid" NOT NULL,
    "bucket" "text" DEFAULT 'chat-attachments'::"text" NOT NULL,
    "path" "text" NOT NULL,
    "mime_type" "text",
    "size_bytes" bigint DEFAULT 0 NOT NULL,
    "width" integer,
    "height" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."chat_attachments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."chat_conversations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid",
    "is_group" boolean DEFAULT false NOT NULL,
    "title" "text",
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_msg_at" timestamp with time zone,
    "last_msg_snippet" "text"
);


ALTER TABLE "public"."chat_conversations" OWNER TO "postgres";


COMMENT ON COLUMN "public"."chat_conversations"."account_id" IS 'معرّف الحساب (clinic/account) المرتبطة به المحادثة.';



CREATE TABLE IF NOT EXISTS "public"."chat_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "conversation_id" "uuid" NOT NULL,
    "sender_uid" "uuid" NOT NULL,
    "sender_email" "text",
    "kind" "text" DEFAULT 'text'::"text" NOT NULL,
    "body" "text",
    "edited" boolean DEFAULT false NOT NULL,
    "deleted" boolean DEFAULT false NOT NULL,
    "deleted_at" timestamp with time zone,
    "edited_at" timestamp with time zone,
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "patient_id" "text",
    "account_id" "uuid",
    "device_id" "text",
    "local_id" bigint,
    "reply_to_message_id" "uuid",
    "reply_to_snippet" "text",
    "mentions" "jsonb"
);


ALTER TABLE "public"."chat_messages" OWNER TO "postgres";


COMMENT ON COLUMN "public"."chat_messages"."account_id" IS 'حقل اختياري لتجميع الرسائل حسب الحساب (clinic/account). يُستخدم ضمن triplet مع device_id/local_id.';



COMMENT ON COLUMN "public"."chat_messages"."device_id" IS 'مُعرّف الجهاز/العميل المرسل (اختياري). جزء من triplet لمطابقة الرسائل محليًا.';



COMMENT ON COLUMN "public"."chat_messages"."local_id" IS 'مُعرّف محلي متزايد (BIGINT) داخل الجهاز/الجلسة، يُستخدم لتجنّب التكرار أثناء الإرسال.';



CREATE TABLE IF NOT EXISTS "public"."chat_participants" (
    "conversation_id" "uuid" NOT NULL,
    "user_uid" "uuid" NOT NULL,
    "role" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."chat_participants" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."chat_reactions" (
    "message_id" "uuid" NOT NULL,
    "user_uid" "uuid" NOT NULL,
    "emoji" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "chat_reactions_emoji_check" CHECK ((("char_length"("emoji") >= 1) AND ("char_length"("emoji") <= 16)))
);


ALTER TABLE "public"."chat_reactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."chat_reads" (
    "conversation_id" "uuid" NOT NULL,
    "user_uid" "uuid" NOT NULL,
    "last_read_message_id" "uuid",
    "last_read_at" timestamp with time zone DEFAULT '1970-01-01 00:00:00+00'::timestamp with time zone NOT NULL
);


ALTER TABLE "public"."chat_reads" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."clinics" AS
 SELECT "id",
    "name",
    "frozen",
    "created_at"
   FROM "public"."accounts";


ALTER VIEW "public"."clinics" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."complaints" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "title" "text",
    "description" "text",
    "status" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."complaints" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."consumption_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "type" "text",
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."consumption_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."consumptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "patient_id" "text",
    "item_id" "text",
    "quantity" integer,
    "date" timestamp with time zone,
    "amount" double precision,
    "note" "text",
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."consumptions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."doctors" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "employee_id" "uuid",
    "name" "text",
    "specialization" "text",
    "phone_number" "text",
    "start_time" timestamp with time zone,
    "end_time" timestamp with time zone,
    "print_counter" integer,
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."doctors" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."drugs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "name" "text" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."drugs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."employees" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "name" "text",
    "identity_number" "text",
    "phone_number" "text",
    "job_title" "text",
    "address" "text",
    "marital_status" "text",
    "basic_salary" double precision,
    "final_salary" double precision,
    "is_doctor" boolean,
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."employees" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."employees_discounts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "employee_id" "uuid",
    "discount_date_time" timestamp with time zone,
    "amount" double precision,
    "notes" "text",
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."employees_discounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."employees_loans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "employee_id" "uuid",
    "loan_date_time" timestamp with time zone,
    "final_salary" double precision,
    "ratio_sum" double precision,
    "loan_amount" double precision,
    "leftover" double precision,
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."employees_loans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."employees_salaries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "employee_id" "uuid",
    "year" integer,
    "month" integer,
    "final_salary" double precision,
    "ratio_sum" double precision,
    "total_loans" double precision,
    "net_pay" double precision,
    "is_paid" boolean,
    "payment_date" timestamp with time zone,
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."employees_salaries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."financial_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "transaction_type" "text",
    "operation" "text",
    "amount" double precision,
    "employee_id" "text",
    "description" "text",
    "modification_details" "text",
    "timestamp" timestamp with time zone,
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."financial_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."item_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "name" "text",
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."item_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "type_id" "uuid",
    "name" "text",
    "stock" double precision,
    "price" double precision,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."medical_services" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "name" "text",
    "cost" double precision,
    "service_type" "text",
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."medical_services" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."patient_services" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "patient_id" "uuid",
    "service_id" "uuid",
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "service_name" "text" DEFAULT ''::"text" NOT NULL,
    "service_cost" numeric DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."patient_services" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."patients" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "name" "text",
    "age" smallint,
    "diagnosis" "text",
    "phone_number" "text",
    "register_date" "date",
    "paid_amount" numeric DEFAULT 0 NOT NULL,
    "remaining" numeric DEFAULT 0 NOT NULL,
    "health_status" "text",
    "notes" "text",
    "preferences" "text",
    "doctor_id" "uuid",
    "doctor_name" "text",
    "doctor_specialization" "text",
    "service_type" "text",
    "service_id" "uuid",
    "service_name" "text",
    "service_cost" numeric,
    "doctor_share" numeric DEFAULT 0 NOT NULL,
    "doctor_input" numeric DEFAULT 0 NOT NULL,
    "tower_share" numeric DEFAULT 0 NOT NULL,
    "department_share" numeric DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_deleted" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."patients" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."prescription_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "prescription_id" "uuid",
    "drug_id" "uuid",
    "days" integer,
    "times_per_day" integer,
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."prescription_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."prescriptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "patient_id" "uuid",
    "doctor_id" "uuid",
    "record_date" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."prescriptions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "account_id" "uuid",
    "role" "text" DEFAULT 'employee'::"text" NOT NULL,
    "display_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."purchases" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "date" timestamp with time zone,
    "item_id" "uuid",
    "quantity" integer,
    "total" double precision,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."purchases" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."returns" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "date" timestamp with time zone,
    "patient_name" "text",
    "phone_number" "text",
    "diagnosis" "text",
    "remaining" double precision,
    "age" integer,
    "doctor" "text",
    "notes" "text",
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."returns" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."service_doctor_share" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "local_id" bigint,
    "service_id" "uuid",
    "doctor_id" "uuid",
    "share_percentage" double precision,
    "tower_share_percentage" double precision,
    "is_hidden" boolean,
    "device_id" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."service_doctor_share" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."super_admins" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "account_id" "uuid",
    "device_id" "text",
    "local_id" bigint,
    "email" "text",
    "user_uid" "uuid"
);


ALTER TABLE "public"."super_admins" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_chat_last_message" AS
 SELECT "c"."id" AS "conversation_id",
    "lm"."id" AS "last_message_id",
    "lm"."kind" AS "last_message_kind",
    "lm"."body" AS "last_message_body",
    "lm"."created_at" AS "last_message_created_at"
   FROM ("public"."chat_conversations" "c"
     LEFT JOIN LATERAL ( SELECT "m"."id",
            "m"."kind",
            "m"."body",
            "m"."created_at"
           FROM "public"."chat_messages" "m"
          WHERE (("m"."conversation_id" = "c"."id") AND (COALESCE("m"."deleted", false) = false))
          ORDER BY "m"."created_at" DESC
         LIMIT 1) "lm" ON (true));


ALTER VIEW "public"."v_chat_last_message" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_chat_last_message" IS 'Latest non-deleted message per conversation.';



CREATE OR REPLACE VIEW "public"."v_chat_reads_for_me" AS
 SELECT "conversation_id",
    "last_read_message_id",
    "last_read_at"
   FROM "public"."chat_reads" "r"
  WHERE ("user_uid" = "auth"."uid"());


ALTER VIEW "public"."v_chat_reads_for_me" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_chat_reads_for_me" IS 'Per-conversation last read state for the current authenticated user (via auth.uid()).';



CREATE OR REPLACE VIEW "public"."v_chat_conversations_for_me" AS
 WITH "mine" AS (
         SELECT "p"."conversation_id"
           FROM "public"."chat_participants" "p"
          WHERE ("p"."user_uid" = "auth"."uid"())
        ), "unread" AS (
         SELECT "c_1"."id" AS "conversation_id",
            "r"."last_read_at",
            (( SELECT "count"(1) AS "count"
                   FROM "public"."chat_messages" "m_1"
                  WHERE (("m_1"."conversation_id" = "c_1"."id") AND (COALESCE("m_1"."deleted", false) = false) AND (("r"."last_read_at" IS NULL) OR ("m_1"."created_at" > "r"."last_read_at")))))::integer AS "unread_count"
           FROM ("public"."chat_conversations" "c_1"
             LEFT JOIN "public"."v_chat_reads_for_me" "r" ON (("r"."conversation_id" = "c_1"."id")))
        )
 SELECT "c"."id",
    "c"."account_id",
    "c"."is_group",
    "c"."title",
    "c"."created_by",
    "c"."created_at",
    "c"."updated_at",
    "c"."last_msg_at",
    "c"."last_msg_snippet",
    "lm"."last_message_id",
    "lm"."last_message_kind",
    "lm"."last_message_body",
    "lm"."last_message_created_at",
    "u"."last_read_at",
    "u"."unread_count",
        CASE
            WHEN ("lm"."last_message_kind" = 'image'::"text") THEN '📷 صورة'::"text"
            WHEN (("lm"."last_message_body" IS NULL) OR ("btrim"("lm"."last_message_body") = ''::"text")) THEN NULL::"text"
            WHEN ("char_length"("lm"."last_message_body") > 64) THEN ("substr"("lm"."last_message_body", 1, 64) || '…'::"text")
            ELSE "lm"."last_message_body"
        END AS "last_message_text"
   FROM ((("public"."chat_conversations" "c"
     JOIN "mine" "m" ON (("m"."conversation_id" = "c"."id")))
     LEFT JOIN "public"."v_chat_last_message" "lm" ON (("lm"."conversation_id" = "c"."id")))
     LEFT JOIN "unread" "u" ON (("u"."conversation_id" = "c"."id")));


ALTER VIEW "public"."v_chat_conversations_for_me" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_chat_conversations_for_me" IS 'Conversations for current user (member via chat_participants + auth.uid()) with last message and unread counters.';



CREATE OR REPLACE VIEW "public"."v_chat_messages_with_attachments" AS
 SELECT "m"."id",
    "m"."conversation_id",
    "m"."sender_uid",
    "m"."sender_email",
    "m"."kind",
    "m"."body",
    "m"."created_at",
    "m"."edited",
    "m"."deleted",
    "m"."edited_at",
    "m"."deleted_at",
    COALESCE("jsonb_agg"("jsonb_build_object"('id', "a"."id", 'message_id', "a"."message_id", 'bucket', "a"."bucket", 'path', "a"."path", 'mime_type', "a"."mime_type", 'size_bytes', "a"."size_bytes", 'width', "a"."width", 'height', "a"."height", 'created_at', "a"."created_at")) FILTER (WHERE ("a"."id" IS NOT NULL)), '[]'::"jsonb") AS "attachments"
   FROM ("public"."chat_messages" "m"
     LEFT JOIN "public"."chat_attachments" "a" ON (("a"."message_id" = "m"."id")))
  GROUP BY "m"."id", "m"."conversation_id", "m"."sender_uid", "m"."sender_email", "m"."kind", "m"."body", "m"."created_at", "m"."edited", "m"."deleted", "m"."edited_at", "m"."deleted_at";


ALTER VIEW "public"."v_chat_messages_with_attachments" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_chat_messages_with_attachments" IS 'Chat messages with attachments aggregated as JSONB array.';



CREATE TABLE IF NOT EXISTS "storage"."buckets" (
    "id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "owner" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "public" boolean DEFAULT false,
    "avif_autodetection" boolean DEFAULT false,
    "file_size_limit" bigint,
    "allowed_mime_types" "text"[],
    "owner_id" "text",
    "type" "storage"."buckettype" DEFAULT 'STANDARD'::"storage"."buckettype" NOT NULL
);


ALTER TABLE "storage"."buckets" OWNER TO "supabase_storage_admin";


COMMENT ON COLUMN "storage"."buckets"."owner" IS 'Field is deprecated, use owner_id instead';



CREATE TABLE IF NOT EXISTS "storage"."buckets_analytics" (
    "id" "text" NOT NULL,
    "type" "storage"."buckettype" DEFAULT 'ANALYTICS'::"storage"."buckettype" NOT NULL,
    "format" "text" DEFAULT 'ICEBERG'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "storage"."buckets_analytics" OWNER TO "supabase_storage_admin";


CREATE TABLE IF NOT EXISTS "storage"."migrations" (
    "id" integer NOT NULL,
    "name" character varying(100) NOT NULL,
    "hash" character varying(40) NOT NULL,
    "executed_at" timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE "storage"."migrations" OWNER TO "supabase_storage_admin";


CREATE TABLE IF NOT EXISTS "storage"."objects" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "bucket_id" "text",
    "name" "text",
    "owner" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "last_accessed_at" timestamp with time zone DEFAULT "now"(),
    "metadata" "jsonb",
    "path_tokens" "text"[] GENERATED ALWAYS AS ("string_to_array"("name", '/'::"text")) STORED,
    "version" "text",
    "owner_id" "text",
    "user_metadata" "jsonb",
    "level" integer
);


ALTER TABLE "storage"."objects" OWNER TO "supabase_storage_admin";


COMMENT ON COLUMN "storage"."objects"."owner" IS 'Field is deprecated, use owner_id instead';



CREATE TABLE IF NOT EXISTS "storage"."prefixes" (
    "bucket_id" "text" NOT NULL,
    "name" "text" NOT NULL COLLATE "pg_catalog"."C",
    "level" integer GENERATED ALWAYS AS ("storage"."get_level"("name")) STORED NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "storage"."prefixes" OWNER TO "supabase_storage_admin";


CREATE TABLE IF NOT EXISTS "storage"."s3_multipart_uploads" (
    "id" "text" NOT NULL,
    "in_progress_size" bigint DEFAULT 0 NOT NULL,
    "upload_signature" "text" NOT NULL,
    "bucket_id" "text" NOT NULL,
    "key" "text" NOT NULL COLLATE "pg_catalog"."C",
    "version" "text" NOT NULL,
    "owner_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_metadata" "jsonb"
);


ALTER TABLE "storage"."s3_multipart_uploads" OWNER TO "supabase_storage_admin";


CREATE TABLE IF NOT EXISTS "storage"."s3_multipart_uploads_parts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "upload_id" "text" NOT NULL,
    "size" bigint DEFAULT 0 NOT NULL,
    "part_number" integer NOT NULL,
    "bucket_id" "text" NOT NULL,
    "key" "text" NOT NULL COLLATE "pg_catalog"."C",
    "etag" "text" NOT NULL,
    "owner_id" "text",
    "version" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "storage"."s3_multipart_uploads_parts" OWNER TO "supabase_storage_admin";


ALTER TABLE ONLY "public"."account_users"
    ADD CONSTRAINT "account_users_pkey" PRIMARY KEY ("account_id", "user_uid");



ALTER TABLE ONLY "public"."accounts"
    ADD CONSTRAINT "accounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."alert_settings"
    ADD CONSTRAINT "alert_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chat_attachments"
    ADD CONSTRAINT "chat_attachments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chat_conversations"
    ADD CONSTRAINT "chat_conversations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chat_messages"
    ADD CONSTRAINT "chat_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."chat_participants"
    ADD CONSTRAINT "chat_participants_pkey" PRIMARY KEY ("conversation_id", "user_uid");



ALTER TABLE ONLY "public"."chat_reactions"
    ADD CONSTRAINT "chat_reactions_pkey" PRIMARY KEY ("message_id", "user_uid", "emoji");



ALTER TABLE ONLY "public"."chat_reads"
    ADD CONSTRAINT "chat_reads_pkey" PRIMARY KEY ("conversation_id", "user_uid");



ALTER TABLE ONLY "public"."complaints"
    ADD CONSTRAINT "complaints_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."consumption_types"
    ADD CONSTRAINT "consumption_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."consumptions"
    ADD CONSTRAINT "consumptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."doctors"
    ADD CONSTRAINT "doctors_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."drugs"
    ADD CONSTRAINT "drugs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employees_discounts"
    ADD CONSTRAINT "employees_discounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employees_loans"
    ADD CONSTRAINT "employees_loans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employees_salaries"
    ADD CONSTRAINT "employees_salaries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."financial_logs"
    ADD CONSTRAINT "financial_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."item_types"
    ADD CONSTRAINT "item_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."medical_services"
    ADD CONSTRAINT "medical_services_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."patient_services"
    ADD CONSTRAINT "patient_services_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."patients"
    ADD CONSTRAINT "patients_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."prescription_items"
    ADD CONSTRAINT "prescription_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."prescriptions"
    ADD CONSTRAINT "prescriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."purchases"
    ADD CONSTRAINT "purchases_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."returns"
    ADD CONSTRAINT "returns_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."service_doctor_share"
    ADD CONSTRAINT "service_doctor_share_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."super_admins"
    ADD CONSTRAINT "super_admins_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."super_admins"
    ADD CONSTRAINT "super_admins_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."super_admins"
    ADD CONSTRAINT "super_admins_user_uid_key" UNIQUE ("user_uid");



ALTER TABLE ONLY "storage"."buckets_analytics"
    ADD CONSTRAINT "buckets_analytics_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "storage"."buckets"
    ADD CONSTRAINT "buckets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "storage"."migrations"
    ADD CONSTRAINT "migrations_name_key" UNIQUE ("name");



ALTER TABLE ONLY "storage"."migrations"
    ADD CONSTRAINT "migrations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "storage"."objects"
    ADD CONSTRAINT "objects_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "storage"."prefixes"
    ADD CONSTRAINT "prefixes_pkey" PRIMARY KEY ("bucket_id", "level", "name");



ALTER TABLE ONLY "storage"."s3_multipart_uploads_parts"
    ADD CONSTRAINT "s3_multipart_uploads_parts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "storage"."s3_multipart_uploads"
    ADD CONSTRAINT "s3_multipart_uploads_pkey" PRIMARY KEY ("id");



CREATE UNIQUE INDEX "account_users_account_device_local_idx" ON "public"."account_users" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "account_users_account_idx" ON "public"."account_users" USING "btree" ("account_id");



CREATE INDEX "account_users_role_idx" ON "public"."account_users" USING "btree" ("role");



CREATE INDEX "account_users_user_idx" ON "public"."account_users" USING "btree" ("user_uid");



CREATE UNIQUE INDEX "alert_settings_account_device_local_idx" ON "public"."alert_settings" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "alert_settings_account_idx" ON "public"."alert_settings" USING "btree" ("account_id");



CREATE UNIQUE INDEX "appointments_account_device_local_idx" ON "public"."appointments" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "appointments_account_idx" ON "public"."appointments" USING "btree" ("account_id");



CREATE INDEX "chat_attachments_bucket_path_idx" ON "public"."chat_attachments" USING "btree" ("bucket", "path");



CREATE INDEX "chat_attachments_msg_idx" ON "public"."chat_attachments" USING "btree" ("message_id");



CREATE INDEX "chat_conversations_last_msg_at_idx" ON "public"."chat_conversations" USING "btree" ("last_msg_at");



CREATE INDEX "chat_messages_conv_created_idx" ON "public"."chat_messages" USING "btree" ("conversation_id", "created_at");



CREATE INDEX "chat_messages_created_idx" ON "public"."chat_messages" USING "btree" ("created_at");



CREATE INDEX "chat_messages_reply_to_idx" ON "public"."chat_messages" USING "btree" ("reply_to_message_id");



CREATE INDEX "chat_participants_conv_user_idx" ON "public"."chat_participants" USING "btree" ("conversation_id", "user_uid");



CREATE INDEX "chat_participants_user_idx" ON "public"."chat_participants" USING "btree" ("user_uid");



CREATE INDEX "chat_reactions_user_created_idx" ON "public"."chat_reactions" USING "btree" ("user_uid", "created_at" DESC);



CREATE INDEX "chat_reads_conv_user_idx" ON "public"."chat_reads" USING "btree" ("conversation_id", "user_uid");



CREATE INDEX "chat_reads_user_idx" ON "public"."chat_reads" USING "btree" ("user_uid");



CREATE UNIQUE INDEX "complaints_account_device_local_idx" ON "public"."complaints" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "complaints_account_idx" ON "public"."complaints" USING "btree" ("account_id");



CREATE UNIQUE INDEX "consumption_types_account_device_local_idx" ON "public"."consumption_types" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "consumption_types_account_idx" ON "public"."consumption_types" USING "btree" ("account_id");



CREATE UNIQUE INDEX "consumptions_account_device_local_idx" ON "public"."consumptions" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "consumptions_account_idx" ON "public"."consumptions" USING "btree" ("account_id");



CREATE UNIQUE INDEX "doctors_account_device_local_idx" ON "public"."doctors" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "doctors_account_idx" ON "public"."doctors" USING "btree" ("account_id");



CREATE UNIQUE INDEX "drugs_account_device_local_idx" ON "public"."drugs" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "drugs_account_idx" ON "public"."drugs" USING "btree" ("account_id");



CREATE UNIQUE INDEX "employees_account_device_local_idx" ON "public"."employees" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "employees_account_idx" ON "public"."employees" USING "btree" ("account_id");



CREATE UNIQUE INDEX "employees_discounts_account_device_local_idx" ON "public"."employees_discounts" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "employees_discounts_account_idx" ON "public"."employees_discounts" USING "btree" ("account_id");



CREATE UNIQUE INDEX "employees_loans_account_device_local_idx" ON "public"."employees_loans" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "employees_loans_account_idx" ON "public"."employees_loans" USING "btree" ("account_id");



CREATE UNIQUE INDEX "employees_salaries_account_device_local_idx" ON "public"."employees_salaries" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "employees_salaries_account_idx" ON "public"."employees_salaries" USING "btree" ("account_id");



CREATE UNIQUE INDEX "financial_logs_account_device_local_idx" ON "public"."financial_logs" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "financial_logs_account_idx" ON "public"."financial_logs" USING "btree" ("account_id");



CREATE INDEX "idx_chat_attachments_message" ON "public"."chat_attachments" USING "btree" ("message_id");



CREATE INDEX "idx_chat_conversations_account" ON "public"."chat_conversations" USING "btree" ("account_id");



CREATE INDEX "idx_chat_conversations_last_msg_at" ON "public"."chat_conversations" USING "btree" ("last_msg_at" DESC);



CREATE INDEX "idx_chat_messages_conv_created_at" ON "public"."chat_messages" USING "btree" ("conversation_id", "created_at");



CREATE INDEX "idx_chat_messages_conv_id" ON "public"."chat_messages" USING "btree" ("conversation_id", "id");



CREATE INDEX "idx_chat_messages_kind_deleted" ON "public"."chat_messages" USING "btree" ("kind", "deleted");



CREATE INDEX "idx_chat_messages_sender" ON "public"."chat_messages" USING "btree" ("sender_uid");



CREATE INDEX "idx_chat_participants_conv_uid" ON "public"."chat_participants" USING "btree" ("conversation_id", "user_uid");



CREATE INDEX "idx_chat_reads_conv_uid" ON "public"."chat_reads" USING "btree" ("conversation_id", "user_uid");



CREATE UNIQUE INDEX "item_types_account_device_local_idx" ON "public"."item_types" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "item_types_account_idx" ON "public"."item_types" USING "btree" ("account_id");



CREATE UNIQUE INDEX "item_types_unique_name" ON "public"."item_types" USING "btree" ("account_id", "lower"("name"));



CREATE UNIQUE INDEX "items_account_device_local_idx" ON "public"."items" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "items_account_idx" ON "public"."items" USING "btree" ("account_id");



CREATE UNIQUE INDEX "items_unique_type_name" ON "public"."items" USING "btree" ("account_id", "type_id", "lower"("name"));



CREATE UNIQUE INDEX "medical_services_account_device_local_idx" ON "public"."medical_services" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "medical_services_account_idx" ON "public"."medical_services" USING "btree" ("account_id");



CREATE UNIQUE INDEX "patient_services_account_device_local_idx" ON "public"."patient_services" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "patient_services_account_idx" ON "public"."patient_services" USING "btree" ("account_id");



CREATE UNIQUE INDEX "patients_account_device_local_idx" ON "public"."patients" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "patients_account_idx" ON "public"."patients" USING "btree" ("account_id");



CREATE UNIQUE INDEX "prescription_items_account_device_local_idx" ON "public"."prescription_items" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "prescription_items_account_idx" ON "public"."prescription_items" USING "btree" ("account_id");



CREATE UNIQUE INDEX "prescriptions_account_device_local_idx" ON "public"."prescriptions" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "prescriptions_account_idx" ON "public"."prescriptions" USING "btree" ("account_id");



CREATE INDEX "profiles_account_idx" ON "public"."profiles" USING "btree" ("account_id");



CREATE UNIQUE INDEX "purchases_account_device_local_idx" ON "public"."purchases" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "purchases_account_idx" ON "public"."purchases" USING "btree" ("account_id");



CREATE UNIQUE INDEX "returns_account_device_local_idx" ON "public"."returns" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "returns_account_idx" ON "public"."returns" USING "btree" ("account_id");



CREATE UNIQUE INDEX "service_doctor_share_account_device_local_idx" ON "public"."service_doctor_share" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "service_doctor_share_account_idx" ON "public"."service_doctor_share" USING "btree" ("account_id");



CREATE UNIQUE INDEX "service_doctor_share_unique" ON "public"."service_doctor_share" USING "btree" ("account_id", "service_id", "doctor_id");



CREATE UNIQUE INDEX "super_admins_account_device_local_idx" ON "public"."super_admins" USING "btree" ("account_id", "device_id", "local_id");



CREATE INDEX "super_admins_account_idx" ON "public"."super_admins" USING "btree" ("account_id");



CREATE UNIQUE INDEX "uix_drugs_account_lower_name" ON "public"."drugs" USING "btree" ("account_id", "lower"("name"));



CREATE UNIQUE INDEX "bname" ON "storage"."buckets" USING "btree" ("name");



CREATE UNIQUE INDEX "bucketid_objname" ON "storage"."objects" USING "btree" ("bucket_id", "name");



CREATE INDEX "idx_multipart_uploads_list" ON "storage"."s3_multipart_uploads" USING "btree" ("bucket_id", "key", "created_at");



CREATE UNIQUE INDEX "idx_name_bucket_level_unique" ON "storage"."objects" USING "btree" ("name" COLLATE "C", "bucket_id", "level");



CREATE INDEX "idx_objects_bucket_id_name" ON "storage"."objects" USING "btree" ("bucket_id", "name" COLLATE "C");



CREATE INDEX "idx_objects_lower_name" ON "storage"."objects" USING "btree" (("path_tokens"["level"]), "lower"("name") "text_pattern_ops", "bucket_id", "level");



CREATE INDEX "idx_prefixes_lower_name" ON "storage"."prefixes" USING "btree" ("bucket_id", "level", (("string_to_array"("name", '/'::"text"))["level"]), "lower"("name") "text_pattern_ops");



CREATE INDEX "name_prefix_search" ON "storage"."objects" USING "btree" ("name" "text_pattern_ops");



CREATE UNIQUE INDEX "objects_bucket_id_level_idx" ON "storage"."objects" USING "btree" ("bucket_id", "level", "name" COLLATE "C");



CREATE OR REPLACE TRIGGER "account_users_set_updated_at" BEFORE UPDATE ON "public"."account_users" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "alert_settings_set_updated_at" BEFORE UPDATE ON "public"."alert_settings" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "appointments_set_updated_at" BEFORE UPDATE ON "public"."appointments" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "complaints_set_updated_at" BEFORE UPDATE ON "public"."complaints" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "consumption_types_set_updated_at" BEFORE UPDATE ON "public"."consumption_types" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "consumptions_set_updated_at" BEFORE UPDATE ON "public"."consumptions" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "doctors_set_updated_at" BEFORE UPDATE ON "public"."doctors" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "drugs_set_updated_at" BEFORE UPDATE ON "public"."drugs" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "employees_discounts_set_updated_at" BEFORE UPDATE ON "public"."employees_discounts" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "employees_loans_set_updated_at" BEFORE UPDATE ON "public"."employees_loans" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "employees_salaries_set_updated_at" BEFORE UPDATE ON "public"."employees_salaries" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "employees_set_updated_at" BEFORE UPDATE ON "public"."employees" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "financial_logs_set_updated_at" BEFORE UPDATE ON "public"."financial_logs" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "item_types_set_updated_at" BEFORE UPDATE ON "public"."item_types" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "items_set_updated_at" BEFORE UPDATE ON "public"."items" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "medical_services_set_updated_at" BEFORE UPDATE ON "public"."medical_services" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "patient_services_set_updated_at" BEFORE UPDATE ON "public"."patient_services" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "patients_set_updated_at" BEFORE UPDATE ON "public"."patients" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "prescription_items_set_updated_at" BEFORE UPDATE ON "public"."prescription_items" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "prescriptions_set_updated_at" BEFORE UPDATE ON "public"."prescriptions" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "profiles_set_updated_at" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."tg_profiles_set_updated_at"();



CREATE OR REPLACE TRIGGER "purchases_set_updated_at" BEFORE UPDATE ON "public"."purchases" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "returns_set_updated_at" BEFORE UPDATE ON "public"."returns" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "service_doctor_share_set_updated_at" BEFORE UPDATE ON "public"."service_doctor_share" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_chat_messages_last_msg_del" AFTER DELETE ON "public"."chat_messages" FOR EACH ROW EXECUTE FUNCTION "public"."fn_chat_messages_touch_last_msg"();



CREATE OR REPLACE TRIGGER "trg_chat_messages_last_msg_upd" AFTER INSERT OR UPDATE OF "body", "kind", "deleted", "created_at" ON "public"."chat_messages" FOR EACH ROW EXECUTE FUNCTION "public"."fn_chat_messages_touch_last_msg"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."alert_settings" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."appointments" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."complaints" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."consumption_types" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."consumptions" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."doctors" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."drugs" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."employees" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."employees_discounts" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."employees_loans" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."employees_salaries" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."financial_logs" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."item_types" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."items" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."medical_services" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."patient_services" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."patients" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."prescription_items" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."prescriptions" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."purchases" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."returns" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "trg_touch_updated_at" BEFORE UPDATE ON "public"."service_doctor_share" FOR EACH ROW EXECUTE FUNCTION "public"."tg_touch_updated_at"();



CREATE OR REPLACE TRIGGER "enforce_bucket_name_length_trigger" BEFORE INSERT OR UPDATE OF "name" ON "storage"."buckets" FOR EACH ROW EXECUTE FUNCTION "storage"."enforce_bucket_name_length"();



CREATE OR REPLACE TRIGGER "objects_delete_delete_prefix" AFTER DELETE ON "storage"."objects" FOR EACH ROW EXECUTE FUNCTION "storage"."delete_prefix_hierarchy_trigger"();



CREATE OR REPLACE TRIGGER "objects_insert_create_prefix" BEFORE INSERT ON "storage"."objects" FOR EACH ROW EXECUTE FUNCTION "storage"."objects_insert_prefix_trigger"();



CREATE OR REPLACE TRIGGER "objects_update_create_prefix" BEFORE UPDATE ON "storage"."objects" FOR EACH ROW WHEN ((("new"."name" <> "old"."name") OR ("new"."bucket_id" <> "old"."bucket_id"))) EXECUTE FUNCTION "storage"."objects_update_prefix_trigger"();



CREATE OR REPLACE TRIGGER "prefixes_create_hierarchy" BEFORE INSERT ON "storage"."prefixes" FOR EACH ROW WHEN (("pg_trigger_depth"() < 1)) EXECUTE FUNCTION "storage"."prefixes_insert_trigger"();



CREATE OR REPLACE TRIGGER "prefixes_delete_hierarchy" AFTER DELETE ON "storage"."prefixes" FOR EACH ROW EXECUTE FUNCTION "storage"."delete_prefix_hierarchy_trigger"();



CREATE OR REPLACE TRIGGER "update_objects_updated_at" BEFORE UPDATE ON "storage"."objects" FOR EACH ROW EXECUTE FUNCTION "storage"."update_updated_at_column"();



ALTER TABLE ONLY "public"."account_users"
    ADD CONSTRAINT "account_users_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."account_users"
    ADD CONSTRAINT "account_users_user_uid_fkey" FOREIGN KEY ("user_uid") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."alert_settings"
    ADD CONSTRAINT "alert_settings_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."alert_settings"
    ADD CONSTRAINT "alert_settings_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."items"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."chat_attachments"
    ADD CONSTRAINT "chat_attachments_message_id_fkey" FOREIGN KEY ("message_id") REFERENCES "public"."chat_messages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chat_messages"
    ADD CONSTRAINT "chat_messages_conversation_id_fkey" FOREIGN KEY ("conversation_id") REFERENCES "public"."chat_conversations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chat_participants"
    ADD CONSTRAINT "chat_participants_conversation_id_fkey" FOREIGN KEY ("conversation_id") REFERENCES "public"."chat_conversations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chat_reactions"
    ADD CONSTRAINT "chat_reactions_message_id_fkey" FOREIGN KEY ("message_id") REFERENCES "public"."chat_messages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chat_reads"
    ADD CONSTRAINT "chat_reads_conversation_id_fkey" FOREIGN KEY ("conversation_id") REFERENCES "public"."chat_conversations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."complaints"
    ADD CONSTRAINT "complaints_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."consumption_types"
    ADD CONSTRAINT "consumption_types_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."consumptions"
    ADD CONSTRAINT "consumptions_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."doctors"
    ADD CONSTRAINT "doctors_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."doctors"
    ADD CONSTRAINT "doctors_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id");



ALTER TABLE ONLY "public"."drugs"
    ADD CONSTRAINT "drugs_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employees_discounts"
    ADD CONSTRAINT "employees_discounts_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employees_discounts"
    ADD CONSTRAINT "employees_discounts_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employees_loans"
    ADD CONSTRAINT "employees_loans_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employees_loans"
    ADD CONSTRAINT "employees_loans_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employees_salaries"
    ADD CONSTRAINT "employees_salaries_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employees_salaries"
    ADD CONSTRAINT "employees_salaries_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."financial_logs"
    ADD CONSTRAINT "financial_logs_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chat_attachments"
    ADD CONSTRAINT "fk_chat_attachments_message" FOREIGN KEY ("message_id") REFERENCES "public"."chat_messages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."chat_conversations"
    ADD CONSTRAINT "fk_chat_conversations_account" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."chat_reads"
    ADD CONSTRAINT "fk_chat_reads_conversation" FOREIGN KEY ("conversation_id") REFERENCES "public"."chat_conversations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."item_types"
    ADD CONSTRAINT "item_types_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_type_id_fkey" FOREIGN KEY ("type_id") REFERENCES "public"."item_types"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."medical_services"
    ADD CONSTRAINT "medical_services_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."patient_services"
    ADD CONSTRAINT "patient_services_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."patient_services"
    ADD CONSTRAINT "patient_services_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."patient_services"
    ADD CONSTRAINT "patient_services_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "public"."medical_services"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."patients"
    ADD CONSTRAINT "patients_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."prescription_items"
    ADD CONSTRAINT "prescription_items_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."prescription_items"
    ADD CONSTRAINT "prescription_items_drug_id_fkey" FOREIGN KEY ("drug_id") REFERENCES "public"."drugs"("id");



ALTER TABLE ONLY "public"."prescription_items"
    ADD CONSTRAINT "prescription_items_prescription_id_fkey" FOREIGN KEY ("prescription_id") REFERENCES "public"."prescriptions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."prescriptions"
    ADD CONSTRAINT "prescriptions_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."prescriptions"
    ADD CONSTRAINT "prescriptions_doctor_id_fkey" FOREIGN KEY ("doctor_id") REFERENCES "public"."doctors"("id");



ALTER TABLE ONLY "public"."prescriptions"
    ADD CONSTRAINT "prescriptions_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."purchases"
    ADD CONSTRAINT "purchases_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."purchases"
    ADD CONSTRAINT "purchases_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."items"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."returns"
    ADD CONSTRAINT "returns_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."service_doctor_share"
    ADD CONSTRAINT "service_doctor_share_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."service_doctor_share"
    ADD CONSTRAINT "service_doctor_share_doctor_id_fkey" FOREIGN KEY ("doctor_id") REFERENCES "public"."doctors"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."service_doctor_share"
    ADD CONSTRAINT "service_doctor_share_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "public"."medical_services"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "storage"."objects"
    ADD CONSTRAINT "objects_bucketId_fkey" FOREIGN KEY ("bucket_id") REFERENCES "storage"."buckets"("id");



ALTER TABLE ONLY "storage"."prefixes"
    ADD CONSTRAINT "prefixes_bucketId_fkey" FOREIGN KEY ("bucket_id") REFERENCES "storage"."buckets"("id");



ALTER TABLE ONLY "storage"."s3_multipart_uploads"
    ADD CONSTRAINT "s3_multipart_uploads_bucket_id_fkey" FOREIGN KEY ("bucket_id") REFERENCES "storage"."buckets"("id");



ALTER TABLE ONLY "storage"."s3_multipart_uploads_parts"
    ADD CONSTRAINT "s3_multipart_uploads_parts_bucket_id_fkey" FOREIGN KEY ("bucket_id") REFERENCES "storage"."buckets"("id");



ALTER TABLE ONLY "storage"."s3_multipart_uploads_parts"
    ADD CONSTRAINT "s3_multipart_uploads_parts_upload_id_fkey" FOREIGN KEY ("upload_id") REFERENCES "storage"."s3_multipart_uploads"("id") ON DELETE CASCADE;



ALTER TABLE "public"."account_users" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "account_users_mutate" ON "public"."account_users" TO "authenticated" USING (("public"."fn_is_super_admin"() = true)) WITH CHECK (("public"."fn_is_super_admin"() = true));



CREATE POLICY "account_users_select" ON "public"."account_users" FOR SELECT TO "authenticated" USING ((("public"."fn_is_super_admin"() = true) OR (("user_uid")::"text" = ("auth"."uid"())::"text") OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "account_users"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."accounts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "accounts_select" ON "public"."accounts" FOR SELECT TO "authenticated" USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "accounts"."id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."alert_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "alert_settings_delete_own" ON "public"."alert_settings" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "alert_settings"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "alert_settings_insert_own" ON "public"."alert_settings" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "alert_settings"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "alert_settings_select_own" ON "public"."alert_settings" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "alert_settings"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "alert_settings_update_own" ON "public"."alert_settings" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "alert_settings"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "alert_settings"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."appointments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "appointments_delete_own" ON "public"."appointments" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "appointments"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "appointments_insert_own" ON "public"."appointments" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "appointments"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "appointments_select_own" ON "public"."appointments" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "appointments"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "appointments_update_own" ON "public"."appointments" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "appointments"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "appointments"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "atts_delete_owner_message_or_super" ON "public"."chat_attachments" FOR DELETE TO "authenticated" USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."chat_messages" "m"
  WHERE (("m"."id" = "chat_attachments"."message_id") AND (("m"."sender_uid")::"text" = ("auth"."uid"())::"text"))))));



CREATE POLICY "atts_insert_if_participant_or_super" ON "public"."chat_attachments" FOR INSERT TO "authenticated" WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM ("public"."chat_messages" "m"
     JOIN "public"."chat_participants" "p" ON (("p"."conversation_id" = "m"."conversation_id")))
  WHERE (("m"."id" = "chat_attachments"."message_id") AND (("p"."user_uid")::"text" = ("auth"."uid"())::"text"))))));



CREATE POLICY "atts_select_if_participant_or_super" ON "public"."chat_attachments" FOR SELECT TO "authenticated" USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM ("public"."chat_messages" "m"
     JOIN "public"."chat_participants" "p" ON (("p"."conversation_id" = "m"."conversation_id")))
  WHERE (("m"."id" = "chat_attachments"."message_id") AND (("p"."user_uid")::"text" = ("auth"."uid"())::"text"))))));



ALTER TABLE "public"."chat_attachments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."chat_conversations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."chat_messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."chat_participants" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."chat_reactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."chat_reads" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."complaints" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "complaints_delete_own" ON "public"."complaints" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "complaints"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "complaints_insert_own" ON "public"."complaints" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "complaints"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "complaints_select_own" ON "public"."complaints" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "complaints"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "complaints_update_own" ON "public"."complaints" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "complaints"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "complaints"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."consumption_types" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "consumption_types_delete_own" ON "public"."consumption_types" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "consumption_types"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "consumption_types_insert_own" ON "public"."consumption_types" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "consumption_types"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "consumption_types_select_own" ON "public"."consumption_types" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "consumption_types"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "consumption_types_update_own" ON "public"."consumption_types" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "consumption_types"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "consumption_types"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."consumptions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "consumptions_delete_own" ON "public"."consumptions" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "consumptions"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "consumptions_insert_own" ON "public"."consumptions" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "consumptions"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "consumptions_select_own" ON "public"."consumptions" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "consumptions"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "consumptions_update_own" ON "public"."consumptions" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "consumptions"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "consumptions"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "conv_insert_creator_with_account_guard" ON "public"."chat_conversations" FOR INSERT TO "authenticated" WITH CHECK (((("created_by")::"text" = ("auth"."uid"())::"text") AND (("public"."fn_is_super_admin"() = true) OR ("account_id" IS NULL) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "chat_conversations"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND (COALESCE("au"."disabled", false) = false)))))));



CREATE POLICY "conv_select_participant_or_super" ON "public"."chat_conversations" FOR SELECT TO "authenticated" USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."chat_participants" "p"
  WHERE (("p"."conversation_id" = "chat_conversations"."id") AND (("p"."user_uid")::"text" = ("auth"."uid"())::"text"))))));



CREATE POLICY "conv_update_creator_or_super" ON "public"."chat_conversations" FOR UPDATE TO "authenticated" USING ((("public"."fn_is_super_admin"() = true) OR (("created_by")::"text" = ("auth"."uid"())::"text"))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR ("account_id" IS NULL) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "chat_conversations"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND (COALESCE("au"."disabled", false) = false))))));



ALTER TABLE "public"."doctors" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "doctors_delete_own" ON "public"."doctors" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "doctors"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "doctors_insert_own" ON "public"."doctors" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "doctors"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "doctors_select_own" ON "public"."doctors" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "doctors"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "doctors_update_own" ON "public"."doctors" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "doctors"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "doctors"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."drugs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "drugs_delete_own" ON "public"."drugs" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "drugs"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "drugs_insert_own" ON "public"."drugs" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "drugs"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "drugs_select_own" ON "public"."drugs" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "drugs"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "drugs_update_own" ON "public"."drugs" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "drugs"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "drugs"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."employees" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "employees_delete_own" ON "public"."employees" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."employees_discounts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "employees_discounts_delete_own" ON "public"."employees_discounts" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees_discounts"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "employees_discounts_insert_own" ON "public"."employees_discounts" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees_discounts"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "employees_discounts_select_own" ON "public"."employees_discounts" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees_discounts"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "employees_discounts_update_own" ON "public"."employees_discounts" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees_discounts"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees_discounts"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "employees_insert_own" ON "public"."employees" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."employees_loans" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "employees_loans_delete_own" ON "public"."employees_loans" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees_loans"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "employees_loans_insert_own" ON "public"."employees_loans" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees_loans"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "employees_loans_select_own" ON "public"."employees_loans" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees_loans"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "employees_loans_update_own" ON "public"."employees_loans" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees_loans"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees_loans"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."employees_salaries" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "employees_salaries_delete_own" ON "public"."employees_salaries" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees_salaries"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "employees_salaries_insert_own" ON "public"."employees_salaries" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees_salaries"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "employees_salaries_select_own" ON "public"."employees_salaries" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees_salaries"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "employees_salaries_update_own" ON "public"."employees_salaries" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees_salaries"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees_salaries"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "employees_select_own" ON "public"."employees" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "employees_update_own" ON "public"."employees" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "employees"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."financial_logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "financial_logs_delete_own" ON "public"."financial_logs" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "financial_logs"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "financial_logs_insert_own" ON "public"."financial_logs" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "financial_logs"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "financial_logs_select_own" ON "public"."financial_logs" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "financial_logs"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "financial_logs_update_own" ON "public"."financial_logs" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "financial_logs"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "financial_logs"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."item_types" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "item_types_delete_own" ON "public"."item_types" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "item_types"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "item_types_insert_own" ON "public"."item_types" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "item_types"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "item_types_select_own" ON "public"."item_types" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "item_types"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "item_types_update_own" ON "public"."item_types" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "item_types"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "item_types"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "items_delete_own" ON "public"."items" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "items"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "items_insert_own" ON "public"."items" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "items"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "items_select_own" ON "public"."items" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "items"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "items_update_own" ON "public"."items" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "items"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "items"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."medical_services" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "medical_services_delete_own" ON "public"."medical_services" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "medical_services"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "medical_services_insert_own" ON "public"."medical_services" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "medical_services"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "medical_services_select_own" ON "public"."medical_services" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "medical_services"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "medical_services_update_own" ON "public"."medical_services" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "medical_services"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "medical_services"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "msgs_delete_owner_or_super" ON "public"."chat_messages" FOR DELETE TO "authenticated" USING ((("public"."fn_is_super_admin"() = true) OR (("sender_uid")::"text" = ("auth"."uid"())::"text")));



CREATE POLICY "msgs_insert_sender_is_self_and_member" ON "public"."chat_messages" FOR INSERT TO "authenticated" WITH CHECK (((("sender_uid")::"text" = ("auth"."uid"())::"text") AND (EXISTS ( SELECT 1
   FROM "public"."chat_participants" "p"
  WHERE (("p"."conversation_id" = "chat_messages"."conversation_id") AND (("p"."user_uid")::"text" = ("auth"."uid"())::"text"))))));



CREATE POLICY "msgs_select_if_participant_or_super" ON "public"."chat_messages" FOR SELECT TO "authenticated" USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."chat_participants" "p"
  WHERE (("p"."conversation_id" = "chat_messages"."conversation_id") AND (("p"."user_uid")::"text" = ("auth"."uid"())::"text"))))));



CREATE POLICY "msgs_update_owner_or_super" ON "public"."chat_messages" FOR UPDATE TO "authenticated" USING ((("public"."fn_is_super_admin"() = true) OR (("sender_uid")::"text" = ("auth"."uid"())::"text"))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (("sender_uid")::"text" = ("auth"."uid"())::"text")));



CREATE POLICY "part_delete_by_creator_or_super" ON "public"."chat_participants" FOR DELETE TO "authenticated" USING (("public"."fn_is_super_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."chat_conversations" "c"
  WHERE (("c"."id" = "chat_participants"."conversation_id") AND ("c"."created_by" = "auth"."uid"()))))));



CREATE POLICY "part_insert_by_creator_or_super" ON "public"."chat_participants" FOR INSERT TO "authenticated" WITH CHECK (("public"."fn_is_super_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."chat_conversations" "c"
  WHERE (("c"."id" = "chat_participants"."conversation_id") AND ("c"."created_by" = "auth"."uid"()))))));



CREATE POLICY "part_select_self_or_super" ON "public"."chat_participants" FOR SELECT TO "authenticated" USING ((("user_uid" = "auth"."uid"()) OR "public"."fn_is_super_admin"()));



CREATE POLICY "part_update_self_or_super" ON "public"."chat_participants" FOR UPDATE TO "authenticated" USING ((("user_uid" = "auth"."uid"()) OR "public"."fn_is_super_admin"())) WITH CHECK ((("user_uid" = "auth"."uid"()) OR "public"."fn_is_super_admin"()));



ALTER TABLE "public"."patient_services" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "patient_services_delete_own" ON "public"."patient_services" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "patient_services"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "patient_services_insert_own" ON "public"."patient_services" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "patient_services"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "patient_services_select_own" ON "public"."patient_services" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "patient_services"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "patient_services_update_own" ON "public"."patient_services" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "patient_services"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "patient_services"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."patients" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "patients_delete_own" ON "public"."patients" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "patients"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "patients_insert_own" ON "public"."patients" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "patients"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "patients_select_own" ON "public"."patients" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "patients"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "patients_update_own" ON "public"."patients" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "patients"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "patients"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."prescription_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "prescription_items_delete_own" ON "public"."prescription_items" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "prescription_items"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "prescription_items_insert_own" ON "public"."prescription_items" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "prescription_items"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "prescription_items_select_own" ON "public"."prescription_items" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "prescription_items"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "prescription_items_update_own" ON "public"."prescription_items" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "prescription_items"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "prescription_items"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."prescriptions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "prescriptions_delete_own" ON "public"."prescriptions" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "prescriptions"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "prescriptions_insert_own" ON "public"."prescriptions" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "prescriptions"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "prescriptions_select_own" ON "public"."prescriptions" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "prescriptions"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "prescriptions_update_own" ON "public"."prescriptions" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "prescriptions"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "prescriptions"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_delete_account_managers" ON "public"."profiles" FOR DELETE TO "authenticated" USING ((("public"."fn_is_super_admin"() = true) OR (("account_id" IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "profiles"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND (COALESCE("au"."disabled", false) = false) AND ("lower"(COALESCE("au"."role", ''::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text", 'superadmin'::"text"]))))))));



CREATE POLICY "profiles_insert_account_managers" ON "public"."profiles" FOR INSERT TO "authenticated" WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (("account_id" IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "profiles"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND (COALESCE("au"."disabled", false) = false) AND ("lower"(COALESCE("au"."role", ''::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text", 'superadmin'::"text"]))))))));



CREATE POLICY "profiles_select_own_or_account" ON "public"."profiles" FOR SELECT TO "authenticated" USING ((("public"."fn_is_super_admin"() = true) OR (("id")::"text" = ("auth"."uid"())::"text") OR (("account_id" IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "profiles"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND (COALESCE("au"."disabled", false) = false)))))));



CREATE POLICY "profiles_update_account_managers" ON "public"."profiles" FOR UPDATE TO "authenticated" USING ((("public"."fn_is_super_admin"() = true) OR (("id")::"text" = ("auth"."uid"())::"text") OR (("account_id" IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "profiles"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND (COALESCE("au"."disabled", false) = false) AND ("lower"(COALESCE("au"."role", ''::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text", 'superadmin'::"text"])))))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (("id")::"text" = ("auth"."uid"())::"text") OR (("account_id" IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "profiles"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND (COALESCE("au"."disabled", false) = false) AND ("lower"(COALESCE("au"."role", ''::"text")) = ANY (ARRAY['owner'::"text", 'admin'::"text", 'superadmin'::"text"]))))))));



ALTER TABLE "public"."purchases" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "purchases_delete_own" ON "public"."purchases" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "purchases"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "purchases_insert_own" ON "public"."purchases" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "purchases"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "purchases_select_own" ON "public"."purchases" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "purchases"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "purchases_update_own" ON "public"."purchases" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "purchases"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "purchases"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "reactions delete by owner participant" ON "public"."chat_reactions" FOR DELETE TO "authenticated" USING ((("user_uid" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM ("public"."chat_messages" "m"
     JOIN "public"."chat_participants" "p" ON ((("p"."conversation_id" = "m"."conversation_id") AND ("p"."user_uid" = "auth"."uid"()))))
  WHERE ("m"."id" = "chat_reactions"."message_id")))));



CREATE POLICY "reactions insert by participant self" ON "public"."chat_reactions" FOR INSERT TO "authenticated" WITH CHECK ((("user_uid" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM ("public"."chat_messages" "m"
     JOIN "public"."chat_participants" "p" ON ((("p"."conversation_id" = "m"."conversation_id") AND ("p"."user_uid" = "auth"."uid"()))))
  WHERE ("m"."id" = "chat_reactions"."message_id")))));



CREATE POLICY "reactions select for participants" ON "public"."chat_reactions" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."chat_messages" "m"
     JOIN "public"."chat_participants" "p" ON ((("p"."conversation_id" = "m"."conversation_id") AND ("p"."user_uid" = "auth"."uid"()))))
  WHERE ("m"."id" = "chat_reactions"."message_id"))));



CREATE POLICY "reads_insert_self_if_member" ON "public"."chat_reads" FOR INSERT TO "authenticated" WITH CHECK (((("user_uid")::"text" = ("auth"."uid"())::"text") AND (EXISTS ( SELECT 1
   FROM "public"."chat_participants" "p"
  WHERE (("p"."conversation_id" = "chat_reads"."conversation_id") AND (("p"."user_uid")::"text" = ("auth"."uid"())::"text"))))));



CREATE POLICY "reads_select_self_or_super_if_member" ON "public"."chat_reads" FOR SELECT TO "authenticated" USING ((("public"."fn_is_super_admin"() = true) OR ((("user_uid")::"text" = ("auth"."uid"())::"text") AND (EXISTS ( SELECT 1
   FROM "public"."chat_participants" "p"
  WHERE (("p"."conversation_id" = "chat_reads"."conversation_id") AND (("p"."user_uid")::"text" = ("auth"."uid"())::"text")))))));



CREATE POLICY "reads_update_self_or_super_if_member" ON "public"."chat_reads" FOR UPDATE TO "authenticated" USING ((("public"."fn_is_super_admin"() = true) OR ((("user_uid")::"text" = ("auth"."uid"())::"text") AND (EXISTS ( SELECT 1
   FROM "public"."chat_participants" "p"
  WHERE (("p"."conversation_id" = "chat_reads"."conversation_id") AND (("p"."user_uid")::"text" = ("auth"."uid"())::"text"))))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR ((("user_uid")::"text" = ("auth"."uid"())::"text") AND (EXISTS ( SELECT 1
   FROM "public"."chat_participants" "p"
  WHERE (("p"."conversation_id" = "chat_reads"."conversation_id") AND (("p"."user_uid")::"text" = ("auth"."uid"())::"text")))))));



ALTER TABLE "public"."returns" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "returns_delete_own" ON "public"."returns" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "returns"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "returns_insert_own" ON "public"."returns" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "returns"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "returns_select_own" ON "public"."returns" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "returns"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "returns_update_own" ON "public"."returns" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "returns"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "returns"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "public"."service_doctor_share" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "service_doctor_share_delete_own" ON "public"."service_doctor_share" FOR DELETE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "service_doctor_share"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "service_doctor_share_insert_own" ON "public"."service_doctor_share" FOR INSERT WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "service_doctor_share"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "service_doctor_share_select_own" ON "public"."service_doctor_share" FOR SELECT USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "service_doctor_share"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



CREATE POLICY "service_doctor_share_update_own" ON "public"."service_doctor_share" FOR UPDATE USING ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "service_doctor_share"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE)))))) WITH CHECK ((("public"."fn_is_super_admin"() = true) OR (EXISTS ( SELECT 1
   FROM "public"."account_users" "au"
  WHERE (("au"."account_id" = "service_doctor_share"."account_id") AND (("au"."user_uid")::"text" = ("auth"."uid"())::"text") AND ("au"."disabled" IS NOT TRUE))))));



ALTER TABLE "storage"."buckets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "storage"."buckets_analytics" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "chat-attachments delete for participants" ON "storage"."objects" FOR DELETE TO "authenticated" USING ((("bucket_id" = 'chat-attachments'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."chat_participants" "p"
  WHERE (("p"."conversation_id" = "public"."chat_conversation_id_from_path"("objects"."name")) AND ("p"."user_uid" = "auth"."uid"()))))));



CREATE POLICY "chat-attachments insert for participants" ON "storage"."objects" FOR INSERT TO "authenticated" WITH CHECK ((("bucket_id" = 'chat-attachments'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."chat_participants" "p"
  WHERE (("p"."conversation_id" = "public"."chat_conversation_id_from_path"("objects"."name")) AND ("p"."user_uid" = "auth"."uid"()))))));



CREATE POLICY "chat-attachments read for participants" ON "storage"."objects" FOR SELECT TO "authenticated" USING ((("bucket_id" = 'chat-attachments'::"text") AND (EXISTS ( SELECT 1
   FROM "public"."chat_participants" "p"
  WHERE (("p"."conversation_id" = "public"."chat_conversation_id_from_path"("objects"."name")) AND ("p"."user_uid" = "auth"."uid"()))))));



ALTER TABLE "storage"."migrations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "storage"."objects" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "storage"."prefixes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "storage"."s3_multipart_uploads" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "storage"."s3_multipart_uploads_parts" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT USAGE ON SCHEMA "storage" TO "postgres" WITH GRANT OPTION;
GRANT USAGE ON SCHEMA "storage" TO "anon";
GRANT USAGE ON SCHEMA "storage" TO "authenticated";
GRANT USAGE ON SCHEMA "storage" TO "service_role";
GRANT ALL ON SCHEMA "storage" TO "supabase_storage_admin";
GRANT ALL ON SCHEMA "storage" TO "dashboard_user";



GRANT ALL ON FUNCTION "public"."admin_attach_employee"("p_account" "uuid", "p_user_uid" "uuid", "p_role" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_attach_employee"("p_account" "uuid", "p_user_uid" "uuid", "p_role" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_attach_employee"("p_account" "uuid", "p_user_uid" "uuid", "p_role" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_bootstrap_clinic_for_email"("clinic_name" "text", "owner_email" "text", "owner_role" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_bootstrap_clinic_for_email"("clinic_name" "text", "owner_email" "text", "owner_role" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_bootstrap_clinic_for_email"("clinic_name" "text", "owner_email" "text", "owner_role" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."chat_conversation_id_from_path"("_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."chat_conversation_id_from_path"("_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."chat_conversation_id_from_path"("_name" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_employee"("p_account" "uuid", "p_user_uid" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_employee"("p_account" "uuid", "p_user_uid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_employee"("p_account" "uuid", "p_user_uid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_employee"("p_account" "uuid", "p_user_uid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_chat_messages_touch_last_msg"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_chat_messages_touch_last_msg"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_chat_messages_touch_last_msg"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_chat_refresh_last_msg"("p_conversation_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."fn_chat_refresh_last_msg"("p_conversation_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_chat_refresh_last_msg"("p_conversation_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_is_super_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_is_super_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_is_super_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_my_latest_account_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_my_latest_account_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_my_latest_account_id"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_sign_chat_attachment"("p_bucket" "text", "p_path" "text", "p_expires_in" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_sign_chat_attachment"("p_bucket" "text", "p_path" "text", "p_expires_in" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."fn_sign_chat_attachment"("p_bucket" "text", "p_path" "text", "p_expires_in" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_sign_chat_attachment"("p_bucket" "text", "p_path" "text", "p_expires_in" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_enum_types"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_enum_types"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_enum_types"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_schema_info"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_schema_info"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_schema_info"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."list_employees_with_email"("p_account" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_employees_with_email"("p_account" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."list_employees_with_email"("p_account" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_employees_with_email"("p_account" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."my_account_id"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."my_account_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."my_account_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."my_account_id"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."my_accounts"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."my_accounts"() TO "anon";
GRANT ALL ON FUNCTION "public"."my_accounts"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."my_accounts"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."set_employee_disabled"("p_account" "uuid", "p_user_uid" "uuid", "p_disabled" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_employee_disabled"("p_account" "uuid", "p_user_uid" "uuid", "p_disabled" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."set_employee_disabled"("p_account" "uuid", "p_user_uid" "uuid", "p_disabled" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_employee_disabled"("p_account" "uuid", "p_user_uid" "uuid", "p_disabled" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_profiles_set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_profiles_set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_profiles_set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_touch_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_touch_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_touch_updated_at"() TO "service_role";



GRANT ALL ON TABLE "public"."account_users" TO "anon";
GRANT ALL ON TABLE "public"."account_users" TO "authenticated";
GRANT ALL ON TABLE "public"."account_users" TO "service_role";



GRANT ALL ON TABLE "public"."accounts" TO "anon";
GRANT ALL ON TABLE "public"."accounts" TO "authenticated";
GRANT ALL ON TABLE "public"."accounts" TO "service_role";



GRANT ALL ON TABLE "public"."alert_settings" TO "anon";
GRANT ALL ON TABLE "public"."alert_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."alert_settings" TO "service_role";



GRANT ALL ON TABLE "public"."appointments" TO "anon";
GRANT ALL ON TABLE "public"."appointments" TO "authenticated";
GRANT ALL ON TABLE "public"."appointments" TO "service_role";



GRANT ALL ON TABLE "public"."chat_attachments" TO "anon";
GRANT ALL ON TABLE "public"."chat_attachments" TO "authenticated";
GRANT ALL ON TABLE "public"."chat_attachments" TO "service_role";



GRANT ALL ON TABLE "public"."chat_conversations" TO "anon";
GRANT ALL ON TABLE "public"."chat_conversations" TO "authenticated";
GRANT ALL ON TABLE "public"."chat_conversations" TO "service_role";



GRANT ALL ON TABLE "public"."chat_messages" TO "anon";
GRANT ALL ON TABLE "public"."chat_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."chat_messages" TO "service_role";



GRANT ALL ON TABLE "public"."chat_participants" TO "anon";
GRANT ALL ON TABLE "public"."chat_participants" TO "authenticated";
GRANT ALL ON TABLE "public"."chat_participants" TO "service_role";



GRANT ALL ON TABLE "public"."chat_reactions" TO "anon";
GRANT ALL ON TABLE "public"."chat_reactions" TO "authenticated";
GRANT ALL ON TABLE "public"."chat_reactions" TO "service_role";



GRANT ALL ON TABLE "public"."chat_reads" TO "anon";
GRANT ALL ON TABLE "public"."chat_reads" TO "authenticated";
GRANT ALL ON TABLE "public"."chat_reads" TO "service_role";



GRANT ALL ON TABLE "public"."clinics" TO "anon";
GRANT ALL ON TABLE "public"."clinics" TO "authenticated";
GRANT ALL ON TABLE "public"."clinics" TO "service_role";



GRANT ALL ON TABLE "public"."complaints" TO "anon";
GRANT ALL ON TABLE "public"."complaints" TO "authenticated";
GRANT ALL ON TABLE "public"."complaints" TO "service_role";



GRANT ALL ON TABLE "public"."consumption_types" TO "anon";
GRANT ALL ON TABLE "public"."consumption_types" TO "authenticated";
GRANT ALL ON TABLE "public"."consumption_types" TO "service_role";



GRANT ALL ON TABLE "public"."consumptions" TO "anon";
GRANT ALL ON TABLE "public"."consumptions" TO "authenticated";
GRANT ALL ON TABLE "public"."consumptions" TO "service_role";



GRANT ALL ON TABLE "public"."doctors" TO "anon";
GRANT ALL ON TABLE "public"."doctors" TO "authenticated";
GRANT ALL ON TABLE "public"."doctors" TO "service_role";



GRANT ALL ON TABLE "public"."drugs" TO "anon";
GRANT ALL ON TABLE "public"."drugs" TO "authenticated";
GRANT ALL ON TABLE "public"."drugs" TO "service_role";



GRANT ALL ON TABLE "public"."employees" TO "anon";
GRANT ALL ON TABLE "public"."employees" TO "authenticated";
GRANT ALL ON TABLE "public"."employees" TO "service_role";



GRANT ALL ON TABLE "public"."employees_discounts" TO "anon";
GRANT ALL ON TABLE "public"."employees_discounts" TO "authenticated";
GRANT ALL ON TABLE "public"."employees_discounts" TO "service_role";



GRANT ALL ON TABLE "public"."employees_loans" TO "anon";
GRANT ALL ON TABLE "public"."employees_loans" TO "authenticated";
GRANT ALL ON TABLE "public"."employees_loans" TO "service_role";



GRANT ALL ON TABLE "public"."employees_salaries" TO "anon";
GRANT ALL ON TABLE "public"."employees_salaries" TO "authenticated";
GRANT ALL ON TABLE "public"."employees_salaries" TO "service_role";



GRANT ALL ON TABLE "public"."financial_logs" TO "anon";
GRANT ALL ON TABLE "public"."financial_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."financial_logs" TO "service_role";



GRANT ALL ON TABLE "public"."item_types" TO "anon";
GRANT ALL ON TABLE "public"."item_types" TO "authenticated";
GRANT ALL ON TABLE "public"."item_types" TO "service_role";



GRANT ALL ON TABLE "public"."items" TO "anon";
GRANT ALL ON TABLE "public"."items" TO "authenticated";
GRANT ALL ON TABLE "public"."items" TO "service_role";



GRANT ALL ON TABLE "public"."medical_services" TO "anon";
GRANT ALL ON TABLE "public"."medical_services" TO "authenticated";
GRANT ALL ON TABLE "public"."medical_services" TO "service_role";



GRANT ALL ON TABLE "public"."patient_services" TO "anon";
GRANT ALL ON TABLE "public"."patient_services" TO "authenticated";
GRANT ALL ON TABLE "public"."patient_services" TO "service_role";



GRANT ALL ON TABLE "public"."patients" TO "anon";
GRANT ALL ON TABLE "public"."patients" TO "authenticated";
GRANT ALL ON TABLE "public"."patients" TO "service_role";



GRANT ALL ON TABLE "public"."prescription_items" TO "anon";
GRANT ALL ON TABLE "public"."prescription_items" TO "authenticated";
GRANT ALL ON TABLE "public"."prescription_items" TO "service_role";



GRANT ALL ON TABLE "public"."prescriptions" TO "anon";
GRANT ALL ON TABLE "public"."prescriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."prescriptions" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."purchases" TO "anon";
GRANT ALL ON TABLE "public"."purchases" TO "authenticated";
GRANT ALL ON TABLE "public"."purchases" TO "service_role";



GRANT ALL ON TABLE "public"."returns" TO "anon";
GRANT ALL ON TABLE "public"."returns" TO "authenticated";
GRANT ALL ON TABLE "public"."returns" TO "service_role";



GRANT ALL ON TABLE "public"."service_doctor_share" TO "anon";
GRANT ALL ON TABLE "public"."service_doctor_share" TO "authenticated";
GRANT ALL ON TABLE "public"."service_doctor_share" TO "service_role";



GRANT ALL ON TABLE "public"."super_admins" TO "anon";
GRANT ALL ON TABLE "public"."super_admins" TO "authenticated";
GRANT ALL ON TABLE "public"."super_admins" TO "service_role";



GRANT ALL ON TABLE "public"."v_chat_last_message" TO "anon";
GRANT ALL ON TABLE "public"."v_chat_last_message" TO "authenticated";
GRANT ALL ON TABLE "public"."v_chat_last_message" TO "service_role";



GRANT ALL ON TABLE "public"."v_chat_reads_for_me" TO "anon";
GRANT ALL ON TABLE "public"."v_chat_reads_for_me" TO "authenticated";
GRANT ALL ON TABLE "public"."v_chat_reads_for_me" TO "service_role";



GRANT ALL ON TABLE "public"."v_chat_conversations_for_me" TO "anon";
GRANT ALL ON TABLE "public"."v_chat_conversations_for_me" TO "authenticated";
GRANT ALL ON TABLE "public"."v_chat_conversations_for_me" TO "service_role";



GRANT ALL ON TABLE "public"."v_chat_messages_with_attachments" TO "anon";
GRANT ALL ON TABLE "public"."v_chat_messages_with_attachments" TO "authenticated";
GRANT ALL ON TABLE "public"."v_chat_messages_with_attachments" TO "service_role";



GRANT ALL ON TABLE "storage"."buckets" TO "anon";
GRANT ALL ON TABLE "storage"."buckets" TO "authenticated";
GRANT ALL ON TABLE "storage"."buckets" TO "service_role";
GRANT ALL ON TABLE "storage"."buckets" TO "postgres" WITH GRANT OPTION;



GRANT ALL ON TABLE "storage"."buckets_analytics" TO "service_role";
GRANT ALL ON TABLE "storage"."buckets_analytics" TO "authenticated";
GRANT ALL ON TABLE "storage"."buckets_analytics" TO "anon";



GRANT ALL ON TABLE "storage"."objects" TO "anon";
GRANT ALL ON TABLE "storage"."objects" TO "authenticated";
GRANT ALL ON TABLE "storage"."objects" TO "service_role";
GRANT ALL ON TABLE "storage"."objects" TO "postgres" WITH GRANT OPTION;



GRANT ALL ON TABLE "storage"."prefixes" TO "service_role";
GRANT ALL ON TABLE "storage"."prefixes" TO "authenticated";
GRANT ALL ON TABLE "storage"."prefixes" TO "anon";



GRANT ALL ON TABLE "storage"."s3_multipart_uploads" TO "service_role";
GRANT SELECT ON TABLE "storage"."s3_multipart_uploads" TO "authenticated";
GRANT SELECT ON TABLE "storage"."s3_multipart_uploads" TO "anon";



GRANT ALL ON TABLE "storage"."s3_multipart_uploads_parts" TO "service_role";
GRANT SELECT ON TABLE "storage"."s3_multipart_uploads_parts" TO "authenticated";
GRANT SELECT ON TABLE "storage"."s3_multipart_uploads_parts" TO "anon";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON SEQUENCES TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON FUNCTIONS TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "storage" GRANT ALL ON TABLES TO "service_role";



RESET ALL;
