# Raw attribute evidence

Five files are exact byte copies of the separate authorized
`source-checkpoint/collection-attribute-probe-v1/` execution. `pins.json` binds
fixtures, actual observed output, manifest and raw stdout/stderr. The same original
compiled GetElementsOracle main/classes/JARs ran once with -Xmx256m: exactly two
new rows, JVM exit 0, no compile/download or rerun of the original twelve/eight.
The unchanged harness's actual output corpus remains HTML-GET-ELEMENTS-01.

`raw-whitespace-and-empty-attribute-units` records raw space/tab/LF/CR/space,
first-present empty attribute before a later nonempty one, and node reads.
`raw-text-all-key-collision-units` records literal text/all attribute values,
once-parsed entity characters and the distinct node.text() result. Every String
is converted to explicit charCodeAt units inside the original frozen script,
so the product's scalar HTML decoding tail cannot manufacture the expected value.
Observed bytes were not derived from the product or edited.

The `HTML getElements raw attribute observed` group executes both exact getter
scripts through the current real HTML pipeline. The separate `HTML getElements
raw attribute source controls` group changes only the initial getter producer
to existing Jsoup.parse(src).select(css), retaining code-unit outputs to isolate
existing DOM bridge attribute/text/serialization collisions. Those two controls
are equivalent-source product controls, not extra frozen runs.

The candidate's matching Windows library passed these cases within its 47-case
element suite and 11-case adapter suite. Raw attributes use a separate native read
from text/serialization. Independent review, integration, a new Windows
app/scratch driven run and platform acceptance remain pending. No whole-entity,
new-device or mutable-Java-Elements compatibility claim is made.
