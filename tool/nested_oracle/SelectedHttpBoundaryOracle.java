package io.liber.oracle.nested;

/** Fixed target and corpus entry for the selected-reference HTTP-BOUNDARY-01 corpus. */
public final class SelectedHttpBoundaryOracle extends HttpBoundaryOracle {
    @Override boolean selectedCorpus() { return true; }

    @Override public boolean onException(Object object, Throwable error) {
        return handleShortcutException(object, error) || super.onException(object, error);
    }
}
