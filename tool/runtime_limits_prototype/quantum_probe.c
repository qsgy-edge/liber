/* THROWAWAY: measure the poll quantum's deadline benefit and throughput cost.
 *
 * The pinned QuickJS polls its interrupt handler every JS_INTERRUPT_COUNTER_INIT
 * interpreter polls (and every INTERRUPT_COUNTER_INIT libregexp steps). Both
 * constants live in the frozen vendored sources, so the harness builds this
 * probe against a patched *copy* of those sources and compares the deadline
 * overshoot against the throughput cost of polling more often.
 *
 * Every deadline case is repeated; the record keeps the median and the worst
 * sample so run-to-run variance stays visible. QUANTUM_LABEL is supplied by the
 * build so the record names the constant under test.
 */
#if defined(_WIN32)
#include <windows.h>
#else
/* Same clock shim as native_probe.c: only the monotonic clock differs by
 * platform, so the quantum comparison runs on every destination. */
#define _POSIX_C_SOURCE 200809L
#include <time.h>
#endif

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "quickjs.h"

#ifndef QUANTUM_LABEL
#define QUANTUM_LABEL 0
#endif

#define REPEATS 3
#define THROUGHPUT_REPEATS 9
#define MAX_REPEATS THROUGHPUT_REPEATS

#if defined(_WIN32)
static LARGE_INTEGER g_frequency;
static LARGE_INTEGER g_origin;

static void timer_init(void) {
  QueryPerformanceFrequency(&g_frequency);
  QueryPerformanceCounter(&g_origin);
}

static double now_ms(void) {
  LARGE_INTEGER counter;
  QueryPerformanceCounter(&counter);
  return (double)(counter.QuadPart - g_origin.QuadPart) * 1000.0 /
         (double)g_frequency.QuadPart;
}
#else
static struct timespec g_origin;

static void timer_init(void) { clock_gettime(CLOCK_MONOTONIC, &g_origin); }

static double now_ms(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (double)(now.tv_sec - g_origin.tv_sec) * 1000.0 +
         (double)(now.tv_nsec - g_origin.tv_nsec) / 1000000.0;
}
#endif

typedef struct {
  double deadline_ms;
  double start_ms;
  int fired;
} Interrupt;

static int on_interrupt(JSRuntime *rt, void *opaque) {
  Interrupt *state = opaque;
  (void)rt;
  if (state->deadline_ms > 0 &&
      now_ms() - state->start_ms >= state->deadline_ms) {
    state->fired = 1;
    return 1;
  }
  return 0;
}

typedef struct {
  double fastest_ms;
  double median_ms;
  double slowest_ms;
  int interrupted_all;
  int repeats;
} Samples;

static int compare_double(const void *left, const void *right) {
  const double a = *(const double *)left;
  const double b = *(const double *)right;
  return (a > b) - (a < b);
}

static double measure_once(JSRuntime *runtime, JSContext *context,
                           Interrupt *interrupt, const char *source,
                           double deadline_ms, bool *interrupted) {
  interrupt->deadline_ms = deadline_ms;
  interrupt->start_ms = now_ms();
  interrupt->fired = 0;
  const double started = now_ms();
  JSValue value = JS_Eval(context, source, strlen(source), "<quantum-probe>",
                          JS_EVAL_TYPE_GLOBAL);
  const double elapsed = now_ms() - started;
  if (JS_IsException(value)) {
    JSValue exception = JS_GetException(context);
    JS_FreeValue(context, exception);
  }
  JS_FreeValue(context, value);
  *interrupted = interrupt->fired != 0;
  return elapsed;
}

static Samples measure_samples(JSRuntime *runtime, JSContext *context,
                               Interrupt *interrupt, const char *source,
                               double deadline_ms, int repeats) {
  double samples[MAX_REPEATS];
  Samples result;
  memset(&result, 0, sizeof(result));
  result.interrupted_all = 1;
  result.repeats = repeats;
  for (int index = 0; index < repeats; index++) {
    JS_RunGC(runtime);
    bool interrupted = false;
    samples[index] =
        measure_once(runtime, context, interrupt, source, deadline_ms, &interrupted);
    if (!interrupted) result.interrupted_all = 0;
  }
  qsort(samples, repeats, sizeof(double), compare_double);
  result.fastest_ms = samples[0];
  result.median_ms = samples[repeats / 2];
  result.slowest_ms = samples[repeats - 1];
  return result;
}

