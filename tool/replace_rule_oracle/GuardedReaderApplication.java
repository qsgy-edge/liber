package io.liber.oracle.nested;

import android.app.Application;
import android.content.Intent;
import android.os.Bundle;
import java.util.concurrent.atomic.AtomicInteger;

/** Refuses the selected reader's restart before it can launch the real app. */
public final class GuardedReaderApplication extends Application {
    private static final AtomicInteger attempts = new AtomicInteger();

    static int launchAttempts() { return attempts.get(); }

    @Override public void startActivity(Intent intent) {
        attempts.incrementAndGet();
        throw new SecurityException("selected reader refused activity launch");
    }

    @Override public void startActivity(Intent intent, Bundle options) {
        attempts.incrementAndGet();
        throw new SecurityException("selected reader refused activity launch");
    }
}
