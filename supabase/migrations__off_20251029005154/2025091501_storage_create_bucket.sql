-- 2025091501_storage_create_bucket.sql
-- إنشاء bucket chat-attachments بطريقة متوافقة مع مختلف إصدارات Storage
-- مع idempotency (لن يعيد الإنشاء إذا كان موجودًا).

DO $$
BEGIN
  -- لو البكت موجود مسبقًا، لا تفعل شيئًا
  IF EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'chat-attachments') THEN
    -- تأكد فقط أن الخاصية public = false
    UPDATE storage.buckets SET public = false WHERE id = 'chat-attachments';
    RETURN;
  END IF;

  -- جرّب التوقيع الشائع (اسم + عام/خاص)
  BEGIN
    PERFORM storage.create_bucket('chat-attachments', false);
  EXCEPTION WHEN undefined_function THEN
    -- إن لم تتوفر هذه الدالة بهذا التوقيع، جرّب توقيعًا أطول (نسخ أحدث)
    BEGIN
      -- بعض الإصدارات لديها وسيطات إضافية: (name, public, file_size_limit, allowed_mime_types, avif_autodetection)
      PERFORM storage.create_bucket('chat-attachments', false, NULL, NULL, TRUE);
    EXCEPTION WHEN undefined_function THEN
      -- كحل أخير: أنشئ الصف مباشرة (مسموح في Supabase) واضبط public=false
      INSERT INTO storage.buckets (id, name, public)
      VALUES ('chat-attachments', 'chat-attachments', false);
    END;
  END;
END$$;
