param(
  [string]$LauncherHome,
  [switch]$NoBuild,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# Rebuild the patched launcher and repoint the existing shortcuts at it.
#
# Why versioned file names: Windows refuses to overwrite an exe image that is currently mapped, and the
# launcher is usually running while a fix is being tested. So every build gets its own name
# (DSHLauncher-custom-v3.exe, v4, ...) and the shortcuts are repointed instead of the binary being
# swapped in place.
#
# The dsh-desktop-shell plugin owns DSHLauncher.exe and re-copies it on every boot; that is why the
# patched build lives under its own name at all.
#
# Shortcut names are yours: every desktop / start-menu / startup link whose target points at a
# DSHLauncher*.exe inside the launcher home is repointed in place, so renames survive.
#
# Usage:  powershell -File rebuild-launcher.ps1             (build + repoint)
#         powershell -File rebuild-launcher.ps1 -NoBuild    (repoint only)
#         powershell -File rebuild-launcher.ps1 -Home D:\dsh-desktop

if (-not $LauncherHome) { $LauncherHome = [IO.Path]::Combine($env:USERPROFILE, 'dsh-desktop') }
$repo = Split-Path -Parent $PSScriptRoot

$src = @(
  [IO.Path]::Combine($LauncherHome, 'custom', 'DSHLauncher.patched.cs'),
  [IO.Path]::Combine($repo, 'src', 'DSHLauncher.patched.cs')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$icon = @(
  [IO.Path]::Combine($LauncherHome, 'DSHLauncher.ico'),
  [IO.Path]::Combine($repo, 'src', 'DSHLauncher.ico')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$nameFile = [IO.Path]::Combine($LauncherHome, 'custom', 'build-name.txt')

function Write-Note($m) { if (-not $Quiet) { $m } }

if (-not (Test-Path -LiteralPath $LauncherHome)) { throw "launcher home not found: $LauncherHome (install dsh-desktop-shell first)" }

# ---- next build name ----
$current = if (Test-Path -LiteralPath $nameFile) { (Get-Content -LiteralPath $nameFile -Raw).Trim() } else { 'DSHLauncher-custom-v0.exe' }
$n = 0
if ($current -match 'DSHLauncher-custom-v(\d+)\.exe') { $n = [int]$Matches[1] }
$out = [IO.Path]::Combine($LauncherHome, ('DSHLauncher-custom-v' + ($n + 1) + '.exe'))

if (-not $NoBuild) {
  if (-not $src) { throw "patched source missing (looked in <home>\\custom and <repo>\\src)" }
  if (-not $icon) { throw 'DSHLauncher.ico missing (looked in <home> and <repo>\\src)' }
  if (-not (Test-Path -LiteralPath $csc)) { throw "legacy csc not found: $csc" }
  foreach ($ref in @('Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll')) {
    if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($LauncherHome, $ref)))) { throw "missing $ref in $LauncherHome - run dsh-desktop-shell once so it copies its runtime files" }
  }

  $stage = [IO.Path]::Combine($env:TEMP, ('DSHLauncher-build-' + [guid]::NewGuid().ToString('N') + '.exe'))
  $cscArgs = @(
    '/nologo', '/target:winexe', '/optimize+', '/platform:anycpu',
    ('/win32icon:' + $icon), ('/out:' + $stage),
    '/r:System.dll', '/r:System.Core.dll', '/r:System.Windows.Forms.dll',
    '/r:System.Drawing.dll', '/r:System.Web.Extensions.dll', '/r:System.Net.Http.dll',
    ('/r:' + [IO.Path]::Combine($LauncherHome, 'Microsoft.Web.WebView2.Core.dll')),
    ('/r:' + [IO.Path]::Combine($LauncherHome, 'Microsoft.Web.WebView2.WinForms.dll')),
    $src
  )
  & $csc @cscArgs 2>&1 | Where-Object { $_ -notmatch 'warning CS1998|warning CS0219' } | ForEach-Object { Write-Note $_ }
  if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }
  New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($nameFile)) | Out-Null
  Copy-Item -LiteralPath $stage -Destination $out -Force
  Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
  Set-Content -LiteralPath $nameFile -Value (Split-Path $out -Leaf) -Encoding ascii
  Write-Note ('built {0} ({1} bytes)' -f $out, (Get-Item -LiteralPath $out).Length)
} else {
  $out = [IO.Path]::Combine($LauncherHome, $current)
  Write-Note "repointing only, using $out"
}

