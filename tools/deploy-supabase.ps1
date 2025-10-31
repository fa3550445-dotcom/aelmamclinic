param([switch]$SkipFunctions = $false)
$ErrorActionPreference = "Stop"

$MigrationsDir = "supabase\migrations"
$OffDir        = "supabase\migrations_off"
New-Item -ItemType Directory -Force -Path $MigrationsDir | Out-Null

Write-Host "== Sync placeholders =="
$raw = supabase migration list --linked | Out-String
$remoteOnly = [System.Collections.Generic.HashSet[string]]::new()

foreach ($line in ($raw -split "`r?`n")) {
  if ($line -match '^\s*(?<local>\d{6,}|)\s*\|\s*(?<remote>\d{6,}|)\s*\|') {
    $l = $Matches['local'].Trim()
    $r = $Matches['remote'].Trim()
    if ($l -eq 'Local' -or $l -match '^-+$') { continue }
    if ($l -eq '' -and $r -ne '') { $remoteOnly.Add($r) | Out-Null }
  }
}

foreach ($ver in $remoteOnly) {
  $inMain = @(Get-ChildItem $MigrationsDir -Filter ("{0}_*.sql" -f $ver) -ErrorAction SilentlyContinue).Count -gt 0
  if (-not $inMain) {
    $cand = @(Get-ChildItem $OffDir -Filter ("{0}_*.sql" -f $ver) -ErrorAction SilentlyContinue)
    if ($cand.Count -gt 0) {
      Move-Item $cand[0].FullName $MigrationsDir -Force
      Write-Host "moved back: $ver"
    } else {
      $ph = Join-Path $MigrationsDir ("{0}_placeholder.sql" -f $ver)
      if (-not (Test-Path $ph)) {
        Set-Content -LiteralPath $ph -Value ("-- placeholder for remote-applied version {0}" -f $ver) -Encoding UTF8
        Write-Host "created placeholder: $ver"
      }
    }
  }
}

Write-Host "== Pull to stabilize history =="
try { supabase db pull --linked | Out-Null } catch { Write-Host $_.Exception.Message }

Write-Host "== Dry run =="
$out = supabase db push --linked --dry-run | Out-String
$out | Write-Host

if ($out -match "Found local migration files to be inserted before the last migration on remote database") {
  Write-Host "== Applying with --include-all =="
  supabase db push --linked --include-all --yes
} elseif ($out -match "Remote migration versions not found in local migrations directory") {
  Write-Error "Remote-only versions still missing locally. Ensure placeholders exist, then rerun."
  exit 1
} elseif ($out -match "Would push these migrations:") {
  Write-Host "== Applying pending migrations =="
  supabase db push --linked --yes
} else {
  Write-Host "No pending migrations."
}

if (-not $SkipFunctions) {
  if (Test-Path "supabase\functions") {
    Write-Host "== Deploying Edge Functions =="
    Get-ChildItem "supabase\functions" -Directory | ForEach-Object {
      supabase functions deploy $_.Name --yes
    }
  }
}

Write-Host "== Verify =="
supabase migration list --linked
Write-Host "Done."
