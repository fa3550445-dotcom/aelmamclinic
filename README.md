# aelmamclinic

إدارة متكاملة لعيادة ألمام مبنية على Flutter مع تخزين محلي SQLite ومزامنة Supabase.

## المتطلبات

- Flutter 3.35 أو أحدث.
- Dart 3.9 أو أحدث.
- Supabase CLI (اختياري للتشغيل المحلي).
- حساب Supabase مع مشروع مهيأ مسبقاً.

## الإعداد السريع

1. **تنزيل الحزم**
   ```bash
   flutter pub get
   ```
2. **تهيئة مفاتيح Supabase**
   استخدم ‎`--dart-define`‎ أو ملف ‎`.env`‎ (حسب بيئة النشر) لتوفير:
   - `SUPABASE_URL`
   - `SUPABASE_ANON_KEY`

   بديلًا عن إعادة بناء التطبيق يمكن وضع ملف ‎`config.json`‎ في مجلد البيانات الخاص
   بالمنصّة (مثل `C:\aelmam_clinic\config.json` على ويندوز) يحتوي على:

   ```json
   {
     "supabaseUrl": "https://your-project.supabase.co",
     "supabaseAnonKey": "ey..."
   }
   ```

   تُحمَّل هذه القيم تلقائيًا عند الإقلاع وتتفوق على الإعدادات المضمّنة. على
   ويندوز يتم البحث أيضًا في المسارات `D:\aelmam_clinic`, ومساري
   `%APPDATA%\aelmam_clinic` و`%LOCALAPPDATA%\aelmam_clinic`. يمكن تمرير مسار
   ملف مخصّص عبر المتغير البيئي `AELMAM_SUPABASE_CONFIG` أو `AELMAM_CONFIG`
   (أو تحديد مجلد عبر `AELMAM_DIR` / `AELMAM_CLINIC_DIR`).

3. **تهيئة Firebase (اختياري)**
   استورد إعدادات `firebase_options.dart` المطابقة لبيئتك.

## الإعداد المتقدم

### ضبط بيئة الدردشة

القيم الافتراضية معرفة في `lib/core/constants.dart`. يمكن تعديلها عبر `--dart-define` أو تحديث الملف نفسه:

| الثابت | الغرض | القيمة الافتراضية |
| --- | --- | --- |
| `chatPreferPublicUrls` | استخدام روابط عامة للمرفقات بدلاً من الروابط الموقعة | `false` |
| `chatMaxAttachmentBytes` | الحد الأقصى لحجم مرفقات الرسالة الواحدة (null لتعطيل) | 20 MB |
| `chatMaxSingleAttachmentBytes` | الحد الأقصى لكل ملف مفرد (null لتعطيل) | 10 MB |

### مفاتيح إضافية

- `storageSignedUrlTTLSeconds` يمكن ضبطه لتغيير عمر الروابط الموقعة.
- مسارات البيانات المحلية قابلة للتهيئة لكل منصة ضمن `AppConstants`.

## تشغيل الاختبارات

### اختبارات الوحدات

```bash
flutter test test/auth_provider_permissions_test.dart
```
يتحقق من بوابة الصلاحيات في `AuthProvider` (بما في ذلك حالات المشرف).

### اختبارات قاعدة البيانات

```bash
flutter test test/db_service_smoke_test.dart
```
ينشئ قاعدة SQLite مؤقتة ويختبر إدخال مريض وبث التغييرات عبر `DBService` والمستودع الجديد للمرضى.

## المراقبة والتشغيل

- يتم تسجيل الأعطال في ملف موجود ضمن دليل البيانات الخاص بالمنصة (مثل `C:\aelmam_clinic\crash_log.txt`) بالإضافة إلى `dart:developer`.
- سجلات Edge Functions (مثل `admin__create_employee`) تحتوي على `console.error` عند فشل الاستدعاءات.
- يمكن ضبط حدود المرفقات أو تعطيلها عبر الثوابت المذكورة أعلاه لتجنب استهلاك التخزين.

## معالم في الكود

- **مستودع المرضى المحلي**: `lib/services/db_service_parts/patient_local_repository.dart` يحتوي على عمليات CRUD الخاصة بالمرضى.
- **سياسات الصلاحيات**: `AuthProvider` يغلق الميزات افتراضياً حتى اكتمال التحميل، مع واجهات اختبار `debugSetPermissions` و`debugSetCurrentUser`.
- **مرفقات الدردشة**: `ChatService` يستخدم `_friendlyFileName` للرفع ويطبق حدود الحجم وفق `AppConstants`.

## المساهمة

1. أنشئ فرعاً جديداً.
2. نفّذ التعديلات وشغّل الاختبارات أعلاه.
3. أرسل طلب دمج موضحاً تغييرك.
