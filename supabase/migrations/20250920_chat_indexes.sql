-- 20250920_chat_indexes.sql
-- فهارس للدردشة + تهيئة أعمدة الردّ إن لم تكن موجودة

-- للبحث النصّي الجزئي
create extension if not exists pg_trgm;

-- ✅ تأكّد من وجود أعمدة الردود قبل إنشاء الفهارس
alter table public.chat_messages
  add column if not exists reply_to_message_id uuid,
  add column if not exists reply_to_snippet text,
  add column if not exists mentions jsonb;

-- فهارس chat_messages
create index if not exists chat_messages_conv_created_idx
  on public.chat_messages (conversation_id, created_at);

create index if not exists chat_messages_created_idx
  on public.chat_messages (created_at);

-- في حال وجود reply_to_message_id، يفيد القفز للرسالة المُشار إليها
create index if not exists chat_messages_reply_to_idx
  on public.chat_messages (reply_to_message_id);

-- فهرس بحث نصي سريع على النص/المتن (اختياري لكنه مفيد للـ ilike)
create index if not exists chat_messages_trgm_idx
  on public.chat_messages
  using gin (
    (coalesce(body,'') || ' ' || coalesce(text,'')) gin_trgm_ops
  );

-- فهارس المشاركين
create index if not exists chat_participants_conv_user_idx
  on public.chat_participants (conversation_id, user_uid);

create index if not exists chat_participants_user_idx
  on public.chat_participants (user_uid);

-- فهارس القراءة
create index if not exists chat_reads_conv_user_idx
  on public.chat_reads (conversation_id, user_uid);

create index if not exists chat_reads_user_idx
  on public.chat_reads (user_uid);

-- فهارس المحادثات (للفرز بحسب آخر نشاط)
create index if not exists chat_conversations_last_msg_at_idx
  on public.chat_conversations (last_msg_at);

-- فهارس المرفقات (إن كان جدول chat_attachments موجودًا)
do $$
begin
  if to_regclass('public.chat_attachments') is not null then
    create index if not exists chat_attachments_msg_idx
      on public.chat_attachments (message_id);
    create index if not exists chat_attachments_bucket_path_idx
      on public.chat_attachments (bucket, path);
  end if;
end$$;
