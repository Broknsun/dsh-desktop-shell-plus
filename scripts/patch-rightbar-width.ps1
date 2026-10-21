param([string]$DshRoot)

$ErrorActionPreference = 'Stop'

# Patch DSH right-sidebar (rightbar) first-open width: 45% -> 20%.
# Re-run after a dsh upgrade; idempotent. Browser needs Ctrl+F5 afterwards.

$target = $null
if ($DshRoot) {
  $p = [IO.Path]::Combine($DshRoot, 'node_modules', '@deepseek-ai', 'dsh-client-ui-layout', 'lib', 'client.js')
  if (Test-Path -LiteralPath $p) { $target = $p }
} else {
  $found = @()
  Get-ChildItem -LiteralPath ([IO.Path]::Combine($env:LOCALAPPDATA, 'npm-cache', '_npx')) -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $c = [IO.Path]::Combine($_.FullName, 'node_modules', '@deepseek-ai', 'dsh-client-ui-layout', 'lib', 'client.js')
    if (Test-Path -LiteralPath $c) { $found += (Get-Item -LiteralPath $c) }
  }
  if ($found.Count -gt 0) { $target = ($found | Sort-Object LastWriteTime -Descending)[0].FullName }
}

if (-not $target) { throw 'dsh-client-ui-layout not found; run dsh once first' }
Write-Host ('target: ' + $target)

$text = [IO.File]::ReadAllText($target)
$orig = $text

$pairs = @(
  @('const RIGHTBAR_DEFAULT_RATIO = .45;', 'const RIGHTBAR_DEFAULT_RATIO = .2;'),
  @('const rightbarPreference = layoutInfo.rightbar ?? viewport * .45;', 'const rightbarPreference = layoutInfo.rightbar ?? viewport * .2;'),
  @('clampWidth(rightbar, 300, viewport * RIGHTBAR_MAX_RATIO)', 'clampWidth(rightbar, 280, viewport * RIGHTBAR_MAX_RATIO)'),
  @('clampWidth(rightbarPreference, 300, viewport * RIGHTBAR_MAX_RATIO)', 'clampWidth(rightbarPreference, 280, viewport * RIGHTBAR_MAX_RATIO)'),
  @('d.layoutInfo.rightbar = clampWidth(px, 300, Math.max(300, d.layoutInfo.viewportWidth * RIGHTBAR_MAX_RATIO));', 'd.layoutInfo.rightbar = clampWidth(px, 280, Math.max(280, d.layoutInfo.viewportWidth * RIGHTBAR_MAX_RATIO));'),
  @('d.layoutInfo.rightbar ??= Math.max(300, Math.round(d.layoutInfo.viewportWidth * RIGHTBAR_DEFAULT_RATIO));', 'd.layoutInfo.rightbar ??= Math.max(280, Math.round(d.layoutInfo.viewportWidth * RIGHTBAR_DEFAULT_RATIO));')
)

foreach ($pair in $pairs) {
  $text = $text.Replace($pair[0], $pair[1])
}

if ($text -ceq $orig) {
  Write-Host 'already patched (.2 / 280) - nothing to do'
  exit 0
}

$backup = $target + '.orig-45'
if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $target -Destination $backup -Force }

[IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host 'patched: rightbar first-open 20%, min 280. Reload with Ctrl+F5.'
