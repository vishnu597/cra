# Builds Cra for Windows into Windows/build/Cra: Cra.exe, CraHelper.exe, the DLLs SwiftPM
# built, the Swift runtime, and CEF's DLLs and resources. Then checks every DLL is there.
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
# The Swift runtime (swiftCore, Foundation, Dispatch, ...) is installed with the toolchain, not
# built by SwiftPM, so it is copied from wherever the toolchain put it on PATH.
$runtime = $env:Path -split ';' | Where-Object { $_ -and (Test-Path (Join-Path $_ 'swiftCore.dll')) } | Select-Object -First 1
if (-not $runtime) { throw 'Swift runtime (swiftCore.dll) not found on PATH' }
Copy-Item (Join-Path $runtime '*.dll') $out
$cef = Join-Path $root 'vendor\cef'
Copy-Item (Join-Path $cef 'Release\*') $out -Recurse -Exclude '*.lib'
Copy-Item (Join-Path $cef 'Resources\*') $out -Recurse
# Every DLL the executables load must now be in $out: start each with only System32 on PATH.
# 0xC0000135 (STATUS_DLL_NOT_FOUND) means one is missing. Cra.exe opens a window, so it is
# stopped after a few seconds if it is still running.
$cleanPath = Join-Path $env:SystemRoot 'System32'
$savedPath = $env:Path
try {
    $env:Path = $cleanPath
    foreach ($exe in 'CraHelper.exe', 'Cra.exe') {
        $p = Start-Process (Join-Path $out $exe) -WorkingDirectory $out -PassThru
        if (-not $p.WaitForExit(5000)) { $p.Kill(); continue }
        if ($p.ExitCode -eq -1073741515) { throw "$exe could not load a DLL it needs (STATUS_DLL_NOT_FOUND)" }
    }
} finally {
    $env:Path = $savedPath
}
Write-Host "Built $out"
