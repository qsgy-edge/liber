param(
  [string]$QuickJsDirectory='C:/Users/17945/.cargo/git/checkouts/rquickjs-908a74ff20076c6a/04e2734/sys/quickjs',
  [string]$OutputDirectory="$env:TEMP/liber-quickjs-stack-prototype",
  [string]$Compiler='D:/Tool/mingw64/bin/gcc.exe',
  [string]$EvidenceDirectory="$PSScriptRoot/evidence"
)
$ErrorActionPreference='Stop'
& "$PSScriptRoot/build.ps1" -QuickJsDirectory $QuickJsDirectory -OutputDirectory $OutputDirectory -Compiler $Compiler
if($LASTEXITCODE -ne 0){throw 'Build failed'}
$exe=Join-Path $OutputDirectory prototype.exe
& python "$PSScriptRoot/verify.py" $exe --output "$EvidenceDirectory/windows.json"
if($LASTEXITCODE -ne 0){throw 'Positive prototype gate failed'}
& python "$PSScriptRoot/verify.py" $exe --without-frame-restore --output "$EvidenceDirectory/windows-no-frame-restore.json"
if($LASTEXITCODE -ne 1){throw 'Negative control did not fail as expected'}
$negative=Get-Content "$EvidenceDirectory/windows-no-frame-restore.json" -Raw | ConvertFrom-Json
$failures=@($negative.checks.PSObject.Properties | Where-Object {$_.Value -eq $false} | ForEach-Object Name)
if(($failures|Sort-Object) -join ',' -ne 'resumedNativeBacktraceA,resumedNativeBacktraceB'){throw 'Unexpected negative-control failures'}
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$inputFiles=@(Get-ChildItem $QuickJsDirectory -File | Where-Object Extension -in '.h','.c')
$localFiles=@('prototype.c','build.ps1','verify.py','run.ps1')
$manifest=[ordered]@{
  status='pass';scope='Windows native feasibility only; product integration not-run';recordedAt=(Get-Date -Format o)
  repositoryHead=(& git -C $repo rev-parse HEAD);repositoryBranch=(& git -C $repo branch --show-current);uncommitted=$true
  quickJsDirectory=$QuickJsDirectory;quickJsRevision=(& git -C $QuickJsDirectory rev-parse HEAD)
  compiler=(& $Compiler --version | Select-Object -First 1)
  executable=$exe;executableSha256=(Get-FileHash $exe).Hash.ToLowerInvariant()
  sourceHashes=@($localFiles | ForEach-Object {@{path=$_;sha256=(Get-FileHash (Join-Path $PSScriptRoot $_)).Hash.ToLowerInvariant()}})
  engineInputHashes=@($inputFiles | ForEach-Object {@{path=$_.Name;sha256=(Get-FileHash $_.FullName).Hash.ToLowerInvariant()}})
  resultHashes=@('windows.json','windows-no-frame-restore.json','windows.events.jsonl','windows-no-frame-restore.events.jsonl' | ForEach-Object {@{path=$_;sha256=(Get-FileHash (Join-Path $EvidenceDirectory $_)).Hash.ToLowerInvariant()}})
  productModified=$false;nativeQuickJsSourcesModified=$false
  caveats=@('Controller chooses ready task; no production scheduler','Windows fibers and MinGW C, not Rust/FRB suspended frames','Seven engine observations compared; three LRU observations absent','Other four platforms not-run','No production or full compatibility verdict')
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content "$EvidenceDirectory/manifest.json"
$global:LASTEXITCODE=0
Write-Output 'Prototype gate passed; negative control failed only its two intended backtrace checks.'
