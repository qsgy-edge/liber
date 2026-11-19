param(
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [Parameter(Mandatory=$true)][string]$JavaHome,
  [string]$AndroidSdk = "$env:LOCALAPPDATA/Android/Sdk",
  [string]$DebugKeystore = "$env:USERPROFILE/.android/debug.keystore",
  [switch]$Selected,
  [string]$FrozenSource = '',
  [string]$ReferenceApk = ''
)
# Builds the disposable REPLACE-JS-01 @js: replacement oracle APK (ticket #49).
# Its own package id and its own corpus asset: it never touches the
# replace_rule_oracle, result_field_oracle, nested_oracle, first_slice or
# html_oracle corpora.
$ErrorActionPreference = 'Stop'
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
  & $Program @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Program exited $LASTEXITCODE" }
}
if ($Selected) {
  if (!$FrozenSource -or !$ReferenceApk) { throw 'Selected build requires frozen source and reference APK' }
  $fixturePath = "$PSScriptRoot/fixtures-selected.json"
  $fixture = Get-Content -Raw -Encoding UTF8 $fixturePath | ConvertFrom-Json
  $legacy = Get-Content -Raw -Encoding UTF8 "$PSScriptRoot/fixtures.json" | ConvertFrom-Json
  if (($fixture.cases | ConvertTo-Json -Depth 100 -Compress) -cne ($legacy.cases | ConvertTo-Json -Depth 100 -Compress)) { throw 'Selected case inputs differ from original' }
  if ($fixture.fixtureId -ne 'REPLACE-JS-01' -or $fixture.corpusVersion -ne 1 -or
      $fixture.baselineCommit -ne 'a7d37f1707a70a459ad708f4fe79341d1e42d716' -or
      $fixture.target.package -ne 'com.legado.app.debug' -or
      $fixture.target.apkSha256 -ne '593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5') { throw 'Selected fixture identity differs' }
  $fixtureHash = (Get-FileHash $fixturePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($fixtureHash -ne 'f62c564192e0c400b1341c21e18354926589b450f178ebff841ff43434d1d7e4') { throw 'Selected corpus bytes differ' }
  if ((Get-FileHash $ReferenceApk -Algorithm SHA256).Hash.ToLowerInvariant() -ne $fixture.target.apkSha256) { throw 'Selected reference APK differs' }
  $head = & git -C $FrozenSource rev-parse HEAD
  if ($LASTEXITCODE -ne 0 -or $head -ne $fixture.baselineCommit) { throw 'Selected source HEAD differs' }
  $tree = & git -C $FrozenSource rev-parse 'HEAD^{tree}'
  if ($LASTEXITCODE -ne 0 -or $tree -ne '0f69dc7004012a969551ce271dc4e11051637d32') { throw 'Selected source tree differs' }
  $status = & git -C $FrozenSource status --porcelain=v1
  if ($LASTEXITCODE -ne 0 -or $status) { throw 'Selected source is not clean' }
  $referenceHashes = [ordered]@{}
  foreach ($source in $fixture.frozenSources) {
    $path = Join-Path $FrozenSource $source.path
    $sha1 = (Get-FileHash $path -Algorithm SHA1).Hash.ToLowerInvariant()
    $sha256 = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha1 -ne $source.sha1 -or $sha256 -ne $source.sha256) { throw "Selected reference source differs: $($source.path)" }
    $referenceHashes[$source.path] = $sha256
  }
  if (Test-Path $OutputDirectory) { throw 'Use a fresh output directory' }
  foreach ($directory in @('classes','dex','assets')) { New-Item -ItemType Directory -Path (Join-Path $OutputDirectory $directory) -Force | Out-Null }
  $tools = Join-Path $AndroidSdk 'build-tools/35.0.1'
  $androidJar = Join-Path $AndroidSdk 'platforms/android-35/android.jar'
  $repo = (Resolve-Path "$PSScriptRoot/../..").Path
  $inputs = @('tool/replace_js_oracle/ReplaceJsOracle.java','tool/replace_js_oracle/SelectedReplaceJsOracle.java','tool/replace_js_oracle/SelectedWebViewContainment.java','tool/replace_js_oracle/AndroidManifest-selected.xml','tool/replace_js_oracle/build.ps1','tool/replace_js_oracle/capture.py','tool/replace_js_oracle/selected_capture.py','tool/replace_js_oracle/compare.dart','tool/replace_rule_oracle/GuardedReaderApplication.java','tool/nested_oracle/StateSessionOracle.java','tool/nested_oracle/HostRuntimeInit.java','tool/nested_oracle/ShortcutStartupGuard.java')
  $sourceHashes = [ordered]@{}
  foreach ($name in $inputs) { $sourceHashes[$name] = (Get-FileHash (Join-Path $repo $name) -Algorithm SHA256).Hash.ToLowerInvariant() }
  [System.IO.File]::Copy($fixturePath, "$OutputDirectory/assets/fixtures-selected.json")
  $sources = @("$PSScriptRoot/ReplaceJsOracle.java", "$PSScriptRoot/SelectedReplaceJsOracle.java", "$PSScriptRoot/SelectedWebViewContainment.java", "$PSScriptRoot/../replace_rule_oracle/GuardedReaderApplication.java", "$PSScriptRoot/../nested_oracle/StateSessionOracle.java", "$PSScriptRoot/../nested_oracle/HostRuntimeInit.java", "$PSScriptRoot/../nested_oracle/ShortcutStartupGuard.java")
  Invoke-Checked "$JavaHome/bin/javac.exe" (@('-encoding','UTF-8','-source','8','-target','8','-cp',$androidJar,'-d',"$OutputDirectory/classes") + $sources)
  Invoke-Checked "$JavaHome/bin/jar.exe" @('cf',"$OutputDirectory/classes.jar",'-C',"$OutputDirectory/classes",'.')
  Invoke-Checked "$JavaHome/bin/java.exe" @('-cp',"$tools/lib/d8.jar",'com.android.tools.r8.D8','--lib',$androidJar,'--min-api','26','--output',"$OutputDirectory/dex","$OutputDirectory/classes.jar")
  $provenance = [ordered]@{baselineCommit=$fixture.baselineCommit; corpusAssetSha256=$fixtureHash; corpusSha256Lf=$fixtureHash; sourceHashes=$sourceHashes; referenceHashes=$referenceHashes; dexSha256=(Get-FileHash "$OutputDirectory/dex/classes.dex" -Algorithm SHA256).Hash.ToLowerInvariant()}
  [System.IO.File]::WriteAllText("$OutputDirectory/assets/provenance.json", ($provenance | ConvertTo-Json -Depth 10) + "`n", [System.Text.UTF8Encoding]::new($false))
  Copy-Item "$PSScriptRoot/AndroidManifest-selected.xml" "$OutputDirectory/AndroidManifest.xml"
  Invoke-Checked "$tools/aapt.exe" @('package','-f','-M',"$OutputDirectory/AndroidManifest.xml",'-I',$androidJar,'-A',"$OutputDirectory/assets",'-F',"$OutputDirectory/unsigned.apk")
  Invoke-Checked "$JavaHome/bin/jar.exe" @('uf',"$OutputDirectory/unsigned.apk",'-C',"$OutputDirectory/dex",'classes.dex')
  Invoke-Checked "$tools/zipalign.exe" @('-p','4',"$OutputDirectory/unsigned.apk","$OutputDirectory/aligned.apk")
  Invoke-Checked "$JavaHome/bin/java.exe" @('-jar',"$tools/lib/apksigner.jar",'sign','--ks',$DebugKeystore,'--ks-key-alias','androiddebugkey','--ks-pass','pass:android','--key-pass','pass:android','--out',"$OutputDirectory/replace-js-selected.apk","$OutputDirectory/aligned.apk")
  Get-FileHash "$OutputDirectory/replace-js-selected.apk" -Algorithm SHA256
  return
}
if (Test-Path $OutputDirectory) { throw 'Use a fresh output directory' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
foreach ($directory in @('classes','dex','assets')) {
  New-Item -ItemType Directory -Path (Join-Path $OutputDirectory $directory) | Out-Null
}
$tools = Join-Path $AndroidSdk 'build-tools/35.0.1'
$androidJar = Join-Path $AndroidSdk 'platforms/android-35/android.jar'
# The REPLACE-JS-01 corpus travels inside the harness: the oracle reads it from
# the device process and the golden records this file's hash as its corpus hash.
# The bytes are copied as they are on disk; a Windows checkout that rewrote them
# to CRLF has to be normalised back to the committed LF blob before the build,
# which is why both hashes are printed and compared.
[System.IO.File]::Copy("$PSScriptRoot/fixtures.json", "$OutputDirectory/assets/replace-js-fixtures.json", $true)
$sourceHash = (Get-FileHash "$PSScriptRoot/fixtures.json" -Algorithm SHA256).Hash.ToLowerInvariant()
$assetHash = (Get-FileHash "$OutputDirectory/assets/replace-js-fixtures.json" -Algorithm SHA256).Hash.ToLowerInvariant()
if ($sourceHash -ne $assetHash) { throw "the corpus asset does not match the corpus file" }
Write-Host "corpus asset sha256: $assetHash"
Invoke-Checked "$JavaHome/bin/javac.exe" @('-encoding','UTF-8','-source','8','-target','8','-cp',$androidJar,'-d',"$OutputDirectory/classes","$PSScriptRoot/ReplaceJsOracle.java")
Invoke-Checked "$JavaHome/bin/jar.exe" @('cf',"$OutputDirectory/classes.jar",'-C',"$OutputDirectory/classes",'.')
Invoke-Checked "$JavaHome/bin/java.exe" @('-cp',"$tools/lib/d8.jar",'com.android.tools.r8.D8','--lib',$androidJar,'--min-api','26','--output',"$OutputDirectory/dex","$OutputDirectory/classes.jar")
Invoke-Checked "$tools/aapt.exe" @('package','-f','-M',"$PSScriptRoot/AndroidManifest.xml",'-I',$androidJar,'-A',"$OutputDirectory/assets",'-F',"$OutputDirectory/unsigned.apk")
Invoke-Checked "$JavaHome/bin/jar.exe" @('uf',"$OutputDirectory/unsigned.apk",'-C',"$OutputDirectory/dex",'classes.dex')
Invoke-Checked "$tools/zipalign.exe" @('-p','4',"$OutputDirectory/unsigned.apk","$OutputDirectory/aligned.apk")
# Standard local Android debug key; its certificate must match the frozen APK.
Invoke-Checked "$JavaHome/bin/java.exe" @('-jar',"$tools/lib/apksigner.jar",'sign','--ks',$DebugKeystore,'--ks-key-alias','androiddebugkey','--ks-pass','pass:android','--key-pass','pass:android','--out',"$OutputDirectory/replace-js-oracle.apk","$OutputDirectory/aligned.apk")
Get-FileHash "$OutputDirectory/replace-js-oracle.apk" -Algorithm SHA256
