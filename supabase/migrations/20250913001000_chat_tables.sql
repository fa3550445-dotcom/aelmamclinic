-- 20250913001000_chat_tables.sql
-- Legacy placeholder: the chat schema now lives entirely in 2025091300_chat_base.sql.
-- This migration drops any early/partial tables so the next migration can recreate them
-- with the correct (account_id, device_id, local_id) structure.

DROP TABLE IF EXISTS public.chat_reactions CASCADE;
DROP TABLE IF EXISTS public.chat_attachments CASCADE;
DROP TABLE IF EXISTS public.chat_reads CASCADE;
DROP TABLE IF EXISTS public.chat_participants CASCADE;
DROP TABLE IF EXISTS public.chat_messages CASCADE;
DROP TABLE IF EXISTS public.chat_conversations CASCADE;
