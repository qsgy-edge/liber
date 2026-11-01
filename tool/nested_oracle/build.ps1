param(
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [Parameter(Mandatory=$true)][string]$JavaHome,
  [string]$AndroidSdk = "$env:LOCALAPPDATA/Android/Sdk",
  [string]$DebugKeystore = "$env:USERPROFILE/.android/debug.keystore",
  # Optional local selection of the HTML corpus asset only. The default stays
  # the original #12/#65 corpus, so every existing build is unchanged; passing
  # tool/html_oracle/list-fixtures.json packages the independent HTML-LIST-01
  # family under the harness' fixed html-fixtures.json asset name.
  [string]$HtmlCorpusPath = "$PSScriptRoot/../html_oracle/fixtures.json"
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
# The explicitly selected local jsLib shared-scope corpus (#74) travels the same
# way: `am instrument -e corpus jslib` makes NestedOracle read it instead of the
# default fixtures.json, and its golden records this file's hash.
Copy-Item "$PSScriptRoot/jslib-fixtures.json" "$OutputDirectory/assets/jslib-fixtures.json"
# The selected-reference JSLIB-01 corpus travels the same way:
# `am instrument -e corpus jslib-selected` makes SelectedJsLibOracle read it instead of the
# historical corpus, and its capture pins this file's hash and target pin.
Copy-Item "$PSScriptRoot/jslib-fixtures-selected.json" "$OutputDirectory/assets/jslib-fixtures-selected.json"
Copy-Item "$PSScriptRoot/state-fixtures.json" "$OutputDirectory/assets/state-fixtures.json"
# The request-semantics corpus travels the same way: the RequestOracle drives the
# frozen AnalyzeUrl against it, and the golden records this file's hash.
Copy-Item "$PSScriptRoot/request-fixtures.json" "$OutputDirectory/assets/request-fixtures.json"
# The first-slice corpus travels inside the harness: the oracle serves it from the
# device process, and the golden records this file's hash as its corpus hash.
Copy-Item "$PSScriptRoot/../first_slice/fixtures.json" "$OutputDirectory/assets/slice-fixtures.json"
# The #23 HTML extraction corpus travels the same way; the harness serves it from
# the device process, and the golden records `tool/html_oracle/fixtures.json`'s
# hash as its corpus hash. -HtmlCorpusPath may select the independent
# HTML-LIST-01 corpus instead; only this asset changes, and the collector binds
# its emitted observations to the packaged asset's actual bytes and raw SHA-256.
Copy-Item (Resolve-Path $HtmlCorpusPath).Path "$OutputDirectory/assets/html-fixtures.json"
# Ticket #79's limit probe drives a rule-level `@js:` field through the frozen
# rule path and appends every stage to a journal the process may not outlive, so
# its row set travels as data too.
Copy-Item "$PSScriptRoot/limit-fixtures.json" "$OutputDirectory/assets/limit-fixtures.json"
# The #136 STATE-SESSION-01 corpus travels the same way: StateSessionOracle serves
# it from the device process, and its report pins this file's LF-normalised hash.
Copy-Item "$PSScriptRoot/../state_session/fixtures.json" "$OutputDirectory/assets/state-session-fixtures.json"
# The selected-reference STATE-SESSION-01 corpus travels beside it: the fixed
# SelectedStateSessionOracle entry serves it, pinning its hash and selected target.
Copy-Item "$PSScriptRoot/../state_session/fixtures-selected.json" "$OutputDirectory/assets/state-session-fixtures-selected.json"
# The #137 AUTH-SESSION-01 corpus is served by AuthSessionOracle from the target
# process; the report pins both the raw asset hash and the LF-normalised hash.
Copy-Item "$PSScriptRoot/../auth_session/fixtures.json" "$OutputDirectory/assets/auth-session-fixtures.json"
# The #137 HTTP-BOUNDARY-01 corpus is served by HttpBoundaryOracle from the target
# process; its report pins both the raw asset hash and the LF-normalised hash.
Copy-Item "$PSScriptRoot/../http_boundary/fixtures.json" "$OutputDirectory/assets/http-boundary-fixtures.json"
Invoke-Checked "$JavaHome/bin/javac.exe" @('-source','8','-target','8','-cp',$androidJar,'-d',"$OutputDirectory/classes","$PSScriptRoot/HostRuntimeInit.java","$PSScriptRoot/ShortcutStartupGuard.java","$PSScriptRoot/NestedOracle.java","$PSScriptRoot/SelectedJsLibOracle.java","$PSScriptRoot/StateOracle.java","$PSScriptRoot/SliceOracle.java","$PSScriptRoot/HtmlOracle.java","$PSScriptRoot/RequestOracle.java","$PSScriptRoot/LimitOracle.java","$PSScriptRoot/StateSessionOracle.java","$PSScriptRoot/SelectedStateSessionOracle.java","$PSScriptRoot/AuthSessionOracle.java","$PSScriptRoot/HttpBoundaryOracle.java")
Invoke-Checked "$JavaHome/bin/jar.exe" @('cf',"$OutputDirectory/classes.jar",'-C',"$OutputDirectory/classes",'.')
Invoke-Checked "$JavaHome/bin/java.exe" @('-cp',"$tools/lib/d8.jar",'com.android.tools.r8.D8','--lib',$androidJar,'--min-api','26','--output',"$OutputDirectory/dex","$OutputDirectory/classes.jar")
Invoke-Checked "$tools/aapt.exe" @('package','-f','-M',"$PSScriptRoot/AndroidManifest.xml",'-I',$androidJar,'-A',"$OutputDirectory/assets",'-F',"$OutputDirectory/unsigned.apk")
Invoke-Checked "$JavaHome/bin/jar.exe" @('uf',"$OutputDirectory/unsigned.apk",'-C',"$OutputDirectory/dex",'classes.dex')
Invoke-Checked "$tools/zipalign.exe" @('-p','4',"$OutputDirectory/unsigned.apk","$OutputDirectory/aligned.apk")
# Standard local Android debug key; its certificate must match the frozen APK.
Invoke-Checked "$JavaHome/bin/java.exe" @('-jar',"$tools/lib/apksigner.jar",'sign','--ks',$DebugKeystore,'--ks-key-alias','androiddebugkey','--ks-pass','pass:android','--key-pass','pass:android','--out',"$OutputDirectory/nested-oracle.apk","$OutputDirectory/aligned.apk")
Get-FileHash "$OutputDirectory/nested-oracle.apk" -Algorithm SHA256
