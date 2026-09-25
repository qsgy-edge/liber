// `org.jsoup.nodes.Node`, for the compile classpath only.
//
// `AnalyzeRule.setContent` (`AnalyzeRule.kt:83-89`) asks `is Node` once, to
// decide that a jsoup element is never JSON. The harness pins no jsoup jar —
// this corpus decides the *replacement* path around an extraction, and the
// selector engine itself belongs to the product's Rust adapter and to
// `tool/html_oracle/` — so the one type that `when` names is declared here. No
// value of it is ever constructed, and no corpus case reaches the check with a
// node.
package org.jsoup.nodes

/** The jsoup `Node` type `AnalyzeRule.setContent` names. */
open class Node
