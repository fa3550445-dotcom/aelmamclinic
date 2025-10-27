-- 2025091300_chat_base.sql
-- تعريف جداول الدردشة الأساسية مع أعمدة triplet (account_id, device_id, local_id)
-- بحيث تكون الهجرات اللاحقة (فهارس، سياسات، عروض) مبنية على مخطط واضح ومتناسق.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ╭──────────────────────────────────────────────────────────────────────────────╮
-- │ جدول المحادثات                                                              │
-- ╰──────────────────────────────────────────────────────────────────────────────╯
CREATE TABLE IF NOT EXISTS public.chat_conversations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id      uuid REFERENCES public.accounts(id) ON DELETE SET NULL,
  title           text,
  is_group        boolean NOT NULL DEFAULT false,
  created_by      uuid NOT NULL REFERENCES auth.users(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  last_msg_at     timestamptz,
  last_msg_snippet text,
  deleted_at      timestamptz,
  is_deleted      boolean NOT NULL DEFAULT false
);

COMMENT ON TABLE public.chat_conversations IS 'قائمة المحادثات (قناة جماعية أو محادثة مباشرة) ضمن حساب العيادة.';

-- ╭──────────────────────────────────────────────────────────────────────────────╮
-- │ جدول المشاركين                                                              │
-- ╰──────────────────────────────────────────────────────────────────────────────╯
CREATE TABLE IF NOT EXISTS public.chat_participants (
  account_id      uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  user_uid        uuid NOT NULL,
  email           text,
  nickname        text,
  role            text,
  joined_at       timestamptz,
  muted           boolean NOT NULL DEFAULT false,
  PRIMARY KEY (conversation_id, user_uid),
  FOREIGN KEY (account_id, user_uid)
    REFERENCES public.account_users(account_id, user_uid)
);

COMMENT ON TABLE public.chat_participants IS 'ربط المستخدمين بالمحادثات مع بيانات إضافية (الدور، البريد، حالة الكتم).';

-- ╭──────────────────────────────────────────────────────────────────────────────╮
-- │ جدول الرسائل                                                                │
-- ╰──────────────────────────────────────────────────────────────────────────────╯
CREATE TABLE IF NOT EXISTS public.chat_messages (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id         uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  conversation_id    uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  sender_uid         uuid NOT NULL,
  sender_email       text,
  kind               text NOT NULL DEFAULT 'text',
  body               text,
  text               text,
  attachments        jsonb NOT NULL DEFAULT '[]'::jsonb,
  mentions           jsonb NOT NULL DEFAULT '[]'::jsonb,
  reply_to_message_id uuid REFERENCES public.chat_messages(id) ON DELETE SET NULL,
  reply_to_id        text,
  reply_to_snippet   text,
  patient_id         uuid,
  created_at         timestamptz NOT NULL DEFAULT now(),
  edited             boolean NOT NULL DEFAULT false,
  edited_at          timestamptz,
  deleted            boolean NOT NULL DEFAULT false,
  deleted_at         timestamptz,
  is_deleted         boolean NOT NULL DEFAULT false,
  device_id          text,
  local_id           bigint,
  FOREIGN KEY (account_id, sender_uid)
    REFERENCES public.account_users(account_id, user_uid)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_chat_messages_device_local
  ON public.chat_messages (account_id, device_id, local_id)
  WHERE account_id IS NOT NULL AND device_id IS NOT NULL AND local_id IS NOT NULL;

COMMENT ON TABLE public.chat_messages IS 'الرسائل داخل كل محادثة مع دعم الحقول التفاؤلية (triplet) للمزامنة عبر الأجهزة.';

-- ╭──────────────────────────────────────────────────────────────────────────────╮
-- │ جدول حالات القراءة                                                          │
-- ╰──────────────────────────────────────────────────────────────────────────────╯
CREATE TABLE IF NOT EXISTS public.chat_reads (
  account_id           uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  conversation_id      uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  user_uid             uuid NOT NULL,
  last_read_message_id uuid REFERENCES public.chat_messages(id) ON DELETE SET NULL,
  last_read_at         timestamptz,
  PRIMARY KEY (conversation_id, user_uid),
  FOREIGN KEY (account_id, user_uid)
    REFERENCES public.account_users(account_id, user_uid)
);

COMMENT ON TABLE public.chat_reads IS 'آخر حالة قراءة لكل مشارك داخل المحادثات.';

-- ╭──────────────────────────────────────────────────────────────────────────────╮
-- │ جدول المرفقات                                                                │
-- ╰──────────────────────────────────────────────────────────────────────────────╯
CREATE TABLE IF NOT EXISTS public.chat_attachments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id  uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  message_id  uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  bucket      text NOT NULL DEFAULT 'chat-attachments',
  path        text NOT NULL,
  mime_type   text,
  size_bytes  integer,
  width       integer,
  height      integer,
  created_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,
  is_deleted  boolean NOT NULL DEFAULT false,
  device_id   text,
  local_id    bigint,
  FOREIGN KEY (message_id)
    REFERENCES public.chat_messages(id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_chat_attachments_device_local
  ON public.chat_attachments (account_id, device_id, local_id)
  WHERE account_id IS NOT NULL AND device_id IS NOT NULL AND local_id IS NOT NULL;

COMMENT ON TABLE public.chat_attachments IS 'البيانات الوصفية لمرفقات الرسائل (المسار داخل Storage، الأبعاد، الحجم...).';

-- ╭──────────────────────────────────────────────────────────────────────────────╮
-- │ جدول التفاعلات على الرسائل                                                  │
-- ╰──────────────────────────────────────────────────────────────────────────────╯
CREATE TABLE IF NOT EXISTS public.chat_reactions (
  account_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE,
  message_id uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  user_uid   uuid NOT NULL,
  emoji      text NOT NULL CHECK (char_length(emoji) BETWEEN 1 AND 16),
  created_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz,
  is_deleted boolean NOT NULL DEFAULT false,
  device_id  text,
  local_id   bigint,
  PRIMARY KEY (message_id, user_uid, emoji),
  FOREIGN KEY (account_id, user_uid)
    REFERENCES public.account_users(account_id, user_uid)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_chat_reactions_device_local
  ON public.chat_reactions (account_id, device_id, local_id, emoji)
  WHERE account_id IS NOT NULL AND device_id IS NOT NULL AND local_id IS NOT NULL;

COMMENT ON TABLE public.chat_reactions IS 'تفاعلات المستخدمين على الرسائل (إيموجي) مع تتبع triplet للمزامنة.';

-- انتهى
