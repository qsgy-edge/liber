param(
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [Parameter(Mandatory=$true)][string]$JavaHome,
  [string]$AndroidSdk = "$env:LOCALAPPDATA/Android/Sdk",
  [string]$DebugKeystore = "$env:USERPROFILE/.android/debug.keystore",
  [string]$CorpusPath = '',
  [string]$FrozenSource = ''
)
$ErrorActionPreference = 'Stop'
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
  & $Program @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Program exited $LASTEXITCODE" }
}
function Lf-Hash([string]$Path) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes(([System.IO.File]::ReadAllText($Path)).Replace("`r`n", "`n"))
  $digest = [System.Security.Cryptography.SHA256]::Create()
  try { return [BitConverter]::ToString($digest.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() }
  finally { $digest.Dispose() }
}
function File-Hash([string]$Path, [string]$Algorithm) {
  $digest = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
  try {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return [BitConverter]::ToString($digest.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()
  } finally { $digest.Dispose() }
}
if (!$CorpusPath) { $CorpusPath = "$PSScriptRoot/fixtures.json" }
$corpus = (Resolve-Path $CorpusPath).Path
$legacy = (Resolve-Path "$PSScriptRoot/fixtures.json").Path
$selected = (Resolve-Path "$PSScriptRoot/fixtures-selected.json").Path
if ($corpus -ne $legacy -and $corpus -ne $selected) { throw 'Unsupported corpus path' }
$isSelected = $corpus -eq $selected
$fixture = Get-Content -Raw -Encoding UTF8 $corpus | ConvertFrom-Json
if ($fixture.fixtureId -ne 'REPLACE-17' -or
    ($isSelected -and ($fixture.corpusVersion -ne 2 -or $fixture.baselineCommit -ne 'a7d37f1707a70a459ad708f4fe79341d1e42d716' -or $fixture.target.package -ne 'com.legado.app.debug' -or $fixture.target.apkSha256 -ne '593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5')) -or
    (!$isSelected -and ($fixture.corpusVersion -ne 1 -or $fixture.baselineCommit -ne '14dd24945b2914ce2708b8abaa4ee67ceef892af'))) { throw 'Unsupported corpus identity' }
if ($isSelected) {
  if (!$FrozenSource) { throw 'Selected build requires the fixed reference source checkout' }
  $head = & git -C $FrozenSource rev-parse HEAD
  if ($LASTEXITCODE -ne 0 -or $head -ne 'a7d37f1707a70a459ad708f4fe79341d1e42d716') { throw 'Selected reference HEAD differs' }
  $status = & git -C $FrozenSource status --porcelain=v1
  if ($LASTEXITCODE -ne 0 -or $status) { throw 'Selected reference checkout is not clean' }
  $lfBytes = [System.Text.Encoding]::UTF8.GetBytes(([System.IO.File]::ReadAllText($corpus)).Replace("`r`n", "`n"))
  $lfHash = [BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($lfBytes)).Replace('-','').ToLowerInvariant()
  if ($lfHash -ne '6d73f51c2a03a93b728075a2d2acb4b8a4c8e31f454961b6a4eb7c3e318a1548') { throw 'Selected corpus bytes differ' }
  foreach ($source in $fixture.frozenSources) {
    if ((File-Hash (Join-Path $FrozenSource $source.path) 'SHA1') -ne $source.sha1 -or (File-Hash (Join-Path $FrozenSource $source.path) 'SHA256') -ne $source.sha256) { throw "Selected reference source differs: $($source.path)" }
  }
}
if (Test-Path $OutputDirectory) { throw 'Use a fresh output directory' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
foreach ($directory in @('classes','dex','assets')) {
  New-Item -ItemType Directory -Path (Join-Path $OutputDirectory $directory) | Out-Null
}
$tools = Join-Path $AndroidSdk 'build-tools/35.0.1'
$androidJar = Join-Path $AndroidSdk 'platforms/android-35/android.jar'
$javaSources = @("$PSScriptRoot/ReaderOracle.java")
$manifest = "$PSScriptRoot/AndroidManifest.xml"
if ($isSelected) {
  $manifest = "$OutputDirectory/AndroidManifest.xml"
  Copy-Item "$PSScriptRoot/AndroidManifest-selected.xml" $manifest
  $javaSources += @("$PSScriptRoot/SelectedReaderOracle.java", "$PSScriptRoot/GuardedReaderApplication.java", "$PSScriptRoot/../nested_oracle/StateSessionOracle.java", "$PSScriptRoot/../nested_oracle/HostRuntimeInit.java", "$PSScriptRoot/../nested_oracle/ShortcutStartupGuard.java")
}
Copy-Item $corpus "$OutputDirectory/assets/$(Split-Path $corpus -Leaf)"
if ($isSelected) {
  $repo = (Resolve-Path "$PSScriptRoot/../..").Path
  $inputs = @('tool/replace_rule_oracle/ReaderOracle.java','tool/replace_rule_oracle/SelectedReaderOracle.java','tool/replace_rule_oracle/GuardedReaderApplication.java','tool/replace_rule_oracle/AndroidManifest-selected.xml','tool/replace_rule_oracle/build.ps1','tool/replace_rule_oracle/capture.py','tool/replace_rule_oracle/compare.dart','tool/nested_oracle/StateSessionOracle.java','tool/nested_oracle/HostRuntimeInit.java','tool/nested_oracle/ShortcutStartupGuard.java')
  $sourceHashes = [ordered]@{}
  $sourceHashesLf = [ordered]@{}
  foreach ($name in $inputs) {
    $sourceHashes[$name] = File-Hash (Join-Path $repo $name) 'SHA256'
    $sourceHashesLf[$name] = Lf-Hash (Join-Path $repo $name)
  }
  $referenceHashes = [ordered]@{}
  foreach ($source in $fixture.frozenSources) { $referenceHashes[$source.path] = File-Hash (Join-Path $FrozenSource $source.path) 'SHA256' }
  $provenance = [ordered]@{ baselineCommit=$fixture.baselineCommit; corpusAssetSha256=(File-Hash $corpus 'SHA256'); corpusSha256Lf=$lfHash; sourceHashes=$sourceHashes; sourceHashesLf=$sourceHashesLf; referenceHashes=$referenceHashes }
}
Invoke-Checked "$JavaHome/bin/javac.exe" (@('-encoding','UTF-8','-source','8','-target','8','-cp',$androidJar,'-d',"$OutputDirectory/classes") + $javaSources)
Invoke-Checked "$JavaHome/bin/jar.exe" @('cf',"$OutputDirectory/classes.jar",'-C',"$OutputDirectory/classes",'.')
Invoke-Checked "$JavaHome/bin/java.exe" @('-cp',"$tools/lib/d8.jar",'com.android.tools.r8.D8','--lib',$androidJar,'--min-api','26','--output',"$OutputDirectory/dex","$OutputDirectory/classes.jar")
if ($isSelected) {
  $provenance['dexSha256'] = File-Hash "$OutputDirectory/dex/classes.dex" 'SHA256'
  $provenance | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 "$OutputDirectory/assets/provenance.json"
}
Invoke-Checked "$tools/aapt.exe" @('package','-f','-M',$manifest,'-I',$androidJar,'-A',"$OutputDirectory/assets",'-F',"$OutputDirectory/unsigned.apk")
Invoke-Checked "$JavaHome/bin/jar.exe" @('uf',"$OutputDirectory/unsigned.apk",'-C',"$OutputDirectory/dex",'classes.dex')
Invoke-Checked "$tools/zipalign.exe" @('-p','4',"$OutputDirectory/unsigned.apk","$OutputDirectory/aligned.apk")
# Standard local Android debug key; its certificate must match the frozen APK.
Invoke-Checked "$JavaHome/bin/java.exe" @('-jar',"$tools/lib/apksigner.jar",'sign','--ks',$DebugKeystore,'--ks-key-alias','androiddebugkey','--ks-pass','pass:android','--key-pass','pass:android','--out',"$OutputDirectory/reader-oracle.apk","$OutputDirectory/aligned.apk")
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
  $bytes = [System.IO.File]::ReadAllBytes("$OutputDirectory/reader-oracle.apk")
  [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()
} finally { $sha.Dispose() }
