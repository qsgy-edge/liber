package io.liber.oracle.nested;

import android.app.Instrumentation;
import android.os.Bundle;
import android.os.Build;
import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.lang.reflect.*;
import java.util.*;
import java.util.concurrent.*;

/** Controlled state experiments against installed frozen production classes. */
public final class StateOracle extends Instrumentation {
    private ClassLoader loader;
    private Class<?> sourceClass, urlClass, contextClass, jobClass;
    private Constructor<?> ctor;
    private Method eval, getScope;
    private Object empty, sharedScope;
    private JSONObject fixture;
    // Strong references isolate LRU eviction from nondeterministic weak-ref GC.
    private final List<Object> pinned = new ArrayList<>();
    private String origin;
    private Object source(String library) throws Exception {
        Object source = sourceClass.getConstructor().newInstance();
        sourceClass.getMethod("setBookSourceUrl", String.class).invoke(source, origin + "/source");
        sourceClass.getMethod("setJsLib", String.class).invoke(source, library);
        return source;
    }
    private String run(String library, String script, Object context) throws Exception {
        Object url = ctor.newInstance(origin + "/", "outer-key", Integer.valueOf(7), null, null, "", source(library), null, null, null, null, context, null, Boolean.TRUE);
        try {
            Object result = eval.invoke(url, script.replace("$ORIGIN", origin), null);
            return result == null ? "null" : result.toString();
        } catch (InvocationTargetException e) {
            Throwable cause = e.getCause();
            if (cause instanceof CancellationException) return "error:cancelled";
            throw e;
        }
    }
    private void pin(String library) throws Exception { pinned.add(getScope.invoke(sharedScope, library, empty)); }
    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }
    @Override public void onStart() {
        Bundle status = new Bundle();
        ExecutorService work = Executors.newFixedThreadPool(2);
        try (Replay replay = new Replay()) {
            origin = replay.origin;
            try (InputStream input = getContext().getAssets().open("state-fixtures.json")) {
                fixture = new JSONObject(new String(input.readAllBytes(), StandardCharsets.UTF_8));
            }
            loader = getTargetContext().getClassLoader();
            sourceClass = loader.loadClass("io.legado.app.data.entities.BookSource");
            urlClass = loader.loadClass("io.legado.app.model.analyzeRule.AnalyzeUrl");
            contextClass = loader.loadClass("kotlin.coroutines.CoroutineContext");
            empty = loader.loadClass("kotlin.coroutines.EmptyCoroutineContext").getField("INSTANCE").get(null);
            jobClass = loader.loadClass("kotlinx.coroutines.Job");
            Class<?> scopes = loader.loadClass("io.legado.app.model.SharedJsScope");
            sharedScope = scopes.getField("INSTANCE").get(null);
            getScope = scopes.getMethod("getScope", String.class, contextClass);
            for (Constructor<?> candidate : urlClass.getConstructors()) if (candidate.getParameterCount() == 14) ctor = candidate;
            if (ctor == null) throw new IllegalStateException("Frozen ctor absent");
            eval = urlClass.getMethod("evalJS", String.class, Object.class);
            JSONObject values = new JSONObject();
            String concurrent = fixture.getString("library") + "concurrent";
            run(concurrent, fixture.getString("warm"), empty); pin(concurrent);
            Future<String> first = work.submit(() -> run(concurrent, fixture.getString("first"), empty));
            if (!replay.held.await(5, TimeUnit.SECONDS)) throw new IllegalStateException("First request did not reach hold");
            CountDownLatch secondStarted = new CountDownLatch(1);
            Future<String> second = work.submit(() -> { secondStarted.countDown(); return run(concurrent, fixture.getString("second"), empty); });
            if (!secondStarted.await(5, TimeUnit.SECONDS)) throw new IllegalStateException("Second task not started");
            boolean completed = false;
            try { second.get(fixture.getLong("barrierWaitMilliseconds"), TimeUnit.MILLISECONDS); completed = true; }
            catch (TimeoutException expected) { }
            values.put("secondCompletedWhileFirstHeld", completed);
            replay.release.countDown();
            values.put("firstResult", first.get(5, TimeUnit.SECONDS));
            values.put("secondResult", second.get(5, TimeUnit.SECONDS));
            values.put("concurrentFinalState", run(concurrent, fixture.getString("read"), empty));
            Future<String> early = work.submit(() -> run(concurrent, fixture.getString("early"), empty));
            if (!replay.earlyHeld.await(5, TimeUnit.SECONDS)) throw new IllegalStateException("Early not held");
            Future<String> late = work.submit(() -> run(concurrent, fixture.getString("late"), empty));
            if (!replay.lateHeld.await(5, TimeUnit.SECONDS)) throw new IllegalStateException("Late not held");
            replay.earlyRelease.countDown();
            boolean earlyFinished = false;
            try { early.get(2, TimeUnit.SECONDS); earlyFinished = true; } catch (TimeoutException expected) { }
            values.put("firstCompletesWhileSecondHeld", earlyFinished);
            replay.lateRelease.countDown();
            early.get(5, TimeUnit.SECONDS); late.get(5, TimeUnit.SECONDS);

            String cancelled = fixture.getString("library") + "cancel";
            run(cancelled, fixture.getString("warm"), empty); pin(cancelled);
            Object job = loader.loadClass("kotlinx.coroutines.JobKt").getMethod("Job", jobClass).invoke(null, new Object[]{null});
            Future<String> interrupted = work.submit(() -> run(cancelled, fixture.getString("cancel"), job));
            if (!replay.entered.await(5, TimeUnit.SECONDS)) throw new IllegalStateException("Cancel marker not observed");
            jobClass.getMethod("cancel", CancellationException.class).invoke(job, new CancellationException("fixture cancellation"));
            values.put("cancelResult", interrupted.get(5, TimeUnit.SECONDS));
            values.put("afterCancelState", run(cancelled, fixture.getString("read"), empty));

            String base = fixture.getString("library") + "cache-";
            for (int i=0;i<16;i++) { String lib=base+i; run(lib, fixture.getString("seed"), empty); pin(lib); }
            values.put("lruTouch", run(base+0, fixture.getString("read"), empty));
            run(base+16, fixture.getString("seed"), empty); pin(base+16);
            values.put("lruRetained", run(base+0, fixture.getString("read"), empty));
            values.put("lruEvicted", run(base+1, fixture.getString("read"), empty));
            JSONObject report = new JSONObject().put("baselineCommit",fixture.getString("baselineCommit")).put("fingerprint",Build.FINGERPRINT)
                .put("values",values).put("requests",replay.requests).put("weakReferencesPinnedForLru",true);
            File output = new File(getTargetContext().getExternalFilesDir(null), "state-oracle.json");
            try (FileOutputStream stream = new FileOutputStream(output)) { stream.write(report.toString(2).getBytes(StandardCharsets.UTF_8)); }
            status.putString("stream", "State oracle recorded " + values.length() + " observations\n");
            finish(-1,status);
        } catch (Throwable error) { status.putString("stream", error.toString()+" cause="+error.getCause()+"\n"); finish(1,status); }
        finally { work.shutdownNow(); }
    }
    static final class Replay implements AutoCloseable {
        final ServerSocket server = new ServerSocket(18764,16,InetAddress.getByName("127.0.0.1"));
        final String origin="http://127.0.0.1:18764";
        final CountDownLatch held=new CountDownLatch(1), release=new CountDownLatch(1), entered=new CountDownLatch(1);
        final JSONArray requests=new JSONArray();
        final CountDownLatch earlyHeld=new CountDownLatch(1), lateHeld=new CountDownLatch(1), earlyRelease=new CountDownLatch(1), lateRelease=new CountDownLatch(1);
        final ExecutorService clients=Executors.newFixedThreadPool(4);
        final Thread worker;
        Replay() throws Exception {
            worker=new Thread(() -> {
                while(!server.isClosed()) {
                    try {
                        final Socket accepted=server.accept();
                        clients.submit(() -> { try(Socket client=accepted) {
                        client.setSoTimeout(5000);
                        BufferedReader input=new BufferedReader(new InputStreamReader(client.getInputStream(),StandardCharsets.UTF_8));
                        String line=input.readLine(); if(line==null)return;
                        String target=line.split(" ")[1]; synchronized(requests){requests.put("GET "+target);}
                        while((line=input.readLine())!=null&&!line.isEmpty()){}
                        if(target.equals("/hold")){held.countDown(); if(!release.await(10,TimeUnit.SECONDS))throw new IOException("Hold not released");}
                        if(target.equals("/early")){earlyHeld.countDown(); if(!earlyRelease.await(10,TimeUnit.SECONDS))throw new IOException("Early not released");}
                        if(target.equals("/late")){lateHeld.countDown(); if(!lateRelease.await(10,TimeUnit.SECONDS))throw new IOException("Late not released");}
                        OutputStream output=client.getOutputStream();
                        output.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".getBytes(StandardCharsets.US_ASCII));output.flush();
                        if(target.equals("/entered"))entered.countDown();
                    }catch(Exception error){if(!server.isClosed())synchronized(requests){requests.put("SERVER_ERROR "+error.getClass().getName());}} });
                    }catch(IOException error){if(!server.isClosed())synchronized(requests){requests.put("ACCEPT_ERROR");}}
                }
            },"state-oracle-replay"); worker.start();
        }
        public void close()throws Exception{release.countDown();earlyRelease.countDown();lateRelease.countDown();server.close();worker.join(1000);clients.shutdown();if(worker.isAlive()||!clients.awaitTermination(5,TimeUnit.SECONDS))throw new IllegalStateException("Replay did not stop");}
    }
}
