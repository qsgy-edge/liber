param(
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [Parameter(Mandatory=$true)][string]$JavaHome,
  [string]$AndroidSdk = "$env:LOCALAPPDATA/Android/Sdk",
  [string]$DebugKeystore = "$env:USERPROFILE/.android/debug.keystore",
  # Optional local selection of the FIELDS corpus only. The default remains
  # FIELDS-01 under the harness' fixed field-fixtures.json asset name.
  [string]$CorpusPath = "$PSScriptRoot/fixtures.json"
)
# Builds the disposable FIELDS result-field oracle APK (default FIELDS-01, ticket
# #41; an optional -CorpusPath selects FIELDS-02). Its own package id and its own
# corpus asset: it never touches the nested_oracle, replace_rule_oracle,
# first_slice or html_oracle corpora.
$ErrorActionPreference = 'Stop'
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
  & $Program @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Program exited $LASTEXITCODE" }
}
if (Test-Path $OutputDirectory) { throw 'Use a fresh output directory' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
foreach ($directory in @('classes','dex','assets')) {
  New-Item -ItemType Directory -Path (Join-Path $OutputDirectory $directory) | Out-Null
}
$tools = Join-Path $AndroidSdk 'build-tools/35.0.1'
$androidJar = Join-Path $AndroidSdk 'platforms/android-35/android.jar'
# The selected FIELDS corpus travels inside the harness under the fixed asset
# name: the oracle serves it from the device process on the port the corpus
# names, and the report/golden records the selected file's hash as its corpus
# hash. The bytes are copied as they are on disk; a Windows checkout that
# rewrote them to CRLF has to be normalised back to the committed LF blob before
# the build, which is why both hashes are printed.
$selectedCorpus = (Resolve-Path $CorpusPath).Path
[System.IO.File]::Copy($selectedCorpus, "$OutputDirectory/assets/field-fixtures.json", $true)
$sourceHash = (Get-FileHash $selectedCorpus -Algorithm SHA256).Hash.ToLowerInvariant()
$assetHash = (Get-FileHash "$OutputDirectory/assets/field-fixtures.json" -Algorithm SHA256).Hash.ToLowerInvariant()
if ($sourceHash -ne $assetHash) { throw "the corpus asset does not match the corpus file" }
Write-Host "selected corpus: $selectedCorpus"
Write-Host "corpus asset sha256: $assetHash"
$selectedFixture = (Get-Content -Raw $selectedCorpus) | ConvertFrom-Json
$isFields02 = $selectedFixture.fixtureId -eq 'FIELDS-02'
$sourceInputs = [ordered]@{
  'FieldOracle.java' = "$PSScriptRoot/FieldOracle.java"
  'StateSessionOracle.java' = "$PSScriptRoot/../nested_oracle/StateSessionOracle.java"
  'HostRuntimeInit.java' = "$PSScriptRoot/../nested_oracle/HostRuntimeInit.java"
  'ShortcutStartupGuard.java' = "$PSScriptRoot/../nested_oracle/ShortcutStartupGuard.java"
  'AndroidManifest.xml' = "$PSScriptRoot/AndroidManifest.xml"
  'build.ps1' = "$PSScriptRoot/build.ps1"
  'capture.py' = "$PSScriptRoot/capture.py"
}
function Get-ProvenanceSourceHashes {
  $hashes = [ordered]@{}
  foreach ($entry in $sourceInputs.GetEnumerator()) {
    $hashes[$entry.Key] = (Get-FileHash $entry.Value -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  return $hashes
}
$sourceHashesBefore = Get-ProvenanceSourceHashes
function Get-Sha256Bytes([byte[]]$bytes) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}
$corpusBytes = [System.IO.File]::ReadAllBytes($selectedCorpus)
$lfBuffer = New-Object System.Collections.Generic.List[byte]
for ($index = 0; $index -lt $corpusBytes.Length; $index++) {
  if ($corpusBytes[$index] -eq 13 -and $index + 1 -lt $corpusBytes.Length -and $corpusBytes[$index + 1] -eq 10) { continue }
  $lfBuffer.Add($corpusBytes[$index])
}
$corpusLfHash = Get-Sha256Bytes $lfBuffer.ToArray()
if ($isFields02) {
  if ($selectedFixture.corpusVersion -isnot [int] -and $selectedFixture.corpusVersion -isnot [long]) {
    throw 'FIELDS-02 corpusVersion must be an integer'
  }
  if ([long]$selectedFixture.corpusVersion -ne 1) { throw 'FIELDS-02 corpusVersion must be 1' }
}
# FIELDS-02's storage-only Application reuses the existing STATE scratch helper;
# compiling its source here keeps the two harnesses on the same visibility-only
# helper bytes. The original nested build and assets are unchanged.
Invoke-Checked "$JavaHome/bin/javac.exe" @('-source','8','-target','8','-cp',$androidJar,'-d',"$OutputDirectory/classes","$PSScriptRoot/../nested_oracle/StateSessionOracle.java","$PSScriptRoot/../nested_oracle/HostRuntimeInit.java","$PSScriptRoot/../nested_oracle/ShortcutStartupGuard.java","$PSScriptRoot/FieldOracle.java")
$sourceHashesAfter = Get-ProvenanceSourceHashes
if (($sourceHashesBefore | ConvertTo-Json -Compress) -ne ($sourceHashesAfter | ConvertTo-Json -Compress)) {
  throw 'FIELDS build source inputs changed during compilation'
}
if ($isFields02) {
  $provenance = [ordered]@{
    schemaVersion = 1
    fixtureId = 'FIELDS-02'
    corpus = [ordered]@{
      asset = 'field-fixtures.json'
      bytes = $corpusBytes.Length
      sha256 = $sourceHash
      sha256Lf = $corpusLfHash
      fixtureId = 'FIELDS-02'
      corpusVersion = 1
    }
    sources = $sourceHashesAfter
  }
  $provenanceJson = $provenance | ConvertTo-Json -Depth 6
  $provenancePath = "$OutputDirectory/assets/field-provenance.json"
  [System.IO.File]::WriteAllText($provenancePath, $provenanceJson,
    (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "provenance asset sha256: $((Get-FileHash $provenancePath -Algorithm SHA256).Hash.ToLowerInvariant())"
}
Invoke-Checked "$JavaHome/bin/jar.exe" @('cf',"$OutputDirectory/classes.jar",'-C',"$OutputDirectory/classes",'.')
Invoke-Checked "$JavaHome/bin/java.exe" @('-cp',"$tools/lib/d8.jar",'com.android.tools.r8.D8','--lib',$androidJar,'--min-api','26','--output',"$OutputDirectory/dex","$OutputDirectory/classes.jar")
Invoke-Checked "$tools/aapt.exe" @('package','-f','-M',"$PSScriptRoot/AndroidManifest.xml",'-I',$androidJar,'-A',"$OutputDirectory/assets",'-F',"$OutputDirectory/unsigned.apk")
Invoke-Checked "$JavaHome/bin/jar.exe" @('uf',"$OutputDirectory/unsigned.apk",'-C',"$OutputDirectory/dex",'classes.dex')
Invoke-Checked "$tools/zipalign.exe" @('-p','4',"$OutputDirectory/unsigned.apk","$OutputDirectory/aligned.apk")
# Standard local Android debug key; its certificate must match the frozen APK.
Invoke-Checked "$JavaHome/bin/java.exe" @('-jar',"$tools/lib/apksigner.jar",'sign','--ks',$DebugKeystore,'--ks-key-alias','androiddebugkey','--ks-pass','pass:android','--key-pass','pass:android','--out',"$OutputDirectory/field-oracle.apk","$OutputDirectory/aligned.apk")
if ($isFields02) {
  $sourceHashesFinal = Get-ProvenanceSourceHashes
  if (($sourceHashesBefore | ConvertTo-Json -Compress) -ne ($sourceHashesFinal | ConvertTo-Json -Compress)) {
    throw 'FIELDS build source inputs changed during packaging'
  }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [System.IO.Compression.ZipFile]::OpenRead("$OutputDirectory/field-oracle.apk")
  try {
    $assetEntries = @($archive.Entries | Where-Object { $_.FullName -eq 'assets/field-fixtures.json' })
    $provenanceEntries = @($archive.Entries | Where-Object { $_.FullName -eq 'assets/field-provenance.json' })
    if ($assetEntries.Count -ne 1 -or $provenanceEntries.Count -ne 1) {
      throw 'FIELDS APK must contain exactly one embedded corpus and provenance'
    }
    $assetStream = $assetEntries[0].Open()
    try {
      $sha = [System.Security.Cryptography.SHA256]::Create()
      try { $embeddedAssetHash = ([System.BitConverter]::ToString($sha.ComputeHash($assetStream))).Replace('-', '').ToLowerInvariant() }
      finally { $sha.Dispose() }
    } finally { $assetStream.Dispose() }
    if ($embeddedAssetHash -ne $sourceHash) { throw 'FIELDS APK embedded corpus differs from the build input' }
    $provenanceStream = $provenanceEntries[0].Open()
    try {
      $sha = [System.Security.Cryptography.SHA256]::Create()
      try { $embeddedProvenanceHash = ([System.BitConverter]::ToString($sha.ComputeHash($provenanceStream))).Replace('-', '').ToLowerInvariant() }
      finally { $sha.Dispose() }
    } finally { $provenanceStream.Dispose() }
    if ($embeddedProvenanceHash -ne (Get-FileHash $provenancePath -Algorithm SHA256).Hash.ToLowerInvariant()) {
      throw 'FIELDS APK embedded provenance differs from the generated asset'
    }
  } finally { $archive.Dispose() }
}
Get-FileHash "$OutputDirectory/field-oracle.apk" -Algorithm SHA256
