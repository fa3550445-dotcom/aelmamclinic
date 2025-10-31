import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:aelmamclinic/services/auth_supabase_service.dart';

class _FakeAccount {
  _FakeAccount({required this.id, required this.name, this.frozen = false});

  final String id;
  final String name;
  bool frozen;
}

class _FakeUser {
  _FakeUser({
    required this.id,
    required this.email,
    required this.password,
    required this.accountId,
    required this.role,
  });

  final String id;
  final String email;
  final String password;
  final String accountId;
  final String role;
  bool disabled = false;
}

class _FakeSupabaseBackend {
  final Map<String, _FakeAccount> accounts = <String, _FakeAccount>{};
  final Map<String, _FakeUser> usersByEmail = <String, _FakeUser>{};

  int _accountCounter = 0;
  int _userCounter = 0;
  _FakeUser? _currentUser;

  ProvisioningResult registerOwner({
    required String clinicName,
    required String email,
    required String password,
    String? ownerRole,
  }) {
    final accountId = 'acc-${++_accountCounter}';
    final userId = 'user-${++_userCounter}';
    final normalizedEmail = email.toLowerCase();
    final role = (ownerRole ?? 'owner').toLowerCase();

    accounts[accountId] = _FakeAccount(id: accountId, name: clinicName);
    final user = _FakeUser(
      id: userId,
      email: normalizedEmail,
      password: password,
      accountId: accountId,
      role: role,
    );
    usersByEmail[normalizedEmail] = user;

    return ProvisioningResult(
      accountId: accountId,
      userUid: userId,
      role: role,
    );
  }

  ProvisioningResult registerEmployee({
    required String accountId,
    required String email,
    required String password,
  }) {
    final normalizedEmail = email.toLowerCase();
    final account = accounts[accountId];
    if (account == null) {
      throw StateError('Account $accountId is missing.');
    }

    final userId = 'user-${++_userCounter}';
    final user = _FakeUser(
      id: userId,
      email: normalizedEmail,
      password: password,
      accountId: account.id,
      role: 'employee',
    );
    usersByEmail[normalizedEmail] = user;

    return ProvisioningResult(
      accountId: account.id,
      userUid: userId,
      role: user.role,
    );
  }

  void signIn(String email, String password) {
    final user = usersByEmail[email.toLowerCase()];
    if (user == null || user.password != password) {
      throw const AuthException('Invalid credentials');
    }
    _currentUser = user;
  }

  void signOut() {
    _currentUser = null;
  }

  Map<String, dynamic>? fetchCurrentUser() {
    final user = _currentUser;
    if (user == null) {
      return null;
    }
    return {
      'uid': user.id,
      'email': user.email,
      'accountId': user.accountId,
      'role': user.role,
      'disabled': user.disabled,
      'isSuperAdmin': user.role == 'superadmin',
    };
  }

  String? resolveAccountId() => _currentUser?.accountId;

  ActiveAccount resolveActiveAccountOrThrow() {
    final user = _currentUser;
    if (user == null) {
      throw StateError('Not signed in.');
    }
    final account = accounts[user.accountId];
    if (account == null) {
      throw StateError('No active clinic found for this user.');
    }
    if (account.frozen) {
      throw AccountFrozenException(account.id);
    }
    if (user.disabled) {
      throw AccountUserDisabledException(account.id);
    }
    return ActiveAccount(id: account.id, role: user.role, canWrite: true);
  }

  bool get isSuperAdmin => _currentUser?.role == 'superadmin';

  _FakeUser? get currentUser => _currentUser;

  void freezeAccount(String accountId, bool frozen) {
    final account = accounts[accountId];
    if (account != null) {
      account.frozen = frozen;
    }
  }

  void disableUser(String email, bool disabled) {
    final user = usersByEmail[email.toLowerCase()];
    if (user != null) {
      user.disabled = disabled;
    }
  }

  void removeAccount(String accountId) {
    accounts.remove(accountId);
  }
}

class _HarnessAuthSupabaseService extends AuthSupabaseService {
  _HarnessAuthSupabaseService(this.backend);

  final _FakeSupabaseBackend backend;

  @override
  Future<ProvisioningResult> registerOwner({
    required String clinicName,
    required String email,
    required String password,
    String? ownerRole,
  }) async {
    return backend.registerOwner(
      clinicName: clinicName,
      email: email,
      password: password,
      ownerRole: ownerRole,
    );
  }

  @override
  Future<ProvisioningResult> registerEmployee({
    required String accountId,
    required String email,
    required String password,
  }) async {
    return backend.registerEmployee(
      accountId: accountId,
      email: email,
      password: password,
    );
  }

