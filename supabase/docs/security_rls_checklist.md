# Security & RLS Checklist

This checklist captures the current access model after the Stage 3 refresh.
Use it to validate each role (super admin, owner, admin, employee) plus the
service role during smoke tests.

## Core Helpers

- `fn_is_super_admin()` (20250912235900) – grants elevated access based on
  `super_admins` table, JWT role/email, or service role.
- `fn_is_account_member(uuid)` (20250913020000) – evaluates whether the caller
  belongs to the given account and is not disabled; used across RLS policies.

## Table Coverage

| Table / View | Policies in effect | Expected behaviour |
|--------------|-------------------|--------------------|
| `account_users` | `account_users_select` (20251031100500), domain policies | Caller can read own row, super admin can read all, owners/admins can read account members. Inserts/updates/deletes come from `admin_attach_employee` (SECURITY DEFINER). |
| `account_feature_permissions` | Policies in `20251025080000_patch.sql` | Only super admin or account owners/admins manage feature permissions; readable by members. |
| `profiles` | Policies in `20250923000000_profiles_table.sql` | Owners/admins or the profile owner can view/update; super admin bypass. |
| Business tables (`patients`, `returns`, …) | `*_select/insert/update/delete_member_or_super` (20250913020000) | Members of an account (owner/admin/employee) read/write their account; super admin bypass. |
| `chat_conversations`, `chat_participants`, `chat_messages`, `chat_reads`, `chat_attachments`, `chat_reactions` | Policies in `2025091402_chat_policies.sql` | Participation-based access with super-admin overrides. Inserts enforced through security definer chat APIs. |
| `audit_logs` | Policies in `20251025080000_patch.sql` | Super admin full access; account members can read logs for their account. |
| `clinics` view | Uses `accounts` data (20250913030000) | Readable via same policies as `accounts`. |

## Storage

- Bucket `chat-attachments` created in `2025091501_storage_create_bucket.sql`.
- Policies in `2025092102_storage_chat_attachments.sql` restrict insert/select/delete to conversation participants. Edge function `sign-attachment` enforces the same guard and signs URLs with the service role key.

## Functions / RPCs

- `admin_bootstrap_clinic_for_email` & `admin_create_employee_full`
  (20250913040000) – require `fn_is_super_admin()`; cleanly update account links.
- Legacy RPCs (`my_account_id`, `my_accounts`, `my_profile`, `list_employees_with_email`, `set_employee_disabled`, `delete_employee`) remain security definers and enforce membership checks internally.

## Smoke-Test Checklist

1. **Super Admin**
   - Call `admin_bootstrap_clinic_for_email` ➜ new account created, owner attached.
   - Query `audit_logs` for any account ➜ rows returned.
   - Fetch employees via `list_employees_with_email` for multiple accounts ➜ success.

2. **Owner (non-super)**
   - Select from `patients` for own account ➜ success; attempt other account ➜ 42501.
   - Insert/update/delete sample patient ➜ succeeds.
   - Access chat conversations/messages where they are a participant ➜ success.
   - Request signed attachment via edge function ➜ URL issued.

3. **Employee**
   - Read/write `patients` entries ➜ allowed.
   - Attempt to manage feature permissions ➜ forbidden (expects 42501).
   - Access chat data only for conversations they participate in ➜ success.

4. **Disabled Member**
   - Flip `account_users.disabled` to `true` and confirm RLS prevents reads/writes.

5. **Storage**
   - Upload/download attachment as participant ➜ allowed.
   - Try direct `storage.objects` access through REST as non-participant ➜ blocked (403/42501).

6. **Profiles**
   - Owner updates another employee’s profile ➜ allowed.
   - Employee tries to update someone else ➜ blocked.

Document results alongside API error codes. Any deviation indicates a missing or misconfigured policy.
