package io.liber.oracle.nested;

/** Fixed target and corpus entry for the selected-reference AUTH-SESSION-01 pair. */
public final class SelectedAuthSessionOracle extends AuthSessionOracle {
    @Override boolean selectedCorpus() { return true; }

    @Override public boolean onException(Object object, Throwable error) {
        return handleShortcutException(object, error) || super.onException(object, error);
    }
}
