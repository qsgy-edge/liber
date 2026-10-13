// XPath is outside this bounded corpus. Never supply a fabricated extraction.
package io.legado.app.model.analyzeRule

class AnalyzeByXPath(content: Any) {
    fun getString(rule: String): String = error("XPath outside rule-field corpus")
    fun getStringList(rule: String): List<String> = error("XPath outside rule-field corpus")
    fun getElements(rule: String): List<Any> = error("XPath outside rule-field corpus")
}
