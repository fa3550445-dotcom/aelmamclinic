-- Add user_uid linkage columns for doctors and employees to map Supabase accounts.
ALTER TABLE public.doctors
  ADD COLUMN IF NOT EXISTS user_uid uuid;
ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS user_uid uuid;
CREATE UNIQUE INDEX IF NOT EXISTS doctors_user_uid_unique
  ON public.doctors(user_uid)
  WHERE user_uid IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS employees_user_uid_unique
  ON public.employees(user_uid)
  WHERE user_uid IS NOT NULL;
