param(
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [Parameter(Mandatory=$true)][string]$JavaHome,
  [string]$AndroidSdk = "$env:LOCALAPPDATA/Android/Sdk",
  [string]$DebugKeystore = "$env:USERPROFILE/.android/debug.keystore"
)
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
Copy-Item "$PSScriptRoot/fixtures.json" "$OutputDirectory/assets/fixtures.json"
Invoke-Checked "$JavaHome/bin/javac.exe" @('-encoding','UTF-8','-source','8','-target','8','-cp',$androidJar,'-d',"$OutputDirectory/classes","$PSScriptRoot/ReaderOracle.java")
Invoke-Checked "$JavaHome/bin/jar.exe" @('cf',"$OutputDirectory/classes.jar",'-C',"$OutputDirectory/classes",'.')
Invoke-Checked "$JavaHome/bin/java.exe" @('-cp',"$tools/lib/d8.jar",'com.android.tools.r8.D8','--lib',$androidJar,'--min-api','26','--output',"$OutputDirectory/dex","$OutputDirectory/classes.jar")
Invoke-Checked "$tools/aapt.exe" @('package','-f','-M',"$PSScriptRoot/AndroidManifest.xml",'-I',$androidJar,'-A',"$OutputDirectory/assets",'-F',"$OutputDirectory/unsigned.apk")
Invoke-Checked "$JavaHome/bin/jar.exe" @('uf',"$OutputDirectory/unsigned.apk",'-C',"$OutputDirectory/dex",'classes.dex')
Invoke-Checked "$tools/zipalign.exe" @('-p','4',"$OutputDirectory/unsigned.apk","$OutputDirectory/aligned.apk")
# Standard local Android debug key; its certificate must match the frozen APK.
Invoke-Checked "$JavaHome/bin/java.exe" @('-jar',"$tools/lib/apksigner.jar",'sign','--ks',$DebugKeystore,'--ks-key-alias','androiddebugkey','--ks-pass','pass:android','--key-pass','pass:android','--out',"$OutputDirectory/reader-oracle.apk","$OutputDirectory/aligned.apk")
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
  $bytes = [System.IO.File]::ReadAllBytes("$OutputDirectory/reader-oracle.apk")
  [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()
} finally { $sha.Dispose() }
