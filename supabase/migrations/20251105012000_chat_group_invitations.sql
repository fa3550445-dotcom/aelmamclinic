-- 20251105012000_chat_group_invitations.sql
-- Adds chat_group_invitations table plus helper views and RPCs to support
-- invitation-based onboarding into group conversations.

CREATE TABLE IF NOT EXISTS public.chat_group_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  inviter_uid uuid NOT NULL REFERENCES auth.users(id),
  invitee_uid uuid NOT NULL REFERENCES auth.users(id),
  invitee_email text,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','declined')),
  created_at timestamptz NOT NULL DEFAULT now(),
  responded_at timestamptz,
  response_note text
);

CREATE INDEX IF NOT EXISTS chat_group_invitations_conv_idx
  ON public.chat_group_invitations (conversation_id);
CREATE INDEX IF NOT EXISTS chat_group_invitations_invitee_idx
  ON public.chat_group_invitations (invitee_uid)
  WHERE status = 'pending';
CREATE UNIQUE INDEX IF NOT EXISTS chat_group_invitations_unique_pending
  ON public.chat_group_invitations (conversation_id, invitee_uid)
  WHERE status = 'pending';

ALTER TABLE public.chat_group_invitations ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'chat_group_invitations'
      AND policyname = 'chat_group_invites_select_visibility'
  ) THEN
    CREATE POLICY chat_group_invites_select_visibility
      ON public.chat_group_invitations
      FOR SELECT
      TO authenticated
      USING (
        fn_is_super_admin() = true
        OR invitee_uid::text = auth.uid()::text
        OR inviter_uid::text = auth.uid()::text
        OR EXISTS (
          SELECT 1
          FROM public.chat_conversations c
          WHERE c.id = chat_group_invitations.conversation_id
            AND c.created_by::text = auth.uid()::text
        )
      );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'chat_group_invitations'
      AND policyname = 'chat_group_invites_insert_creator_or_super'
  ) THEN
    CREATE POLICY chat_group_invites_insert_creator_or_super
      ON public.chat_group_invitations
      FOR INSERT
      TO authenticated
      WITH CHECK (
        fn_is_super_admin() = true
        OR inviter_uid::text = auth.uid()::text
      );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'chat_group_invitations'
      AND policyname = 'chat_group_invites_update_invitee_or_super'
  ) THEN
    CREATE POLICY chat_group_invites_update_invitee_or_super
      ON public.chat_group_invitations
      FOR UPDATE
      TO authenticated
      USING (
        fn_is_super_admin() = true
        OR invitee_uid::text = auth.uid()::text
      )
      WITH CHECK (
        fn_is_super_admin() = true
        OR invitee_uid::text = auth.uid()::text
      );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'chat_group_invitations'
      AND policyname = 'chat_group_invites_delete_owner_or_super'
  ) THEN
    CREATE POLICY chat_group_invites_delete_owner_or_super
      ON public.chat_group_invitations
      FOR DELETE
      TO authenticated
      USING (
        fn_is_super_admin() = true
        OR inviter_uid::text = auth.uid()::text
      );
  END IF;
END $$;

COMMENT ON TABLE public.chat_group_invitations IS
  'Pending invitations for group conversations (status pending/accepted/declined).';

-------------------------------------------------------------------------------
-- Views
-------------------------------------------------------------------------------

CREATE OR REPLACE VIEW public.v_chat_group_invitations_for_me AS
SELECT
  i.id,
  i.conversation_id,
  i.inviter_uid,
  i.invitee_uid,
  i.invitee_email,
  i.status,
  i.created_at,
  i.responded_at,
  i.response_note,
  c.title,
  c.is_group,
  c.account_id,
  c.created_by,
  c.created_at AS conversation_created_at
FROM public.chat_group_invitations i
JOIN public.chat_conversations c
  ON c.id = i.conversation_id
WHERE i.invitee_uid = auth.uid();

GRANT SELECT ON public.v_chat_group_invitations_for_me TO authenticated;
  i.response_note
FROM public.chat_group_invitations i;


-------------------------------------------------------------------------------
-- Helper functions
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.chat_upsert_participant_from_invite(
  p_conversation_id uuid,
  p_user_uid uuid,
  p_email text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_now timestamptz := timezone('utc', now());
BEGIN
  INSERT INTO public.chat_participants (conversation_id, user_uid, email, joined_at)
  VALUES (p_conversation_id, p_user_uid, lower(coalesce(p_email, '')), v_now)
  ON CONFLICT (conversation_id, user_uid)
  DO UPDATE SET
    email = EXCLUDED.email,
    joined_at = EXCLUDED.joined_at;
END;
$$;

REVOKE ALL ON FUNCTION public.chat_upsert_participant_from_invite(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_upsert_participant_from_invite(uuid, uuid, text) TO authenticated;

-------------------------------------------------------------------------------
-- Accept / Decline RPCs
-------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.chat_accept_invitation(p_invitation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_inv public.chat_group_invitations%ROWTYPE;
  v_email text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;

  SELECT *
  INTO v_inv
  FROM public.chat_group_invitations
  WHERE id = p_invitation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invitation not found' USING errcode = 'P0002';
  END IF;

  IF v_inv.invitee_uid <> v_uid THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  IF v_inv.status <> 'pending' THEN
    RETURN;
  END IF;

  SELECT au.email
  INTO v_email
  FROM public.account_users au
  WHERE au.user_uid = v_uid
  ORDER BY au.created_at DESC
  LIMIT 1;

  PERFORM public.chat_upsert_participant_from_invite(
    v_inv.conversation_id,
    v_uid,
    COALESCE(v_inv.invitee_email, v_email)
  );

  UPDATE public.chat_group_invitations
  SET
    status = 'accepted',
    responded_at = timezone('utc', now()),
    response_note = NULL
  WHERE id = v_inv.id;
END;
$$;

REVOKE ALL ON FUNCTION public.chat_accept_invitation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_accept_invitation(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.chat_decline_invitation(
  p_invitation_id uuid,
  p_note text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_inv public.chat_group_invitations%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING errcode = '42501';
  END IF;

  SELECT *
  INTO v_inv
  FROM public.chat_group_invitations
  WHERE id = p_invitation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invitation not found' USING errcode = 'P0002';
  END IF;

  IF v_inv.invitee_uid <> v_uid THEN
    RAISE EXCEPTION 'forbidden' USING errcode = '42501';
  END IF;

  IF v_inv.status <> 'pending' THEN
    RETURN;
  END IF;

  UPDATE public.chat_group_invitations
  SET
    status = 'declined',
    responded_at = timezone('utc', now()),
    response_note = p_note
  WHERE id = v_inv.id;
END;
$$;

REVOKE ALL ON FUNCTION public.chat_decline_invitation(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.chat_decline_invitation(uuid, text) TO authenticated;

