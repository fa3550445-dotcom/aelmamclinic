-- 20250920_chat_indexes.sql
-- فهارس للدردشة + تهيئة أعمدة الردّ إن لم تكن موجودة

-- للبحث النصّي الجزئي
-- ملاحظة: امتداد pg_trgm يجب تفعيله من لوحة التحكم (غير متاح هنا)

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
DO $
BEGIN
  IF EXISTS (SELECT 1 FROM pg_opclass WHERE opcname = 'gin_trgm_ops') THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_indexes
      WHERE schemaname='public' AND indexname='chat_messages_body_trgm_idx'
    ) THEN
      EXECUTE 'CREATE INDEX chat_messages_body_trgm_idx ON public.chat_messages USING gin ((coalesce(body, '''')) gin_trgm_ops)';
    END IF;
  ELSE
    RAISE NOTICE 'skip chat_messages_body_trgm_idx: gin_trgm_ops not available';
  END IF;
END $;

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

