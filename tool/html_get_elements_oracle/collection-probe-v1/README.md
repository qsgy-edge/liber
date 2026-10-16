# Collection getter evidence

Five files in this directory are exact byte copies of the existing successful
`source-checkpoint/collection-probe-v1/` execution: input, actual observed output,
manifest, stdout and empty stderr. `pins.json` binds those bytes. The original
compiled GetElementsOracle main/classes/JARs produced exactly eight rows with
JVM exit 0; the unchanged harness hardcodes output corpus HTML-GET-ELEMENTS-01.
No original row was re-executed while preparing these tests.

`test/html_get_elements_test.dart` group `HTML getElements collection observed`
runs each original getter script through the actual HTML book-info author path
using this exact HTML and compares decoded output to the actual row value.
The eight getter rows retain duplicate merge membership and reversed-root order,
empty Elements versus JS arrays, missing versus empty attributes, and descendant
selection identity deduplication.

`HTML getElements collection source controls` has two equivalent-producer tests:
the missing/empty attribute cases use Jsoup.parse(src).select(css), and the
overlap case removes the getter's @CSS: mode prefix when passing the same raw CSS
to Jsoup.select. These controls isolate façade/native reads from getter
collection wrapping. Their adapted scripts are not additional frozen executions.

The candidate's matching Windows library passed these cases within the 47-case
element suite and 11-case adapter suite. Independent review, integration, a new
Windows app/scratch driven run and platform acceptance remain pending. Host-JVM
rows do not establish Android-device, whole-entity or Java-mutator parity.
