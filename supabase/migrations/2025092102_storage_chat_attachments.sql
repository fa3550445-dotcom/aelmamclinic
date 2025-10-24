-- storage_chat_attachments.sql
-- سياسات وصول لمرفقات الدردشة في Storage (bucket: chat-attachments)
-- المسار المتوقع:
--   attachments/<conversation_id>/<message_id>/<filename>
--   attachments/<conversation_id>/<filename>

-- دالة: تُعيد conversation_id كـ UUID (لتفادي تعارض الأنواع)
create or replace function public.chat_conversation_id_from_path(_name text)
returns uuid
language sql
immutable
as $$
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

-- في Supabase Cloud قد لا نملك صلاحية ALTER على storage.objects؛ نتجاهل الخطأ بأمان.
do $$
begin
  begin
    execute 'alter table storage.objects enable row level security';
  exception
    when insufficient_privilege then null;
  end;
end $$;

-- سياسة القراءة: للمستخدم المصادق المشارك في نفس المحادثة
drop policy if exists "chat-attachments read for participants" on storage.objects;
create policy "chat-attachments read for participants"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'chat-attachments'
  and exists (
    select 1
    from public.chat_participants p
    where p.conversation_id = public.chat_conversation_id_from_path(name)
      and p.user_uid = auth.uid()
  )
);

-- سياسة الإدراج: للمشاركين فقط
drop policy if exists "chat-attachments insert for participants" on storage.objects;
create policy "chat-attachments insert for participants"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'chat-attachments'
  and exists (
    select 1
    from public.chat_participants p
    where p.conversation_id = public.chat_conversation_id_from_path(name)
      and p.user_uid = auth.uid()
  )
);

-- سياسة الحذف: للمشاركين فقط (يمكن تشديدها لاحقًا ليقتصر على مُرسل الرسالة)
drop policy if exists "chat-attachments delete for participants" on storage.objects;
create policy "chat-attachments delete for participants"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'chat-attachments'
  and exists (
    select 1
    from public.chat_participants p
    where p.conversation_id = public.chat_conversation_id_from_path(name)
      and p.user_uid = auth.uid()
  )
);