  @override
  Future<AuthResponse> signIn(String email, String password) async {
    backend.signIn(email, password);
    return AuthResponse(session: null, user: null);
  }

  @override
  Future<void> signOut() async {
    backend.signOut();
  }

  @override
  Future<Map<String, dynamic>?> fetchCurrentUser() async {
    return backend.fetchCurrentUser();
  }

  @override
  Future<String?> resolveAccountId() async {
    return backend.resolveAccountId();
  }

  @override
  Future<ActiveAccount> resolveActiveAccountOrThrow() async {
    return backend.resolveActiveAccountOrThrow();
  }

  @override
  bool get isSuperAdmin => backend.isSuperAdmin;

  @override
  bool get isSignedIn => backend.currentUser != null;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'fake-anon-key',
    );
  });

  group('AuthSupabaseService integration harness', () {
    late _FakeSupabaseBackend backend;
    late _HarnessAuthSupabaseService service;

    setUp(() {
      backend = _FakeSupabaseBackend();
      service = _HarnessAuthSupabaseService(backend);
    });

    test('owner and employee provisioning result in active accounts', () async {
      const ownerEmail = 'owner@clinic.test';
      const ownerPassword = 'owner-pass';
      final ownerResult = await service.registerOwner(
        clinicName: 'QA Clinic',
        email: ownerEmail,
        password: ownerPassword,
      );

      expect(ownerResult.accountId, isNotEmpty);
      expect(ownerResult.userUid, isNotEmpty);
      expect(ownerResult.role, equals('owner'));

      const employeeEmail = 'assistant@clinic.test';
      final employeeResult = await service.registerEmployee(
        accountId: ownerResult.accountId!,
        email: employeeEmail,
        password: 'emp-pass',
      );

      expect(employeeResult.accountId, equals(ownerResult.accountId));
      expect(employeeResult.role, equals('employee'));

      await service.signIn(ownerEmail, ownerPassword);
      final ownerGuard = await service.resolveActiveAccountOrThrow();
      expect(ownerGuard.id, equals(ownerResult.accountId));
      expect(ownerGuard.role, equals('owner'));

      await service.signOut();

      await service.signIn(employeeEmail, 'emp-pass');
      final employeeGuard = await service.resolveActiveAccountOrThrow();
      expect(employeeGuard.id, equals(ownerResult.accountId));
      expect(employeeGuard.role, equals('employee'));
    });

    test('resolveActiveAccountOrThrow surfaces frozen account', () async {
      final owner = await service.registerOwner(
        clinicName: 'Freeze Clinic',
        email: 'freeze-owner@clinic.test',
        password: 'owner-pass',
      );
      const employeeEmail = 'freeze-emp@clinic.test';
      await service.registerEmployee(
        accountId: owner.accountId!,
        email: employeeEmail,
        password: 'emp-pass',
      );

      backend.freezeAccount(owner.accountId!, true);

      await service.signIn(employeeEmail, 'emp-pass');
      expect(
        () => service.resolveActiveAccountOrThrow(),
        throwsA(isA<AccountFrozenException>()),
      );
    });

    test('resolveActiveAccountOrThrow surfaces disabled user', () async {
      final owner = await service.registerOwner(
        clinicName: 'Disabled Clinic',
        email: 'disabled-owner@clinic.test',
        password: 'owner-pass',
      );
      const employeeEmail = 'disabled-emp@clinic.test';
      await service.registerEmployee(
        accountId: owner.accountId!,
        email: employeeEmail,
        password: 'emp-pass',
      );

      backend.disableUser(employeeEmail, true);

      await service.signIn(employeeEmail, 'emp-pass');
      expect(
        () => service.resolveActiveAccountOrThrow(),
        throwsA(isA<AccountUserDisabledException>()),
      );
    });

    test('resolveActiveAccountOrThrow surfaces orphaned accounts', () async {
      final owner = await service.registerOwner(
        clinicName: 'Missing Clinic',
        email: 'missing-owner@clinic.test',
        password: 'owner-pass',
      );
      const employeeEmail = 'missing-emp@clinic.test';
      await service.registerEmployee(
        accountId: owner.accountId!,
        email: employeeEmail,
        password: 'emp-pass',
      );

      backend.removeAccount(owner.accountId!);

      await service.signIn(employeeEmail, 'emp-pass');
      expect(
        () => service.resolveActiveAccountOrThrow(),
        throwsA(isA<StateError>()),
      );
    });
  });
}
