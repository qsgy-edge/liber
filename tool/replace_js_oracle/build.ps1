param(
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [Parameter(Mandatory=$true)][string]$JavaHome,
  [string]$AndroidSdk = "$env:LOCALAPPDATA/Android/Sdk",
  [string]$DebugKeystore = "$env:USERPROFILE/.android/debug.keystore"
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