# ---- keep the plugin's generated shortcut script pointed at the newest custom build ----
$profileRoot = [IO.Path]::Combine($env:USERPROFILE, '.dsh', 'profiles')
Get-ChildItem -LiteralPath $profileRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
  $installJs = [IO.Path]::Combine($_.FullName, 'node_modules', 'dsh-desktop-shell', 'lib', 'install.js')
  if (-not (Test-Path -LiteralPath $installJs)) { return }
  $oldLine = '    "$exe = Join-Path $DshHome ''DSHLauncher.exe''",'
  $newLine = ('    "$exe = Get-ChildItem -Path $DshHome -Filter ''DSHLauncher-custom*.exe'' -ErrorAction SilentlyContinue | ' +
              'Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { $_.FullName }",' + "`r`n" +
              '    "if (-not $exe) { $exe = Join-Path $DshHome ''DSHLauncher.exe'' }",')
  $text = [IO.File]::ReadAllText($installJs)
  if (-not $text.Contains('DSHLauncher-custom') -and $text.Contains($oldLine)) {
    [IO.File]::WriteAllText($installJs, $text.Replace($oldLine, $newLine), (New-Object System.Text.UTF8Encoding($false)))
    Write-Note "patched plugin shortcut generator: $installJs"
  }
}

# ---- repoint every existing launcher link, keeping its file name ----
$wsh = New-Object -ComObject WScript.Shell
$folders = @(
  [Environment]::GetFolderPath('Desktop'),
  [Environment]::GetFolderPath('Programs'),
  [Environment]::GetFolderPath('Startup')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

$repointed = 0
$links = @()
foreach ($folder in $folders) { $links += Get-ChildItem -LiteralPath $folder -Filter '*.lnk' -ErrorAction SilentlyContinue }

foreach ($link in $links) {
  try { $s = $wsh.CreateShortcut($link.FullName) } catch { continue }
  $target = [string]$s.TargetPath
  if (-not $target) { continue }
  if (-not ($target -like "$LauncherHome\DSHLauncher*")) { continue }
  if ($target -eq $out) { continue }
  try {
    $s.TargetPath = $out
    $s.WorkingDirectory = $LauncherHome
    $s.Save()
    $repointed++
    Write-Note ('repointed {0} -> {1} {2}' -f $link.FullName, (Split-Path $out -Leaf), $s.Arguments)
  } catch {
    Write-Note ('could not repoint {0}: {1}' -f $link.FullName, $_.Exception.Message)
  }
}

# ---- the plugin must not recreate or retarget shortcuts any more ----
$frozen = [IO.Path]::Combine($LauncherHome, '.shortcuts-frozen')
if (-not (Test-Path -LiteralPath $frozen)) {
  Set-Content -LiteralPath $frozen -Encoding utf8 -Value 'Shortcut names and targets are owned by hand - the boot-time repair must not touch them.'
}

# ---- drop builds nothing points at ----
$live = Split-Path $out -Leaf
foreach ($b in Get-ChildItem -LiteralPath $LauncherHome -Filter 'DSHLauncher-custom*.exe' | Sort-Object LastWriteTime -Descending) {
  if ($b.Name -eq $live) { continue }
  $inUse = $false
  foreach ($link in $links) {
    try { if ($wsh.CreateShortcut($link.FullName).TargetPath -eq $b.FullName) { $inUse = $true } } catch { }
  }
  $running = Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($b.Name)) -ErrorAction SilentlyContinue
  if (-not $inUse -and -not $running) { Remove-Item -LiteralPath $b.FullName -Force -ErrorAction SilentlyContinue }
}

Write-Note ('live build: {0}   links repointed: {1}' -f $out, $repointed)