static void print_samples(const char *name, const Samples *samples, double deadline_ms) {
  printf("    \"%s\": {\"deadlineMs\": %.0f, \"repeats\": %d, \"fastestMs\": %.2f, "
         "\"medianMs\": %.2f, \"slowestMs\": %.2f, \"worstOvershootMs\": %.2f, "
         "\"interruptedInEverySample\": %s}",
         name, deadline_ms, samples->repeats, samples->fastest_ms, samples->median_ms,
         samples->slowest_ms,
         deadline_ms > 0 ? samples->slowest_ms - deadline_ms : 0.0,
         samples->interrupted_all ? "true" : "false");
}

int main(int argc, char **argv) {
  timer_init();
  JSRuntime *runtime = JS_NewRuntime();
  JSContext *context = JS_NewContext(runtime);
  Interrupt interrupt;
  memset(&interrupt, 0, sizeof(interrupt));
  JS_SetInterruptHandler(runtime, on_interrupt, &interrupt);
  const size_t heap_limit = 8 * 1024 * 1024;

  /* A throughput-only process keeps earlier deadline cases, their garbage and
   * their garbage-collection pressure out of the measurement. */
  if (argc > 1 && strcmp(argv[1], "throughput") == 0) {
    const Samples only = measure_samples(
        runtime, context, &interrupt,
        "var sum = 0; for (var i = 0; i < 20000000; i++) sum += i; sum > 0", 0,
        THROUGHPUT_REPEATS);
    printf("{\"quantum\": %d, \"mode\": \"throughput-only\", \"cases\": {\"throughputLoop\": "
           "{\"deadlineMs\": 0, \"repeats\": %d, \"fastestMs\": %.2f, \"medianMs\": %.2f, "
           "\"slowestMs\": %.2f, \"worstOvershootMs\": 0.0, "
           "\"interruptedInEverySample\": false}}}",
           QUANTUM_LABEL, only.repeats, only.fastest_ms, only.median_ms,
           only.slowest_ms);
    JS_FreeContext(context);
    JS_FreeRuntime(runtime);
    return 0;
  }

  const Samples tight = measure_samples(runtime, context, &interrupt,
                                        "while(true) {}", 100, REPEATS);
  const Samples heavy = measure_samples(
      runtime, context, &interrupt, "while(true) { 'x'.repeat(50000); }", 100, REPEATS);
  const Samples allocation = measure_samples(
      runtime, context, &interrupt,
      "(function() { var blocks = []; while(true) { blocks.push(new "
      "Array(1024).fill(7)); } })()",
      100, REPEATS);
  const Samples regexp = measure_samples(
      runtime, context, &interrupt, "/(a+)+$/.test('a'.repeat(64) + '!')", 100, REPEATS);
  JS_SetMemoryLimit(runtime, heap_limit);
  const Samples oom_retry = measure_samples(
      runtime, context, &interrupt,
      "(function() { var last = null; for (;;) { try { last = new "
      "Array(20000).fill(0); } catch (e) {} } })()",
      300, REPEATS);
  JS_SetMemoryLimit(runtime, 0);
  const Samples throughput = measure_samples(
      runtime, context, &interrupt,
      "var sum = 0; for (var i = 0; i < 20000000; i++) sum += i; sum > 0", 0,
      THROUGHPUT_REPEATS);

  printf("{\"quantum\": %d,\n", QUANTUM_LABEL);
  printf("  \"cases\": {\n");
  print_samples("tightLoop", &tight, 100);
  printf(",\n");
  print_samples("heavyLoopBody", &heavy, 100);
  printf(",\n");
  print_samples("allocationLoop", &allocation, 100);
  printf(",\n");
  print_samples("regexpBacktracking", &regexp, 100);
  printf(",\n");
  print_samples("oomRetryLoop", &oom_retry, 300);
  printf(",\n");
  print_samples("throughputLoop", &throughput, 0);
  printf("\n  }}\n");

  JS_FreeContext(context);
  JS_FreeRuntime(runtime);
  return 0;
}
