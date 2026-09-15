param(
  [string]$QuickJsDirectory='C:/Users/17945/.cargo/git/checkouts/rquickjs-908a74ff20076c6a/04e2734/sys/quickjs',
  [string]$OutputDirectory="$env:TEMP/liber-quickjs-stack-prototype",
  [string]$Compiler='D:/Tool/mingw64/bin/gcc.exe'
)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
& $Compiler '-std=gnu11' '-D_GNU_SOURCE' '-DWIN32_LEAN_AND_MEAN' '-O1' '-g' '-I' $QuickJsDirectory "$PSScriptRoot/prototype.c" "$QuickJsDirectory/libregexp.c" "$QuickJsDirectory/libunicode.c" "$QuickJsDirectory/dtoa.c" '-lws2_32' '-lm' '-o' "$OutputDirectory/prototype.exe"
if($LASTEXITCODE -ne 0){throw "Compiler failed: $LASTEXITCODE"}
Get-FileHash "$OutputDirectory/prototype.exe" -Algorithm SHA256
