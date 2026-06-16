# Deploy slack-deadline-notify Edge Function to Supabase
# Usage: .\scripts\deploy-slack-function.ps1

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Tools = Join-Path $Root ".tools"
$Cli = Join-Path $Tools "supabase.exe"

function Ensure-SupabaseCli {
  if (Test-Path $Cli) { return $Cli }
  New-Item -ItemType Directory -Force -Path $Tools | Out-Null
  $release = Invoke-RestMethod -Uri "https://api.github.com/repos/supabase/cli/releases/latest"
  $tag = $release.tag_name.TrimStart('v')
  $assetName = "supabase_${tag}_windows_amd64.tar.gz"
  $asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
  if (-not $asset) {
    $asset = $release.assets | Where-Object { $_.name -match "windows_amd64.*\.tar\.gz$" } | Select-Object -First 1
  }
  if (-not $asset) { throw "Supabase CLI for Windows not found" }
  $tar = Join-Path $Tools "supabase.tar.gz"
  Write-Host "Downloading Supabase CLI..."
  Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tar
  tar -xzf $tar -C $Tools
  Remove-Item $tar -Force
  if (-not (Test-Path $Cli)) { throw "Failed to extract supabase.exe" }
  Write-Host "Supabase CLI: $Cli"
  return $Cli
}

$supabase = Ensure-SupabaseCli
Set-Location $Root

Write-Host ""
Write-Host "=== Step 1/3: Login ===" -ForegroundColor Cyan
& $supabase projects list 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Run supabase login (browser will open)"
  & $supabase login
}

Write-Host ""
Write-Host "=== Step 2/3: Link project ===" -ForegroundColor Cyan
& $supabase link --project-ref zffoaelhfskphgihbsll

Write-Host ""
Write-Host "=== Step 3/3: Deploy function ===" -ForegroundColor Cyan
& $supabase functions deploy slack-deadline-notify --no-verify-jwt

Write-Host ""
Write-Host "Done. Test with Slack notification check in the admin UI." -ForegroundColor Green
