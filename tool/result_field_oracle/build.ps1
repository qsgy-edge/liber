param(
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [Parameter(Mandatory=$true)][string]$JavaHome,
  [string]$AndroidSdk = "$env:LOCALAPPDATA/Android/Sdk",
  [string]$DebugKeystore = "$env:USERPROFILE/.android/debug.keystore"
)
# Builds the disposable FIELDS-01 result-field oracle APK (ticket #41). Its own
# package id and its own corpus asset: it never touches the nested_oracle,
# replace_rule_oracle, first_slice or html_oracle corpora.
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
# The FIELDS-01 corpus travels inside the harness: the oracle serves it from the
# device process on the port the corpus names, and the golden records this
# file's hash as its corpus hash. The bytes are copied as they are on disk; a
# Windows checkout that rewrote them to CRLF has to be normalised back to the
# committed LF blob before the build, which is why both hashes are printed.
[System.IO.File]::Copy("$PSScriptRoot/fixtures.json", "$OutputDirectory/assets/field-fixtures.json", $true)
$sourceHash = (Get-FileHash "$PSScriptRoot/fixtures.json" -Algorithm SHA256).Hash.ToLowerInvariant()
$assetHash = (Get-FileHash "$OutputDirectory/assets/field-fixtures.json" -Algorithm SHA256).Hash.ToLowerInvariant()
if ($sourceHash -ne $assetHash) { throw "the corpus asset does not match the corpus file" }
Write-Host "corpus asset sha256: $assetHash"
Invoke-Checked "$JavaHome/bin/javac.exe" @('-source','8','-target','8','-cp',$androidJar,'-d',"$OutputDirectory/classes","$PSScriptRoot/FieldOracle.java")
Invoke-Checked "$JavaHome/bin/jar.exe" @('cf',"$OutputDirectory/classes.jar",'-C',"$OutputDirectory/classes",'.')
Invoke-Checked "$JavaHome/bin/java.exe" @('-cp',"$tools/lib/d8.jar",'com.android.tools.r8.D8','--lib',$androidJar,'--min-api','26','--output',"$OutputDirectory/dex","$OutputDirectory/classes.jar")
Invoke-Checked "$tools/aapt.exe" @('package','-f','-M',"$PSScriptRoot/AndroidManifest.xml",'-I',$androidJar,'-A',"$OutputDirectory/assets",'-F',"$OutputDirectory/unsigned.apk")
Invoke-Checked "$JavaHome/bin/jar.exe" @('uf',"$OutputDirectory/unsigned.apk",'-C',"$OutputDirectory/dex",'classes.dex')
Invoke-Checked "$tools/zipalign.exe" @('-p','4',"$OutputDirectory/unsigned.apk","$OutputDirectory/aligned.apk")
# Standard local Android debug key; its certificate must match the frozen APK.
Invoke-Checked "$JavaHome/bin/java.exe" @('-jar',"$tools/lib/apksigner.jar",'sign','--ks',$DebugKeystore,'--ks-key-alias','androiddebugkey','--ks-pass','pass:android','--key-pass','pass:android','--out',"$OutputDirectory/field-oracle.apk","$OutputDirectory/aligned.apk")
Get-FileHash "$OutputDirectory/field-oracle.apk" -Algorithm SHA256
