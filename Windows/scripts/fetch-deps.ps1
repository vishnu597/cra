# Fetches what the Windows build needs into Windows/vendor. Safe to re-run; skips what is
# already there.
#   vendor/cef      CEF's Windows binary distribution (Spotify's stock build at the version
#                   scripts/fetch-cef.sh pins for macOS), with libcef_dll_wrapper built /MD
#   vendor/winrt/*  The Browser Company's Swift/WinRT projections at pinned commits
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$vendor = Join-Path $root 'vendor'
New-Item -ItemType Directory -Force $vendor | Out-Null

# Same Chromium as the macOS app.
$pin = Select-String -Path (Join-Path $root '..\scripts\fetch-cef.sh') -Pattern 'CEF_VERSION="\$\{CEF_VERSION:-(.+)\}"'
$cefVersion = if ($env:CEF_VERSION) { $env:CEF_VERSION } else { $pin.Matches[0].Groups[1].Value }
$name = "cef_binary_${cefVersion}_windows64_minimal"
$cef = Join-Path $vendor 'cef'
if (-not (Test-Path (Join-Path $cef 'Release\libcef.dll'))) {
    $url = "https://cef-builds.spotifycdn.com/$([uri]::EscapeDataString($name)).tar.bz2"
    Write-Host "Downloading $name"
    $download = Join-Path $vendor 'cef-download'
    Remove-Item -Recurse -Force $download, $cef -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $download | Out-Null
    curl.exe -fL --retry 3 --no-progress-meter -o (Join-Path $download 'cef.tar.bz2') $url
    if ($LASTEXITCODE) { throw "CEF download failed: $url" }
    Write-Host "$(Get-Date -Format T) Downloaded, extracting"
    # 7-Zip when it is there (CI runners have it): tar.exe stalled on this archive in CI.
    Push-Location $download
    try {
        $sevenZip = Get-Command 7z -ErrorAction SilentlyContinue
        if ($sevenZip) {
            & $sevenZip.Source x -y -bso0 -bsp0 cef.tar.bz2
            if ($LASTEXITCODE) { throw 'CEF extract (bz2) failed' }
            & $sevenZip.Source x -y -bso0 -bsp0 cef.tar
            if ($LASTEXITCODE) { throw 'CEF extract (tar) failed' }
        } else {
            # Windows' own bsdtar, by relative path: a GNU tar earlier on PATH (Git's) reads
            # the "D:" in an absolute path as a remote host and waits on it forever.
            & (Join-Path $env:SystemRoot 'System32\tar.exe') -xjf cef.tar.bz2
            if ($LASTEXITCODE) { throw 'CEF extract failed' }
        }
    } finally {
        Pop-Location
    }
    Write-Host "$(Get-Date -Format T) Extracted"
    Move-Item (Join-Path $download $name) $cef
    Remove-Item -Recurse -Force $download
}
if (-not (Test-Path (Join-Path $cef 'build\libcef_dll_wrapper\Release\libcef_dll_wrapper.lib'))) {
    Write-Host "$(Get-Date -Format T) Building libcef_dll_wrapper"
    cmake -S $cef -B (Join-Path $cef 'build') -G 'Visual Studio 17 2022' -A x64 `
        -DCEF_RUNTIME_LIBRARY_FLAG=/MD -DUSE_SANDBOX=OFF
    if ($LASTEXITCODE) { throw 'CEF configure failed' }
    cmake --build (Join-Path $cef 'build') --config Release --target libcef_dll_wrapper
    if ($LASTEXITCODE) { throw 'libcef_dll_wrapper build failed' }
}

# Their manifests refer to each other as ../swift-*, so they are cloned side by side.
$winrt = @{
    'swift-cwinrt'            = 'eb46cdb66f770a1e006f9fcfebbf9e99a0fba811'
    'swift-uwp'               = 'd1a96986570189f8aa9ed089e9c4dab3c96e688c'
    'swift-windowsfoundation' = '1efad430c4920d80d063bfaa526dd011d8ee8379'
    'swift-windowsappsdk'     = '317527def617c5b7b3153380a85390bf7d3ec5b2'
    'swift-winui'             = '17c77ebaf8585039ab2f25d8aaf19f6e0aead93b'
}
$winrtDir = Join-Path $vendor 'winrt'
New-Item -ItemType Directory -Force $winrtDir | Out-Null
Write-Host "$(Get-Date -Format T) Fetching the Swift/WinRT projections"
foreach ($repo in $winrt.Keys) {
    $dir = Join-Path $winrtDir $repo
    if (-not (Test-Path (Join-Path $dir '.git'))) {
        git init -q $dir
        git -C $dir remote add origin "https://github.com/thebrowsercompany/$repo"
    }
    if ((git -C $dir rev-parse HEAD 2>$null) -ne $winrt[$repo]) {
        git -C $dir fetch -q --depth 1 origin $winrt[$repo]
        git -C $dir checkout -q --force FETCH_HEAD
        if ($LASTEXITCODE) { throw "Could not check out $repo" }
    }
}
# swift-windowsappsdk at that commit ships an ARM64 Microsoft.WindowsAppRuntime.Bootstrap.dll,
# which an x64 Cra.exe cannot load (it traps before opening a window). Replace it with the x64
# one from the Windows App SDK NuGet package of the same version.
$wasdkVersion = '1.7.250909003'
$bootstrap = Join-Path $winrtDir 'swift-windowsappsdk\Sources\CWinAppSDK\nuget\bin\Microsoft.WindowsAppRuntime.Bootstrap.dll'
function Get-PEMachine([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $pe = [BitConverter]::ToInt32($bytes, 0x3c)
    [BitConverter]::ToUInt16($bytes, $pe + 4)
}
if ((Get-PEMachine $bootstrap) -ne 0x8664) {
    Write-Host "$(Get-Date -Format T) Replacing the ARM64 bootstrap DLL with the x64 one from Windows App SDK $wasdkVersion"
    $nuget = Join-Path $vendor 'wasdk-download'
    Remove-Item -Recurse -Force $nuget -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $nuget | Out-Null
    curl.exe -fL --retry 3 --no-progress-meter -o (Join-Path $nuget 'wasdk.zip') "https://www.nuget.org/api/v2/package/Microsoft.WindowsAppSDK/$wasdkVersion"
    if ($LASTEXITCODE) { throw 'Windows App SDK download failed' }
    Expand-Archive (Join-Path $nuget 'wasdk.zip') (Join-Path $nuget 'pkg')
    $x64 = Get-ChildItem (Join-Path $nuget 'pkg\runtimes') -Recurse -Filter 'Microsoft.WindowsAppRuntime.Bootstrap.dll' |
        Where-Object { $_.Directory.Parent.Name -match '^win(10)?-x64$' } | Select-Object -First 1
    if (-not $x64) { throw 'No x64 Microsoft.WindowsAppRuntime.Bootstrap.dll in the Windows App SDK package' }
    Copy-Item $x64.FullName $bootstrap -Force
    Remove-Item -Recurse -Force $nuget
    if ((Get-PEMachine $bootstrap) -ne 0x8664) { throw 'Bootstrap DLL is still not x64' }
}

Write-Host 'Windows dependencies ready: Windows/vendor'
