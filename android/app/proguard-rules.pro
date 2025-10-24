# قواعد مخصصة لحماية الكود

# إذا كنت تستخدم Flutter:
-keep class io.flutter.app.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }

# مثال لقواعد عامة (يمكنك إضافة قواعد أخرى حسب المكتبات المستخدمة)
-dontwarn okhttp3.**
-keep class okhttp3.** { *; }
