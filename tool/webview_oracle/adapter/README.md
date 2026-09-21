# Ticket 13 destination adapter probe

A thin adapter over the platform WebView, shaped to the frozen Legado
`BackstageWebView` contract, plus a Dart port of the oracle's replay server. It
exists to run the WV-* fixtures on a real device and compare the observations
against the frozen golden.

Run one fixture, or the whole set, from the prototype root:

```
bash tools/run_fixture.sh WV-01
bash tools/run_all_destination.sh
```

`tools/run_fixture.sh` documents the device requirements. Evidence lands in
`evidence/android-destination/`; `tools/compare_to_golden.js` performs the
comparison and `tools/write_destination_manifest.js` records provenance.
