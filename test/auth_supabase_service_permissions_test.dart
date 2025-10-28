import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:aelmamclinic/services/auth_supabase_service.dart';

class _StubAuthSupabaseService extends AuthSupabaseService {
  _StubAuthSupabaseService({required this.payload});

  final dynamic payload;
  Map<String, dynamic>? lastParams;
  int rpcCalls = 0;

  @override
  bool get isSuperAdmin => false;

  @override
  Future<dynamic> runRpc(String fn, {Map<String, dynamic>? params}) async {
    rpcCalls++;
    expect(fn, equals('my_feature_permissions'));
    lastParams = params == null ? null : Map<String, dynamic>.from(params);
    return payload;
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'fake-anon-key',
    );
  });

  test('fetchMyFeaturePermissions falls back to account default row', () async {
    final rpcPayload = {
      'account_id': 'acc-123',
      'user_uid': null,
      'allowed_features': ['reports', 'statistics'],
      'can_create': false,
      'can_update': true,
      'can_delete': false,
    };

    final service = _StubAuthSupabaseService(payload: rpcPayload);
    final permissions =
        await service.fetchMyFeaturePermissions(accountId: 'acc-123');

    expect(service.rpcCalls, equals(1));
    expect(service.lastParams, containsPair('p_account', 'acc-123'));
    expect(permissions.allowedFeatures, equals({'reports', 'statistics'}));
    expect(permissions.canCreate, isFalse);
    expect(permissions.canUpdate, isTrue);
    expect(permissions.canDelete, isFalse);
  });
}
