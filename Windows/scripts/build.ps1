# Builds Cra for Windows into Windows/build/Cra: Cra.exe, CraHelper.exe, CEF's DLLs and
# resources, and the Swift and WinRT runtime DLLs SwiftPM produced.
param([ValidateSet('debug', 'release')] [string]$Configuration = 'release')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'fetch-deps.ps1')

swift build --package-path $root -c $Configuration
if ($LASTEXITCODE) { throw 'swift build failed' }
$bin = (swift build --package-path $root -c $Configuration --show-bin-path).Trim()

$out = Join-Path $root 'build\Cra'
Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item (Join-Path $bin '*.exe'), (Join-Path $bin '*.dll') $out
Get-ChildItem $bin -Directory -Filter '*.resources' | Copy-Item -Destination $out -Recurse
$cef = Join-Path $root 'vendor\cef'
Copy-Item (Join-Path $cef 'Release\*') $out -Recurse -Exclude '*.lib'
Copy-Item (Join-Path $cef 'Resources\*') $out -Recurse
Write-Host "Built $out"
