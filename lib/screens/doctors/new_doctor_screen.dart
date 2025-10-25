// lib/screens/doctors/new_doctor_screen.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dart:ui' as ui show TextDirection;
import '../../core/theme.dart';
import '../../core/neumorphism.dart';

import '../../models/doctor.dart';
import '../../services/db_service.dart';
import '../../widgets/user_account_picker_dialog.dart';

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
  String? _selectedUserUid;
  String? _selectedUserEmail;
  bool _selectedAccountDisabled = false;

  TimeOfDay? _startTime;
  TimeOfDay? _endTime;

  @override
  void dispose() {
    _doctorNameCtrl.dispose();
    _specializationCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
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

  Future<void> _openAccountPicker() async {
    final exclude = await DBService.instance.getLinkedUserUids();
    if (_selectedUserUid != null && _selectedUserUid!.isNotEmpty) {
      exclude.remove(_selectedUserUid);
    }

    final selection = await showDialog<UserAccountSelection>(
      context: context,
      builder: (_) => UserAccountPickerDialog(
        excludeUserUids: exclude,
        initialUserUid: _selectedUserUid,
      ),
    );

    if (selection == null) return;

    final employee = await DBService.instance.getEmployeeByUserUid(selection.uid);
    if (!mounted) return;

    setState(() {
      _selectedUserUid = selection.uid;
      _selectedUserEmail = selection.email.isEmpty ? selection.uid : selection.email;
      _selectedAccountDisabled = selection.disabled;
      _selectedEmployeeId = employee?.id;

      if (employee != null) {
        if (employee.name.trim().isNotEmpty) {
          _doctorNameCtrl.text = employee.name.trim();
        }
        if (employee.jobTitle.trim().isNotEmpty) {
          _specializationCtrl.text = employee.jobTitle.trim();
        }
        if (employee.phoneNumber.trim().isNotEmpty) {
          _phoneCtrl.text = employee.phoneNumber.trim();
        }
      }
    });
  }

  Future<void> _saveDoctor() async {
    if (!_formKey.currentState!.validate()) return;

    if (_selectedUserUid == null || _selectedUserUid!.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الرجاء اختيار حساب Supabase لربط الطبيب.')),
      );
      return;
    }

    final newDoctor = Doctor(
      employeeId: _selectedEmployeeId,
      userUid: _selectedUserUid,
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
                    onTap: _openAccountPicker,
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
                        _selectedUserEmail ?? 'اختيار حساب الموظف',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: Text(
                        _selectedUserEmail == null
                            ? 'اضغط لاختيار حساب Supabase لربط الطبيب'
                            : _selectedAccountDisabled
                                ? '⚠️ هذا الحساب معطّل حاليًا'
                                : (_selectedEmployeeId != null
                                    ? 'موظف مرتبط ID: $_selectedEmployeeId'
                                    : 'سيُربط بالحساب المختار'),
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
