# Login & Access Control Review

## Current flow overview
- **Owner provisioning** — `AuthSupabaseService.registerOwner` first attempts the `admin_create_owner_full` RPC, then falls back to the `admin__create_clinic_owner` edge function, finally trying `admin_bootstrap_clinic_for_email` as a legacy escape hatch. Each path relies on `admin_attach_employee` to seed `account_users` and `profiles` rows for the owner role, but success detection today only checks for a generic `{ ok: true }` flag before returning. 【F:lib/services/auth_supabase_service.dart†L824-L929】
- **Employee provisioning** — `AuthSupabaseService.registerEmployee` shares the same tiered strategy (`admin_create_employee_full` RPC → `admin__create_employee` edge function) and assumes that the edge function will both create the auth user and connect it to the clinic. Failures surface only after all fallbacks are exhausted. 【F:lib/services/auth_supabase_service.dart†L931-L992】
- **Role/bootstrap resolution after sign-in** — `AuthProvider` listens to Supabase auth state changes, pulls user metadata through `fetchCurrentUser`, and validates active clinic access via `resolveActiveAccountOrThrow`. Any non-transient error flags the cached user as disabled before forcing a sign-out. 【F:lib/providers/auth_provider.dart†L94-L451】【F:lib/services/auth_supabase_service.dart†L652-L703】
- **Login UI** — The login screen triggers `auth.signIn` and immediately inspects `auth.isDisabled` / `auth.isLoggedIn` before the provider finishes its refresh cycle, which can race with the background bootstrap that determines whether the session is usable. 【F:lib/screens/auth/login_screen.dart†L130-L170】

## Pain points & risks
1. **Race between UI checks and provider refresh** – Because `AuthProvider.signIn` simply proxies `_auth.signIn` without waiting for `_networkRefreshAndMark` / `_ensureActiveAccountOrSignOut`, the login view may read stale `isDisabled` or `isLoggedIn` values. That leads to confusing states (e.g. disabled banner even when the new session will later succeed, or navigation before guards finish). 【F:lib/providers/auth_provider.dart†L209-L212】【F:lib/screens/auth/login_screen.dart†L150-L168】
2. **Weak verification of provisioning success** – Owner/employee creation paths treat any non-null response as success for the legacy RPCs and only log mismatches, making it hard to distinguish between "account created" and "user already missing prerequisites". We also do not confirm that `profiles.account_id` and `account_users.role` align before returning to the UI. 【F:lib/services/auth_supabase_service.dart†L850-L991】
3. **No automated regression coverage** – There are no tests that assert the expected Supabase-side artifacts (auth user, `profiles`, `account_users`) after provisioning, nor that login guards sign out disabled or orphaned accounts. That makes it difficult to prevent future regressions when policies or edge functions change.

## Phased remediation plan
### Phase 1 — Instrumentation & diagnostics
- Extend `AuthSupabaseService.registerOwner` / `registerEmployee` to capture and return structured results (created user UID, account ID, role) so the admin UI can surface precise status and log mismatches for follow-up. 【F:lib/services/auth_supabase_service.dart†L824-L992】
- Add temporary telemetry hooks (dev-only logs) around `_networkRefreshAndMark` and `_ensureActiveAccountOrSignOut` to record when account resolution fails, helping reproduce the owner/employee login issues the QA team observed. 【F:lib/providers/auth_provider.dart†L285-L405】

### Phase 2 — Sign-in flow hardening
- Introduce an awaited `AuthProvider.signInAndRefresh` helper that awaits a complete refresh/validation cycle before returning to the UI, emitting an explicit status (`success`, `disabled`, `noAccount`, etc.). Update `LoginScreen._submit` to use the richer result instead of checking synchronous flags. 【F:lib/providers/auth_provider.dart†L209-L212】【F:lib/screens/auth/login_screen.dart†L150-L170】
- Guard navigation inside `_checkAndRouteIfSignedIn` so that it only fires after the provider reports a resolved account (or confirmed super-admin), preventing premature routing when background validation will eventually sign out the session. 【F:lib/screens/auth/login_screen.dart†L64-L127】

### Phase 3 — Provisioning guarantees & role clarity
- After successful owner/employee creation, re-query `profiles` / `account_users` to assert the expected `account_id`, `role`, and `disabled=false` flags; throw descriptive errors if the dataset is incomplete so admins can correct data before the user attempts to login. 【F:lib/services/auth_supabase_service.dart†L652-L703】【F:lib/services/auth_supabase_service.dart†L824-L992】
- Store the resolved role in app metadata during provisioning (using the service client) to provide a quick, reliable fallback for role detection during login bootstrap. 【F:lib/services/auth_supabase_service.dart†L931-L992】
- Clarify role-based permissions by seeding owner-specific feature grants (or explicitly documenting that an empty feature set means full access) to avoid ambiguity when new permission checks are added. 【F:lib/providers/auth_provider.dart†L430-L450】

### Phase 4 — Regression safety net
- Create integration-style tests (using Supabase test harness or mock clients) that provision an owner and employee via `AuthSupabaseService`, then assert that both can sign in, resolve their clinic, and that disabled/frozen scenarios trigger forced sign-out. 【F:lib/services/auth_supabase_service.dart†L824-L992】【F:lib/providers/auth_provider.dart†L327-L405】
- Add widget tests for `LoginScreen` covering success, disabled-account rejection, and missing-account errors based on the new status object returned from the provider.

Each phase builds on the previous one: first we get better visibility, then stabilize the client flow, then guarantee data integrity, and finally lock the behaviour down with automated coverage.
