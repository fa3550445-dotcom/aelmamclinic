create extension if not exists pgcrypto;

create table if not exists public.chat_conversations(
  id uuid primary key default gen_random_uuid(),
  account_id uuid null,
  is_group boolean not null default false,
  title text null,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_msg_at timestamptz null,
  last_msg_snippet text null
);

create table if not exists public.chat_messages(
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.chat_conversations(id) on delete cascade,
  sender_uid uuid not null,
  sender_email text null,
  kind text not null default 'text',
  body text null,
  is_edited boolean not null default false,
  is_deleted boolean not null default false,
  edited_at timestamptz null,
  deleted_at timestamptz null,
  created_at timestamptz not null default now(),
  patient_id text null
);

create table if not exists public.chat_participants(
  conversation_id uuid not null references public.chat_conversations(id) on delete cascade,
  user_uid uuid not null,
  role text null,
  created_at timestamptz not null default now(),
  primary key(conversation_id, user_uid)
);

create table if not exists public.chat_reads(
  conversation_id uuid not null references public.chat_conversations(id) on delete cascade,
  user_uid uuid not null,
  last_read_at timestamptz not null default 'epoch'::timestamptz,
  primary key(conversation_id, user_uid)
);

create table if not exists public.chat_attachments(
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.chat_messages(id) on delete cascade,
  bucket text not null default 'chat-attachments',
  path text not null,
  mime_type text null,
  size_bytes bigint not null default 0,
  width int null,
  height int null,
  created_at timestamptz not null default now()
);
