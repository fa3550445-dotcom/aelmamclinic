<# tools\cloud-reset-and-push.ps1
   يعمل Factory Reset على قاعدة البيانات السحابية المرتبطة ثم يطبق كل الهجرات الحالية.
   ينشر وظائف Edge إن وُجدت.

   التشغيل:
     pwsh -File tools\cloud-reset-and-push.ps1 -Yes
   (احذف -Yes لو تبغى تأكيد قبل الحذف)
#>

param(
  [switch]$Yes = $false,
  [switch]$SkipFunctions = $false
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ===== إعدادات مشروعك =====
$ProjectRef  = "wiypiofuyrayywciovoo"
$SupabaseUrl = "https://wiypiofuyrayywciovoo.supabase.co"
$AnonKey     = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndpeXBpb2Z1eXJheXl3Y2lvdm9vIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTQ1NjczOTcsImV4cCI6MjA3MDE0MzM5N30.TwveOqJJfM3eDVwsxaL76YkyVAAzZxeMVxGzLT8EC3E"
$ServiceRole = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndpeXBpb2Z1eXJheXl3Y2lvdm9vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1NDU2NzM5NywiZXhwIjoyMDcwMTQzMzk3fQ.owHpuCMbx6Bw3zvYvW0pNFQN9Ml6_vrT9zx8a5xQ36s"

# إلى جذر المشروع إن شُغّل من tools\
if ($PSScriptRoot) { Set-Location (Resolve-Path (Join-Path $PSScriptRoot "..")) }

# فحص supabase
try { supabase --version | Out-Null } catch {
  Write-Error "Supabase CLI غير متاح. ثبّته أولاً."; exit 1
}

# ===== تجهيز env للاستخدامات الأخرى (لا يُمرَّر للـpush) =====
Write-Host "== Prepare env file =="
New-Item -ItemType Directory -Force -Path "supabase" | Out-Null
New-Item -ItemType Directory -Force -Path "supabase\functions" | Out-Null
$EnvFile = "supabase\.env.production"
@(
  "SUPABASE_URL=$SupabaseUrl",
  "SUPABASE_ANON_KEY=$AnonKey",
  "SUPABASE_SERVICE_ROLE=$ServiceRole"
) | Set-Content -LiteralPath $EnvFile -Encoding UTF8

# تأكد من تجاهله في git
$gi = ".gitignore"
if (Test-Path $gi) {
  $gitIgnore = Get-Content -Raw -LiteralPath $gi
  if ($gitIgnore -notmatch [regex]::Escape("supabase/.env.production")) {
    Add-Content -LiteralPath $gi -Value "`nsupabase/.env.production"
  }
} else {
  Set-Content -LiteralPath $gi -Value "supabase/.env.production" -Encoding UTF8
}

# ===== ربط المشروع =====
Write-Host "== Linking project =="
supabase link --project-ref $ProjectRef | Out-Null

# ===== تأكيد الحذف =====
if (-not $Yes) {
  Write-Warning "سيتم حذف كل بيانات قاعدة البيانات السحابية وإعادة بناء المخطط من الهجرات!"
  $answer = Read-Host "اكتب YES للتأكيد"
  if ($answer -ne "YES") { Write-Host "تم الإلغاء."; exit 0 }
}

# ===== Reset السحابة (لا تستخدم --password/--env-file) =====
Write-Host "== Cloud RESET (destructive) =="
supabase db reset --linked --yes

# ===== Push كل الهجرات الحالية =====
Write-Host "== Dry run =="
$dry = (supabase db push --linked --dry-run | Out-String)

$needIncludeAll = $dry -match "Found local migration files to be inserted before the last migration on remote database"
$remoteMissing  = $dry -match "Remote migration versions not found in local migrations directory"

if ($remoteMissing) {
  Write-Error "Remote migration versions مفقودة محليًا. أضف placeholders أو نفّذ repair ثم أعد المحاولة."
  exit 1
}

Write-Host "== Applying migrations =="
$pushOutput = @()
$pushSucceeded = $true
try {
  if ($needIncludeAll) {
    $pushOutput = & supabase db push --linked --include-all --yes 2>&1
  } else {
    $pushOutput = & supabase db push --linked --yes 2>&1
  }
  $pushOutput | ForEach-Object { Write-Host $_ }
} catch {
  $pushSucceeded = $false
}

if (-not $pushSucceeded -or $LASTEXITCODE -ne 0) {
  $text = ($pushOutput -join "`n")
  $matches = [regex]::Matches($text, 'Applying migration\s+([^\s]+\.sql)\.\.\.')
  $lastFile = if ($matches.Count -gt 0) { $matches[$matches.Count-1].Groups[1].Value } else { $null }

  Write-Error "فشل تطبيق الهجرات."
  if ($lastFile) {
    $migPath = Join-Path "supabase\migrations" $lastFile
    Write-Host "آخر ملف قبل الخطأ: $lastFile"
    if (Test-Path $migPath) { Write-Host "المسار: $migPath" }
  }
  Write-Host "Hint: supabase db push --linked --include-all --debug"
  exit 1
}

# ===== نشر Edge Functions =====
if (-not $SkipFunctions -and (Test-Path "supabase\functions")) {
  Write-Host "== Deploying Edge Functions =="
  Get-ChildItem "supabase\functions" -Directory -ErrorAction SilentlyContinue |
    ForEach-Object {
      supabase functions deploy $_.Name --project-ref $ProjectRef --yes
    }
}

# ===== تحقّق نهائي =====
Write-Host "== Verify Local | Remote =="
supabase migration list --linked

Write-Host "Done."
