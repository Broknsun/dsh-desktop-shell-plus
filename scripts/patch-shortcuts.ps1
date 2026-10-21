param(
  [string]$ProfileRoot,
  [string]$LauncherHome
)

$ErrorActionPreference = 'Stop'

# Stop dsh-desktop-shell from fighting the customised launcher:
#   1. every backend boot re-runs installDesktop(), which (a) copies the stock DSHLauncher.exe back
#      over the home and (b) recreates / retargets the shortcuts, undoing your renames;
#   2. its generated shortcut script hardcodes DSHLauncher.exe as the target.
#
# After this script:
#   - the generated shortcut script prefers the newest DSHLauncher-custom*.exe and falls back to
#     DSHLauncher.exe when no custom build exists;
#   - boot-time repair no longer creates, renames or retargets shortcuts once the marker file
#     `.shortcuts-frozen` exists in the launcher home.
#
# Idempotent. Re-run after a dsh-desktop-shell upgrade, because the upgrade restores both files.

if (-not $ProfileRoot) { $ProfileRoot = [IO.Path]::Combine($env:USERPROFILE, '.dsh', 'profiles') }
if (-not $LauncherHome) { $LauncherHome = [IO.Path]::Combine($env:USERPROFILE, 'dsh-desktop') }

$libs = @()
Get-ChildItem -LiteralPath $ProfileRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
  $lib = [IO.Path]::Combine($_.FullName, 'node_modules', 'dsh-desktop-shell', 'lib')
  if (Test-Path -LiteralPath $lib) { $libs += $lib }
}

if ($libs.Count -eq 0) { throw "dsh-desktop-shell not found under $ProfileRoot" }

$oldExeLine = '    "$exe = Join-Path $DshHome ''DSHLauncher.exe''",'
$newExeLine = @'
    "$exe = Get-ChildItem -Path $DshHome -Filter 'DSHLauncher-custom*.exe' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { $_.FullName }",
    "if (-not $exe) { $exe = Join-Path $DshHome 'DSHLauncher.exe' }",
'@

# pristine boot-time install call (name differs per build; match on the shape, not the identifier)
$callPattern = '(?s)installDesktop\((?<facts>[\w.$]+\(ctx\)|\w+\(ctx\),\s*ctx),\s*\{\s*home,\s*startup:\s*readPreferences\(\{\s*home\s*\}\)\.autostart,\s*shortcuts:\s*undefined\s*\}\);'
$callReplacement = @'
const frozen = existsSync(join(home, ".shortcuts-frozen"));
      const report = installDesktop(FACTS, {
        home,
        startup: frozen ? false : readPreferences({ home }).autostart,
        shortcuts: frozen ? false : undefined
      });
'@

foreach ($lib in $libs) {
  $installJs = [IO.Path]::Combine($lib, 'install.js')
  $indexJs = [IO.Path]::Combine($lib, 'index.js')

  if (Test-Path -LiteralPath $installJs) {
    $t = [IO.File]::ReadAllText($installJs)
    if ($t.Contains('DSHLauncher-custom')) {
      Write-Host "install.js already patched: $installJs"
    } elseif ($t.Contains($oldExeLine)) {
      $t = $t.Replace($oldExeLine, $newExeLine.TrimEnd("`r", "`n"))
      [IO.File]::WriteAllText($installJs, $t, (New-Object System.Text.UTF8Encoding($false)))
      Write-Host "patched install.js: $installJs"
    } else {
      Write-Warning "install.js shortcut template not recognised (plugin version changed?): $installJs"
    }
  }

  if (Test-Path -LiteralPath $indexJs) {
    $t = [IO.File]::ReadAllText($indexJs)
    if ($t.Contains('shortcuts-frozen')) {
      Write-Host "index.js already patched: $indexJs"
    } else {
      $m = [regex]::Match($t, $callPattern)
      if ($m.Success) {
        $facts = $m.Groups['facts'].Value
        $block = ($callReplacement -replace 'FACTS', $facts)
        $t = $t.Remove($m.Index, $m.Length).Insert($m.Index, $block)
        [IO.File]::WriteAllText($indexJs, $t, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "patched index.js: $indexJs"
      } else {
        Write-Warning "index.js installDesktop call not recognised (plugin version changed?): $indexJs"
      }
    }
  }
}

# the marker itself: without it the patched index.js keeps repairing shortcuts as designed
$marker = [IO.Path]::Combine($LauncherHome, '.shortcuts-frozen')
if (-not (Test-Path -LiteralPath $marker)) {
  $dir = Split-Path -Parent $marker
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Set-Content -LiteralPath $marker -Encoding utf8 -Value 'Shortcut names and targets are owned by hand; boot-time repair must not touch them.'
  Write-Host "created marker: $marker"
} else {
  Write-Host "marker already present: $marker"
}

Write-Host 'done - restart the backend for the patched plugin code to load'
