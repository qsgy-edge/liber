param(
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [Parameter(Mandatory=$true)][string]$JavaHome,
  [Parameter(Mandatory=$true)][string]$FrozenSource,
  [Parameter(Mandatory=$true)][string]$CorpusPath,
  [string]$AndroidSdk = "$env:LOCALAPPDATA/Android/Sdk",
  [string]$DebugKeystore = "$env:USERPROFILE/.android/debug.keystore"
)
$ErrorActionPreference = 'Stop'
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
  & $Program @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Program exited $LASTEXITCODE" }
}
function File-Hash([string]$Path) { return (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant() }
function Lf-Hash([string]$Path) {
  $bytes = [Text.Encoding]::UTF8.GetBytes(([IO.File]::ReadAllText($Path)).Replace("`r`n", "`n"))
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}
$corpus = (Resolve-Path $CorpusPath).Path
$scalar = (Resolve-Path "$PSScriptRoot/fixtures-selected.json").Path
$list = (Resolve-Path "$PSScriptRoot/list-fixtures-selected.json").Path
if ($corpus -ne $scalar -and $corpus -ne $list) { throw 'Unsupported selected corpus path' }
$fixture = Get-Content -Raw -Encoding UTF8 $corpus | ConvertFrom-Json
$expectedHash = if ($corpus -eq $scalar) { '5b5bca0204fba6e1da4abdb8fd64fb7b0017dab5bf560098ef4b97f36117c266' } else { '837228894594decc6dcf195cd565365ef461c760f02cbb6b02e32f0fa7f6eb01' }
if ((File-Hash $corpus) -ne $expectedHash -or $fixture.baselineCommit -ne 'a7d37f1707a70a459ad708f4fe79341d1e42d716' -or $fixture.target.package -ne 'com.legado.app.debug' -or $fixture.target.apkSha256 -ne '593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5') { throw 'Selected corpus identity differs' }
$head = & git -C $FrozenSource rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $head -ne $fixture.baselineCommit) { throw 'Selected reference HEAD differs' }
$status = & git -C $FrozenSource status --porcelain=v1
if ($LASTEXITCODE -ne 0 -or $status) { throw 'Selected reference checkout is not clean' }
foreach ($source in $fixture.frozenSources) {
  if ((File-Hash (Join-Path $FrozenSource $source.path)) -ne $source.sha256 -or (Get-FileHash -Algorithm SHA1 (Join-Path $FrozenSource $source.path)).Hash.ToLowerInvariant() -ne $source.sha1) { throw "Reference source differs: $($source.path)" }
}
if (Test-Path $OutputDirectory) { throw 'Use a fresh output directory' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
foreach ($directory in @('classes','dex','assets')) { New-Item -ItemType Directory -Path (Join-Path $OutputDirectory $directory) | Out-Null }
$repo = (Resolve-Path "$PSScriptRoot/../..").Path
$inputs = @('tool/html_oracle/SelectedHtmlOracle.java','tool/html_oracle/AndroidManifest-selected.xml','tool/html_oracle/build.ps1','tool/html_oracle/capture.py','tool/html_adapter_gate.dart','tool/replace_rule_oracle/GuardedReaderApplication.java','tool/nested_oracle/StateSessionOracle.java','tool/nested_oracle/HostRuntimeInit.java','tool/nested_oracle/ShortcutStartupGuard.java')
$sourceHashes = [ordered]@{}; $sourceHashesLf = [ordered]@{}
foreach ($name in $inputs) { $sourceHashes[$name] = File-Hash (Join-Path $repo $name); $sourceHashesLf[$name] = Lf-Hash (Join-Path $repo $name) }
$references = [ordered]@{}
foreach ($source in $fixture.frozenSources) { $references[$source.path] = File-Hash (Join-Path $FrozenSource $source.path) }
foreach ($name in @('app/src/main/java/io/legado/app/model/analyzeRule/SourceHtmlParser.kt','app/src/main/java/io/legado/app/model/SharedJsScope.kt','app/src/main/java/io/legado/app/help/coroutine/Coroutine.kt','app/src/main/java/io/legado/app/App.kt')) { $references[$name] = File-Hash (Join-Path $FrozenSource $name) }
Copy-Item $corpus "$OutputDirectory/assets/html-fixtures.json"
Copy-Item "$PSScriptRoot/AndroidManifest-selected.xml" "$OutputDirectory/AndroidManifest.xml"
$tools = Join-Path $AndroidSdk 'build-tools/35.0.1'
$androidJar = Join-Path $AndroidSdk 'platforms/android-35/android.jar'
$javaSources = @("$PSScriptRoot/SelectedHtmlOracle.java", "$PSScriptRoot/../replace_rule_oracle/GuardedReaderApplication.java", "$PSScriptRoot/../nested_oracle/StateSessionOracle.java", "$PSScriptRoot/../nested_oracle/HostRuntimeInit.java", "$PSScriptRoot/../nested_oracle/ShortcutStartupGuard.java")
Invoke-Checked "$JavaHome/bin/javac.exe" (@('-encoding','UTF-8','-source','8','-target','8','-cp',$androidJar,'-d',"$OutputDirectory/classes") + $javaSources)
Invoke-Checked "$JavaHome/bin/jar.exe" @('cf',"$OutputDirectory/classes.jar",'-C',"$OutputDirectory/classes",'.')
Invoke-Checked "$JavaHome/bin/java.exe" @('-cp',"$tools/lib/d8.jar",'com.android.tools.r8.D8','--lib',$androidJar,'--min-api','26','--output',"$OutputDirectory/dex","$OutputDirectory/classes.jar")
$provenance = [ordered]@{ baselineCommit=$fixture.baselineCommit; corpusAssetSha256=(File-Hash $corpus); corpusSha256Lf=(Lf-Hash $corpus); sourceHashes=$sourceHashes; sourceHashesLf=$sourceHashesLf; referenceHashes=$references; dexSha256=(File-Hash "$OutputDirectory/dex/classes.dex") }
$provenance | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 "$OutputDirectory/assets/provenance.json"
Invoke-Checked "$tools/aapt.exe" @('package','-f','-M',"$OutputDirectory/AndroidManifest.xml",'-I',$androidJar,'-A',"$OutputDirectory/assets",'-F',"$OutputDirectory/unsigned.apk")
Invoke-Checked "$JavaHome/bin/jar.exe" @('uf',"$OutputDirectory/unsigned.apk",'-C',"$OutputDirectory/dex",'classes.dex')
Invoke-Checked "$tools/zipalign.exe" @('-p','4',"$OutputDirectory/unsigned.apk","$OutputDirectory/aligned.apk")
Invoke-Checked "$JavaHome/bin/java.exe" @('-jar',"$tools/lib/apksigner.jar",'sign','--ks',$DebugKeystore,'--ks-key-alias','androiddebugkey','--ks-pass','pass:android','--key-pass','pass:android','--out',"$OutputDirectory/html-oracle.apk","$OutputDirectory/aligned.apk")
Write-Output (File-Hash "$OutputDirectory/html-oracle.apk")
