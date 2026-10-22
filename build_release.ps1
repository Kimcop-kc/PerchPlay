# PerchPlay Release Build Script
# 用法: .\build_release.ps1
# 产物: build\release\com.perchplay.player-v1.0.97.apk

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$env:FLUTTER_ROOT = "D:\dev\flutter"
$env:PATH = "$env:FLUTTER_ROOT\bin;$env:PATH"
$env:JAVA_HOME = "D:\dev\jdk-17"

Write-Host "=== 1/3 flutter build apk --release ==="
flutter build apk --release
if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }

# 从 pubspec.yaml 提取版本号
$pubspec = Get-Content pubspec.yaml -Raw
$m = [regex]::Match($pubspec, 'version:\s*(\S+)')
$version = if ($m.Success) { $m.Groups[1].Value } else { '0.0.0' }

# 从 build.gradle 提取包名
$gradle = Get-Content android\app\build.gradle -Raw
$m2 = [regex]::Match($gradle, 'applicationId\s+"([^"]+)"')
$appId = if ($m2.Success) { $m2.Groups[1].Value } else { 'com.perchplay.player' }

$outDir = "build\release"
$src = "build\app\outputs\flutter-apk\app-release.apk"
$dst = "$outDir\$appId-v$version.apk"

Write-Host "=== 2/3 Rename: $src → $dst ==="
New-Item -ItemType Directory -Force $outDir | Out-Null
Copy-Item -Force $src $dst

Write-Host "=== 3/3 Done: $dst ($((Get-Item $dst).Length / 1MB -as [int])MB) ==="