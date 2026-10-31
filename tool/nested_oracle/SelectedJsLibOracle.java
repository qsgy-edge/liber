package io.liber.oracle.nested;

/** Fixed storage-only entry: Android creates the application before onCreate extras. */
public final class SelectedJsLibOracle extends NestedOracle {
    @Override boolean storageOnly() { return true; }
}
