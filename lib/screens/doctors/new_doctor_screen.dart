// lib/screens/doctors/new_doctor_screen.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dart:ui' as ui show TextDirection;
import 'package:provider/provider.dart';
import '../../core/theme.dart';
import '../../core/neumorphism.dart';

import '../../models/doctor.dart';
import '../../models/account_user_summary.dart';
import '../../providers/auth_provider.dart';
import '../../services/db_service.dart';
import '../../services/auth_supabase_service.dart';
import 'employee_search_dialog.dart';

class NewDoctorScreen extends StatefulWidget {
  const NewDoctorScreen({super.key});

  @override
  State<NewDoctorScreen> createState() => _NewDoctorScreenState();
}

class _NewDoctorScreenState extends State<NewDoctorScreen> {
  final _formKey = GlobalKey<FormState>();

  final _doctorNameCtrl = TextEditingController();
  final _specializationCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();

  int? _selectedEmployeeId;
  AccountUserSummary? _selectedAccount;
  List<AccountUserSummary> _availableAccounts = const [];
  bool _loadingAccounts = false;
  final AuthSupabaseService _authService = AuthSupabaseService();
  Map<String, dynamic>? _selectedEmployee;

  TimeOfDay? _startTime;
  TimeOfDay? _endTime;

  @override
  void dispose() {
    _doctorNameCtrl.dispose();
    _specializationCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadAvailableAccounts();
    });
  }

  String _formatTimeOfDay(TimeOfDay? time) {
    if (time == null) return 'غير محدد';
    final now = DateTime.now();
    final dt = DateTime(now.year, now.month, now.day, time.hour, time.minute);
    return DateFormat('HH:mm').format(dt);
  }

  Future<TimeOfDay?> _pickTime(TimeOfDay? initialTime) {
    return showTimePicker(
      context: context,
      initialTime: initialTime ?? TimeOfDay.now(),
    );
  }

  Future<void> _openEmployeePicker() async {
    final selectedEmployee = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const EmployeeSearchDialog(),
    );

    if (selectedEmployee == null) return;

    setState(() {
      _selectedEmployee = Map<String, dynamic>.from(selectedEmployee);
      _selectedEmployeeId = selectedEmployee['id'] as int?;
      _doctorNameCtrl.text = (selectedEmployee['name'] ?? '').toString();
      _specializationCtrl.text = (selectedEmployee['jobTitle'] ?? '').toString();
      _phoneCtrl.text = (selectedEmployee['phoneNumber'] ?? '').toString();
    });

    final linkedUid = (selectedEmployee['userUid'] ??
            selectedEmployee['user_uid'])
        ?.toString()
        .trim();
    if (linkedUid == null || linkedUid.isEmpty) {
      setState(() => _selectedAccount = null);
      return;
    }

    final existing = _availableAccounts.firstWhere(
      (a) => a.userUid == linkedUid,
      orElse: () => AccountUserSummary(
        userUid: linkedUid,
        email: (selectedEmployee['email'] ?? '').toString(),
        disabled: selectedEmployee['disabled'] == true,
      ),
    );

    setState(() {
      _selectedAccount = existing;
    });
  }

  Future<void> _loadAvailableAccounts() async {
    final accountId = context.read<AuthProvider>().accountId;
    if (accountId == null || accountId.isEmpty) {
      return;
    }
    setState(() => _loadingAccounts = true);
    try {
      final accounts = await _authService.listAccountUsersWithEmail(
        accountId: accountId,
        includeDisabled: false,
      );
      final linked = await DBService.instance.getDoctorUserUids();
      final filtered = accounts.where((a) => !linked.contains(a.userUid)).toList();
      if (!mounted) return;
      setState(() {
        _availableAccounts = filtered;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر تحميل حسابات الموظفين: $e')),
      );
    } finally {
      if (mounted) setState(() => _loadingAccounts = false);
    }
  }

  Future<void> _pickAccount() async {
    if (_loadingAccounts) return;
    if (_availableAccounts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا يوجد حسابات متاحة غير مرتبطة بأطباء.')),
      );
      return;
    }

    final chosen = await showModalBottomSheet<AccountUserSummary>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return Directionality(
          textDirection: ui.TextDirection.rtl,
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: const Text('اختر حساب الموظف', style: TextStyle(fontWeight: FontWeight.w800)),
                  trailing: IconButton(
                    icon: const Icon(Icons.refresh_rounded),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _loadAvailableAccounts();
                    },
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _availableAccounts.length,
                    itemBuilder: (context, index) {
                      final acc = _availableAccounts[index];
                      return ListTile(
                        title: Text(acc.email.isEmpty ? acc.userUid : acc.email,
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: acc.email.isEmpty
                            ? Text(acc.userUid, style: TextStyle(color: scheme.onSurfaceVariant))
                            : Text(acc.userUid, style: TextStyle(color: scheme.onSurfaceVariant)),
                        trailing: const Icon(Icons.chevron_left_rounded),
                        onTap: () => Navigator.pop(ctx, acc),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (chosen != null && mounted) {
      setState(() {
        _selectedAccount = chosen;
      });
    }
  }

  Future<void> _saveDoctor() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedAccount == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يرجى ربط الطبيب بحساب موظف قبل الحفظ.')),
      );
      return;
    }

    final newDoctor = Doctor(
      employeeId: _selectedEmployeeId,
      userUid: _selectedAccount!.userUid,
      name: _doctorNameCtrl.text.trim(),
      specialization: _specializationCtrl.text.trim(),
      phoneNumber: _phoneCtrl.text.trim(),
      startTime: _formatTimeOfDay(_startTime),
      endTime: _formatTimeOfDay(_endTime),
    );

    await DBService.instance.insertDoctor(newDoctor);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم حفظ بيانات الطبيب بنجاح')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
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
              const Text('إضافة طبيب جديد'),
            ],
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: kScreenPadding,
            child: Form(
              key: _formKey,
              child: ListView(
                children: [
                  // اختيار الحساب المرتبط
                  NeuCard(
                    onTap: _openEmployeePicker,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Container(
                        decoration: BoxDecoration(
                          color: kPrimaryColor.withOpacity(.10),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.all(10),
                        child: const Icon(
                          Icons.badge_rounded,
                          color: kPrimaryColor,
                        ),
                      ),
                      title: Text(
                        _selectedEmployee == null
                            ? 'اختيار الموظف'
                            : (_selectedEmployee!['name']?.toString().isNotEmpty ?? false)
                                ? _selectedEmployee!['name'].toString()
                                : 'موظف رقم ${_selectedEmployeeId ?? ''}',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: Text(
                        _selectedEmployee == null
                            ? 'اضغط لاختيار الموظف لربط بياناته بالطبيب'
                            : (_selectedEmployee!['jobTitle']?.toString().isNotEmpty ?? false)
                                ? _selectedEmployee!['jobTitle'].toString()
                                : (_selectedEmployeeId != null
                                    ? 'معرّف الموظف: $_selectedEmployeeId'
                                    : 'سيُستخدم اسم الموظف الحالي'),
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(.6),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      trailing: const Icon(Icons.search_rounded),
                    ),
                  ),
                  const SizedBox(height: 12),

                  NeuCard(
                    onTap: _pickAccount,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Container(
                        decoration: BoxDecoration(
                          color: kPrimaryColor.withOpacity(.10),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.all(10),
                        child: const Icon(Icons.account_circle_rounded, color: kPrimaryColor),
                      ),
                      title: Text(
                        _selectedAccount == null
                            ? 'ربطه بحساب'
                            : (_selectedAccount!.email.isNotEmpty
                                ? _selectedAccount!.email
                                : _selectedAccount!.userUid),
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: Text(
                        _loadingAccounts
                            ? 'جارٍ تحميل الحسابات…'
                            : _availableAccounts.isEmpty
                                ? 'لا توجد حسابات موظفين متاحة للربط'
                                : 'اضغط لاختيار حساب الموظف المرتبط بهذا الطبيب',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(.6),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      trailing: _loadingAccounts
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.chevron_left_rounded),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // اسم الطبيب
                  NeuField(
                    controller: _doctorNameCtrl,
                    hintText: 'اسم الطبيب',
                    prefix: const Icon(Icons.person_rounded),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'الرجاء إدخال اسم الطبيب';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),

                  // التخصص
                  NeuField(
                    controller: _specializationCtrl,
                    hintText: 'التخصص',
                    prefix: const Icon(Icons.work_outline_rounded),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'الرجاء إدخال تخصص الطبيب';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),

                  // رقم الهاتف
                  NeuField(
                    controller: _phoneCtrl,
                    hintText: 'رقم الهاتف',
                    keyboardType: TextInputType.phone,
                    prefix: const Icon(Icons.call_rounded),
                  ),
                  const SizedBox(height: 16),

                  // ساعات المناوبة (من)
                  _TimePickerCard(
                    label: 'ساعات المناوبة (من)',
                    value: _formatTimeOfDay(_startTime),
                    icon: Icons.schedule_rounded,
                    onTap: () async {
                      final picked = await _pickTime(_startTime);
                      if (picked != null) setState(() => _startTime = picked);
                    },
                  ),
                  const SizedBox(height: 12),

                  // ساعات المناوبة (إلى)
                  _TimePickerCard(
                    label: 'ساعات المناوبة (إلى)',
                    value: _formatTimeOfDay(_endTime),
                    icon: Icons.schedule_outlined,
                    onTap: () async {
                      final picked = await _pickTime(_endTime);
                      if (picked != null) setState(() => _endTime = picked);
                    },
                  ),
                  const SizedBox(height: 20),

                  // زر الحفظ
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _saveDoctor,
                      icon: const Icon(Icons.save_rounded),
                      label: const Text('حفظ'),
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

class _TimePickerCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final VoidCallback onTap;

  const _TimePickerCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return NeuCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Container(
          decoration: BoxDecoration(
            color: kPrimaryColor.withOpacity(.10),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: kPrimaryColor),
        ),
        title: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          value,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface.withOpacity(.6),
            fontWeight: FontWeight.w600,
          ),
        ),
        trailing: const Icon(Icons.edit_calendar_rounded),
      ),
    );
  }
}
