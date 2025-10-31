# Seed & Sync Plan

This document explains how to prepare demo data and validate the SQLite ↔ Supabase
sync layer after the schema refresh.

## 1. Triplet / Sync Tables

- `public.sync_uuid_mapping` (added in 20250913010000) stores the UUID ↔ local
  triplet mapping the Flutter `SyncService` expects. It is safe to truncate during
  environment resets—entries are repopulated automatically on push/pull.
- The parity script (`lib/services/db_parity_v3.dart`) assumes every business table
  keeps `account_id`, `device_id`, `local_id`, `updated_at`. These columns now exist
  in the Supabase schema and are protected by triggers added in the same migration.

## 2. Demo Seed Workflow

1. Create an auth user (Supabase dashboard or CLI) for `owner@demo.local`.
2. Run `supabase db remote commit` or `psql` with the service role and execute:
   ```sql
   \i supabase/seeds/dev_seed.sql
   ```
   The script calls `admin_bootstrap_clinic_for_email`, attaches the owner, and
   inserts example doctor/patient/chat data if missing. If the auth user is absent
   the script exits gracefully.
3. Optionally run `supabase db remote commit` again to capture the seed as baseline.

## 3. Sync Smoke Cycle

After seeding, execute the following with a development build of the app:

1. Launch the app, sign in as the seeded owner, and confirm the new clinic appears.
2. Trigger `SyncService.pullAll()` (e.g., via app menu). Expect downloads for
   patients/doctors/items to succeed without FK errors.
3. Modify a patient locally, then run `SyncService.pushAll()`—verify the row updates
   remotely and `sync_uuid_mapping` receives entries.
4. Use the admin account to add a patient directly in Supabase (SQL) and run
   `pullAll()` again to confirm inserts propagate down.

## 4. Resetting Environment

- To wipe demo data, delete rows in order: chat tables → business tables → accounts.
- Truncate `sync_uuid_mapping` if you want to force re-resolution of UUIDs.
- Re-run `dev_seed.sql` after recreating the auth user.

## 5. Artifacts

- SQL: `supabase/seeds/dev_seed.sql`
- RLS checklist: `supabase/docs/security_rls_checklist.md`
- Commands: use `supabase db lint`, `supabase db push --dry-run`, followed by the
  seeding steps above during CI/manual testing.
