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
Copy-Item "$PSScriptRoot/state-fixtures.json" "$OutputDirectory/assets/state-fixtures.json"
# The request-semantics corpus travels the same way: the RequestOracle drives the
# frozen AnalyzeUrl against it, and the golden records this file's hash.
Copy-Item "$PSScriptRoot/request-fixtures.json" "$OutputDirectory/assets/request-fixtures.json"
# The first-slice corpus travels inside the harness: the oracle serves it from the
# device process, and the golden records this file's hash as its corpus hash.
Copy-Item "$PSScriptRoot/../first_slice/fixtures.json" "$OutputDirectory/assets/slice-fixtures.json"
# The #23 HTML extraction corpus travels the same way; the harness serves it from
# the device process, and the golden records `tool/html_oracle/fixtures.json`'s
# hash as its corpus hash.
Copy-Item "$PSScriptRoot/../html_oracle/fixtures.json" "$OutputDirectory/assets/html-fixtures.json"
Invoke-Checked "$JavaHome/bin/javac.exe" @('-source','8','-target','8','-cp',$androidJar,'-d',"$OutputDirectory/classes","$PSScriptRoot/NestedOracle.java","$PSScriptRoot/StateOracle.java","$PSScriptRoot/SliceOracle.java","$PSScriptRoot/HtmlOracle.java","$PSScriptRoot/RequestOracle.java")
Invoke-Checked "$JavaHome/bin/jar.exe" @('cf',"$OutputDirectory/classes.jar",'-C',"$OutputDirectory/classes",'.')
Invoke-Checked "$JavaHome/bin/java.exe" @('-cp',"$tools/lib/d8.jar",'com.android.tools.r8.D8','--lib',$androidJar,'--min-api','26','--output',"$OutputDirectory/dex","$OutputDirectory/classes.jar")
Invoke-Checked "$tools/aapt.exe" @('package','-f','-M',"$PSScriptRoot/AndroidManifest.xml",'-I',$androidJar,'-A',"$OutputDirectory/assets",'-F',"$OutputDirectory/unsigned.apk")
Invoke-Checked "$JavaHome/bin/jar.exe" @('uf',"$OutputDirectory/unsigned.apk",'-C',"$OutputDirectory/dex",'classes.dex')
Invoke-Checked "$tools/zipalign.exe" @('-p','4',"$OutputDirectory/unsigned.apk","$OutputDirectory/aligned.apk")
# Standard local Android debug key; its certificate must match the frozen APK.
Invoke-Checked "$JavaHome/bin/java.exe" @('-jar',"$tools/lib/apksigner.jar",'sign','--ks',$DebugKeystore,'--ks-key-alias','androiddebugkey','--ks-pass','pass:android','--key-pass','pass:android','--out',"$OutputDirectory/nested-oracle.apk","$OutputDirectory/aligned.apk")
Get-FileHash "$OutputDirectory/nested-oracle.apk" -Algorithm SHA256
