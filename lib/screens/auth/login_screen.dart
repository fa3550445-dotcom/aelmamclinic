// lib/screens/auth/login_screen.dart
import 'dart:async';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:aelmamclinic/providers/auth_provider.dart';

// تصميم TBIAN
import 'package:aelmamclinic/core/theme.dart';
import 'package:aelmamclinic/core/neumorphism.dart';
import 'package:aelmamclinic/core/constants.dart';

// 👇 إضافات مهمة
import 'package:aelmamclinic/screens/admin/admin_dashboard_screen.dart';
import 'package:aelmamclinic/services/auth_supabase_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  StreamSubscription<AuthState>? _authSub;
  bool _navigating = false;

  // نضمن تشغيل الـ Bootstrap مرة واحدة عند وجود جلسة مسبقة
  bool _bootstrappedOnce = false;

  @override
  void initState() {
    super.initState();

    // 1) لو فيه جلسة محفوظة، قرّر الوجهة + فعّل المزامنة بعد أول إطار.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndRouteIfSignedIn();
    });

    // 2) استمع لتغيّر حالة المصادقة لتوجيه مضمون بعد signIn.
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((state) {
      if (state.event == AuthChangeEvent.signedIn) {
        _checkAndRouteIfSignedIn();
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  /// يقرر التوجيه حسب المستخدم الحالي (سوبر أدمن أو لا) ويضمن تشغيل المزامنة.
  Future<void> _checkAndRouteIfSignedIn() async {
    if (_navigating || !mounted) return;

    // أولوية لفحص الـ Provider (قد يكون حدد السوبر أدمن مسبقًا)
    final authProv = context.read<AuthProvider>();
    if (authProv.isLoggedIn) {
      // في حال الجلسة مسبقة، فعّل Bootstrap لمرة واحدة بدون سحب كامل
      if (!_bootstrappedOnce) {
        await authProv.bootstrapSync(
          pull: false,
          realtime: true,
          enableLogs: kDebugMode,
          debounce: const Duration(seconds: 1),
        );
        _bootstrappedOnce = true;
      }

      if (authProv.isSuperAdmin) {
        _navigating = true;
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const AdminDashboardScreen()),
        );
        return;
      }
    }

    // إن لم يتوفّر في المزود، نفحص جلسة Supabase مباشرة
    final u = Supabase.instance.client.auth.currentUser;
    if (u == null) return; // لم يتم تسجيل الدخول بعد

    // فعّل Bootstrap لمرة واحدة إذا لم يتم من قبل (جلسة محفوظة)
    // لا نضبط _bootstrappedOnce هنا لكي يُعاد المحاولة فور اكتمال تحميل المزود.

    final email = (u.email ?? '').toLowerCase();
    final isEmailSuper =
        email == AuthSupabaseService.superAdminEmail.toLowerCase();

    var isRoleSuper = false;
    try {
      final row = await Supabase.instance.client
          .from('account_users')
          .select('role')
          .eq('user_uid', u.id)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      final roleValue = row?['role']?.toString().toLowerCase();
      isRoleSuper = roleValue == 'superadmin';
    } catch (_) {
      // تجاهل أي خطأ في الفحص الاحتياطي
    }

    _navigating = true;
    if (!mounted) return;

    if (isEmailSuper || isRoleSuper) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const AdminDashboardScreen()),
      );
    } else {
      Navigator.of(context).pushReplacementNamed('/');
    }
  }

  Future<void> _submit(AuthProvider auth) async {
    if (_loading) return;

    // إلغاء التركيز لإغلاق لوحة المفاتيح
    FocusScope.of(context).unfocus();

    final email = _email.text.trim();
    final pass = _pass.text.trim();

    if (email.isEmpty || pass.isEmpty) {
      setState(() => _error = 'من فضلك أدخل البريد الإلكتروني وكلمة المرور.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await auth.signIn(email, pass);

      if (auth.isDisabled) {
        setState(() => _error = 'تم تعطيل هذا الحساب.');
        return;
      }

      // ✅ بعد نجاح تسجيل الدخول، نفّذ سحبًا أوليًا + Realtime
      if (auth.isLoggedIn) {
        await auth.bootstrapSync(
          pull: true,
          realtime: true,
          enableLogs: kDebugMode,
          debounce: const Duration(seconds: 1),
        );
        _bootstrappedOnce = true;
      }

      // نوجّه فورًا (ولا نعتمد فقط على المستمع).
      await _checkAndRouteIfSignedIn();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message.isNotEmpty
          ? 'فشل تسجيل الدخول: ${e.message}'
          : 'فشل تسجيل الدخول. تحقق من البيانات وحاول مرة أخرى.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'فشل تسجيل الدخول: $e');
    } finally {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthProvider>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/logo.png',
              height: 24,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
            const SizedBox(width: 8),
            const Text('تسجيل الدخول'),
          ],
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: kScreenPadding,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // بطاقة العنوان
                  NeuCard(
                    padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                    child: Row(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: kPrimaryColor.withValues(alpha: .1),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          padding: const EdgeInsets.all(10),
                          child: const Icon(Icons.lock_rounded,
                              color: kPrimaryColor, size: 26),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'مرحبًا بعودتك إلى ${AppConstants.appName}',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // البريد الإلكتروني
                  NeuField(
                    controller: _email,
                    labelText: 'البريد الإلكتروني',
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    prefix: const Icon(Icons.alternate_email_rounded),
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                  ),

                  const SizedBox(height: 12),

                  // كلمة المرور
                  NeuField(
                    controller: _pass,
                    labelText: 'كلمة المرور',
                    obscureText: _obscure,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(auth),
                    prefix: const Icon(Icons.lock_outline_rounded),
                    suffix: IconButton(
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_rounded,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                      tooltip: _obscure ? 'إظهار' : 'إخفاء',
                    ),
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                  ),

                  const SizedBox(height: 10),

                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: scheme.error,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),

                  const SizedBox(height: 6),

                  // زر الدخول
                  Align(
                    alignment: Alignment.centerRight,
                    child: _loading
                        ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: SizedBox(
                        height: 44,
                        width: 44,
                        child: CircularProgressIndicator(strokeWidth: 3),
                      ),
                    )
                        : NeuButton.primary(
                      label: 'دخول',
                      icon: Icons.login_rounded,
                      onPressed: () => _submit(auth),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
