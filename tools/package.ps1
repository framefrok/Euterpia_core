# tools/package.ps1
#
# Сборка архива поставки EUTERPIA для Windows (issue #229).
#
# Что делает:
#   * проверяет, что `euterpia --version` совпадает с `euterpia_version.nim`;
#   * раскладывает exe, документацию, install.ps1/uninstall.ps1;
#   * `install.ps1` прописывает ассоциации файлов проекта (`*.eproj`, `*.eut`)
#     в HKCU (без админских прав) и добавляет каталог в PATH пользователя;
#   * упаковывает всё в zip и считает SHA256.
#
# Использование:
#   powershell -ExecutionPolicy Bypass -File tools/package.ps1 -Cli build/euterpia.exe

param(
  [string]$Cli = "build/euterpia.exe",
  [string]$OutDir = "build/dist"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path $Cli)) { throw "нет бинаря: $Cli" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$versionFile = Get-Content (Join-Path $Root "euterpia_version.nim") -Raw
$match = [regex]::Match($versionFile, '\d+\.\d+\.\d+')
if (-not $match.Success) { throw "не удалось прочитать версию" }
$Version = $match.Value

$cliVersion = & $Cli --version
if ($cliVersion -ne "euterpia $Version") {
  throw "версия бинаря «$cliVersion» не совпала с $Version (euterpia_version.nim)"
}

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x86_64" }
$Name = "euterpia-$Version-windows-$arch"
$Stage = Join-Path $OutDir $Name
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Force -Path (Join-Path $Stage "bin") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Stage "docs") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Stage "share/man/man1") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Stage "completions") | Out-Null
foreach ($sub in @("templates", "setlists", "params")) {
  New-Item -ItemType Directory -Force -Path (Join-Path $Stage "share/euterpia/presets/$sub") | Out-Null
}

Copy-Item $Cli (Join-Path $Stage "bin/euterpia.exe")

# File-association helper: a click on a project opens a terminal in its
# directory (#348). `%~dp1` is the drive+path of the first argument.
$openCmd = @'
@echo off
setlocal
if "%~1"=="" (
  echo usage: euterpia-open ^<project.eproj^|project.eut^> 1>&2
  exit /b 1
)
cd /d "%~dp1"
"%~dp0euterpia.exe" open "%~nx1"
'@
Set-Content -Path (Join-Path $Stage "bin/euterpia-open.cmd") -Value $openCmd -Encoding ASCII

Set-Content -Path (Join-Path $Stage "VERSION") -Value $Version -Encoding ASCII
foreach ($doc in @("README.md", "CHANGELOG.md", "MANIFEST.md")) {
  $src = Join-Path $Root $doc
  if (Test-Path $src) { Copy-Item $src (Join-Path $Stage "docs/$doc") }
}
foreach ($doc in @("cli.md", "clients.md", "embedding.md", "delivery.md", "quickstart.md", "cli-policy.md")) {
  $src = Join-Path $Root "docs/$doc"
  if (Test-Path $src) { Copy-Item $src (Join-Path $Stage "docs/$doc") }
}
$presets = Join-Path $Root "presets"
if (Test-Path $presets) {
  foreach ($sub in @("templates", "setlists", "params")) {
    Copy-Item -Recurse -Force (Join-Path $presets "$sub/*") (Join-Path $Stage "share/euterpia/presets/$sub")
  }
}

# Manual and completion are generated from the same specification as help
# and JSON schema (#349). An installed binary must not describe a different
# command surface than the shipped one.
& $Cli __man --write (Join-Path $Stage "share/man/man1") | Out-Null
& $Cli completion bash | Set-Content -Path (Join-Path $Stage "completions/euterpia.bash") -Encoding ASCII
& $Cli completion zsh | Set-Content -Path (Join-Path $Stage "completions/_euterpia") -Encoding ASCII
& $Cli completion fish | Set-Content -Path (Join-Path $Stage "completions/euterpia.fish") -Encoding ASCII
& $Cli completion powershell | Set-Content -Path (Join-Path $Stage "completions/euterpia.ps1") -Encoding UTF8

$install = @'
# Установка EUTERPIA из архива (issue #229).
# Без админских прав: файлы — в %LOCALAPPDATA%\EUTERPIA, ассоциации — в HKCU.
$ErrorActionPreference = "Stop"
$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
$DEST = Join-Path $env:LOCALAPPDATA "EUTERPIA"
New-Item -ItemType Directory -Force -Path $DEST | Out-Null
Copy-Item -Recurse -Force (Join-Path $HERE "bin") $DEST
Copy-Item -Recurse -Force (Join-Path $HERE "docs") $DEST
Copy-Item -Recurse -Force (Join-Path $HERE "share") $DEST
Copy-Item -Recurse -Force (Join-Path $HERE "completions") $DEST
$exe = Join-Path $DEST "bin\euterpia.exe"
$open = Join-Path $DEST "bin\euterpia-open.cmd"

# Association: HKCU\Software\Classes\Euterpia.Project
$progId = "Euterpia.Project"
$classes = "HKCU:\Software\Classes"
New-Item -Force -Path "$classes\$progId\shell\open\command" | Out-Null
Set-ItemProperty -Path "$classes\$progId" -Name "(Default)" -Value "EUTERPIA project"
# The helper changes to the project directory before opening it (#348).
Set-ItemProperty -Path "$classes\$progId\shell\open\command" -Name "(Default)" `
  -Value ('"' + $open + '" "%1"')
foreach ($ext in @(".eproj", ".eut")) {
  New-Item -Force -Path "$classes\$ext" | Out-Null
  Set-ItemProperty -Path "$classes\$ext" -Name "(Default)" -Value $progId
}
# PATH пользователя: без него `euterpia` не находится из терминала.
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$DEST\bin*") {
  [Environment]::SetEnvironmentVariable("Path", "$userPath;$DEST\bin", "User")
}
Write-Host "EUTERPIA установлена: $exe"
Write-Host "Откройте новый терминал (PATH обновлён) и проверьте: euterpia --version"
Write-Host "Автодополнение PowerShell: . $DEST\completions\euterpia.ps1"
Write-Host "Руководство и man-страницы: $DEST\share\man\man1"
'@
Set-Content -Path (Join-Path $Stage "install.ps1") -Value $install -Encoding UTF8

$uninstall = @'
# Удаление EUTERPIA (issue #229).
$ErrorActionPreference = "Stop"
$DEST = Join-Path $env:LOCALAPPDATA "EUTERPIA"
$classes = "HKCU:\Software\Classes"
foreach ($key in @("Euterpia.Project", ".eproj", ".eut")) {
  if (Test-Path "$classes\$key") { Remove-Item -Recurse -Force "$classes\$key" }
}
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$newPath = ($userPath.Split(";") | Where-Object { $_ -and ($_ -notlike "*$DEST\bin*") }) -join ";"
[Environment]::SetEnvironmentVariable("Path", $newPath, "User")
if (Test-Path $DEST) { Remove-Item -Recurse -Force $DEST }
Write-Host "EUTERPIA удалена"
'@
Set-Content -Path (Join-Path $Stage "uninstall.ps1") -Value $uninstall -Encoding UTF8

$zip = Join-Path $OutDir "$Name.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $Stage -DestinationPath $zip
$hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
Set-Content -Path "$zip.sha256" -Value "$hash  $Name.zip" -Encoding ASCII

Write-Host "пакет: $zip"
Write-Host "sha256: $hash"
Write-Host $Name
