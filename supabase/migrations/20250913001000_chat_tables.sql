-- 20250913001000_chat_tables.sql
-- إنشاء جداول الدردشة الأساسية قبل تطبيق الفهارس/السياسات.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS public.chat_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid,
  is_group boolean NOT NULL DEFAULT false,
  title text,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  last_msg_at timestamptz,
  last_msg_snippet text
);

CREATE TABLE IF NOT EXISTS public.chat_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  sender_uid uuid NOT NULL,
  sender_email text,
  kind text NOT NULL DEFAULT 'text',
  body text,
  edited boolean NOT NULL DEFAULT false,
  deleted boolean NOT NULL DEFAULT false,
  deleted_at timestamptz,
  edited_at timestamptz,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  patient_id text
);

CREATE TABLE IF NOT EXISTS public.chat_participants (
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  user_uid uuid NOT NULL,
  role text,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, user_uid)
);

CREATE TABLE IF NOT EXISTS public.chat_reads (
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  user_uid uuid NOT NULL,
  last_read_message_id uuid,
  last_read_at timestamptz NOT NULL DEFAULT 'epoch'::timestamptz,
  PRIMARY KEY (conversation_id, user_uid)
);

CREATE TABLE IF NOT EXISTS public.chat_attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id uuid NOT NULL REFERENCES public.chat_messages(id) ON DELETE CASCADE,
  bucket text NOT NULL DEFAULT 'chat-attachments',
  path text NOT NULL,
  mime_type text,
  size_bytes bigint NOT NULL DEFAULT 0,
  width integer,
  height integer,
  created_at timestamptz NOT NULL DEFAULT now()
);
