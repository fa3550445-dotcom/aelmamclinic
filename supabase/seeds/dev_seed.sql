-- supabase/seeds/dev_seed.sql
-- Demo seeding script. Run with the service role (supabase db remote/psql) after
-- creating an auth user for `owner@demo.local`. The script is idempotent and will
-- skip inserts if data already exists.

DO $$
DECLARE
  owner_email text := 'owner@demo.local';
  owner_uid uuid;
  account_id uuid;
  conversation_id uuid;
BEGIN
  SELECT id
    INTO owner_uid
  FROM auth.users
  WHERE lower(email) = lower(owner_email)
  ORDER BY created_at DESC
  LIMIT 1;

  IF owner_uid IS NULL THEN
    RAISE NOTICE 'Seed skipped: auth user % not found.', owner_email;
    RETURN;
  END IF;

  SELECT id
    INTO account_id
  FROM public.accounts
  WHERE name = 'Demo Clinic Seed'
  LIMIT 1;

  IF account_id IS NULL THEN
    account_id := public.admin_bootstrap_clinic_for_email('Demo Clinic Seed', owner_email, 'owner');
    RAISE NOTICE 'Created demo clinic account %', account_id;
  END IF;

  -- Sample doctor
  IF NOT EXISTS (
    SELECT 1 FROM public.doctors
    WHERE account_id = account_id AND name = 'Dr. Demo'
  ) THEN
    INSERT INTO public.doctors(account_id, name, specialization, phone_number, device_id, local_id)
    VALUES (account_id, 'Dr. Demo', 'General Medicine', '+1-555-0101', 'seed', 1);
  END IF;

  -- Sample patient
  IF NOT EXISTS (
    SELECT 1 FROM public.patients
    WHERE account_id = account_id AND name = 'Demo Patient'
  ) THEN
    INSERT INTO public.patients(
      account_id, device_id, local_id, name, age, diagnosis,
      phone_number, register_date, paid_amount, remaining
    )
    VALUES (
      account_id, 'seed', 1, 'Demo Patient', 30, 'Initial Consultation',
      '+1-555-9999', current_date, 50, 150
    );
  END IF;

  -- Sample chat conversation (owner + doctor)
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_conversations
    WHERE account_id = account_id AND title = 'Demo Support Channel'
  ) THEN
    INSERT INTO public.chat_conversations(
      account_id, title, is_group, created_by, device_id, local_id
    )
    VALUES (
      account_id, 'Demo Support Channel', false, owner_uid, 'seed', 1
    )
    RETURNING id INTO conversation_id;

    INSERT INTO public.chat_participants(account_id, conversation_id, user_uid, email, role, joined_at)
    VALUES
      (account_id, conversation_id, owner_uid, owner_email, 'owner', now());
  END IF;

END;
$$;
