# Liber

Liber is a cross-platform reader for remote books supplied through user-imported book sources and local books selected from user-owned folders.

## Language

**Book Source（书源）**:
A user-imported definition that describes how a remote book service is searched, fetched, and interpreted.
_Avoid_: Site configuration, scraper config

**Book Source Runtime（书源运行时）**:
The environment that carries a Book Source through search, book information, table of contents, and chapter content while preserving its session state.
_Avoid_: Parser, source JSON reader

**Book Source Compatibility（书源兼容）**:
Producing the same observable result as the selected Legado compatibility baseline for the same Book Source and controlled input.
_Avoid_: JSON import compatibility

**Compatibility Baseline（兼容基线）**:
The immutable Legado revision whose Book Source behavior defines compatibility for a Liber release.
_Avoid_: Latest Legado

**Local Library（本地书库）**:
The supported local books discovered under folders explicitly selected by the user and added to the bookshelf.
_Avoid_: Device-wide file scan
