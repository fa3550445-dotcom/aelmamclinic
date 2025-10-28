-- 2025092102_storage_chat_attachments.sql
-- Storage policies for the chat-attachments bucket, executed with the proper owner role.

create or replace function public.chat_conversation_id_from_path(_name text)
returns uuid
language sql
immutable
as $$
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
do $$
begin
  begin
    execute 'alter table storage.objects enable row level security';
  exception
    when insufficient_privilege then null;
  end;
end $$;
do $policies$
begin
  begin
    execute 'set local role supabase_storage_admin';
  exception
    when insufficient_privilege then
      -- On Supabase Cloud the linked service role cannot impersonate the storage owner.
      -- Skip silently; policies must be managed via the dashboard in that environment.
      return;
  end;

  execute 'drop policy if exists "chat-attachments read for participants" on storage.objects';
  execute $$
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
  $$;

  execute 'drop policy if exists "chat-attachments insert for participants" on storage.objects';
  execute $$
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
  $$;

  execute 'drop policy if exists "chat-attachments delete for participants" on storage.objects';
  execute $$
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
  $$;

  execute 'reset role';
end
$policies$;
