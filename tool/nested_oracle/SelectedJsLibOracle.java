package io.liber.oracle.nested;

/** Fixed storage-only entry: Android creates the application before onCreate extras. */
public final class SelectedJsLibOracle extends NestedOracle {
    @Override boolean storageOnly() { return true; }

    @Override public boolean onException(Object object, Throwable error) {
        return handleShortcutException(object, error) || super.onException(object, error);
    }
}
