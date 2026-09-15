param(
  [string]$QuickJsDirectory="$PSScriptRoot/../../packages/fjs/libfjs/vendor/rquickjs-sys/quickjs",
  [string]$OutputDirectory="$env:TEMP/liber-runtime-limits-prototype",
  [string]$Compiler='D:/Tool/mingw64/bin/gcc.exe'
)
$ErrorActionPreference='Stop'
$QuickJsDirectory=(Resolve-Path $QuickJsDirectory).Path
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
& $Compiler '-std=gnu11' '-D_GNU_SOURCE' '-DWIN32_LEAN_AND_MEAN' '-O1' '-g' '-I' $QuickJsDirectory `
  "$PSScriptRoot/native_probe.c" "$QuickJsDirectory/quickjs.c" "$QuickJsDirectory/libregexp.c" `
  "$QuickJsDirectory/libunicode.c" "$QuickJsDirectory/dtoa.c" `
  '-lws2_32' '-lm' '-o' "$OutputDirectory/native_probe.exe"
if($LASTEXITCODE -ne 0){throw "Compiler failed: $LASTEXITCODE"}
Write-Output "built: $OutputDirectory/native_probe.exe"
