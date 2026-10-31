package io.liber.oracle.nested;

/** Fixed target and corpus entry for the selected-reference state/session pair. */
public final class SelectedStateSessionOracle extends StateSessionOracle {
    @Override boolean selectedCorpus() { return true; }

    @Override public boolean onException(Object object, Throwable error) {
        return handleShortcutException(object, error) || super.onException(object, error);
    }
}
