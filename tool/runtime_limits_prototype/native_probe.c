/* THROWAWAY: probe the pinned QuickJS execution deadline and heap limit.
 *
 * Compiled from packages/fjs/libfjs/vendor/rquickjs-sys/quickjs, the same
 * QuickJS 0.15.1 sources the product DLL links. It answers two ticket
 * questions without Dart, FRB, or the fiber layer in the way:
 *
 *   1. can a wall-clock deadline held in C interrupt evaluation, and how far
 *      past that deadline can a workload run;
 *   2. what does JS_SetMemoryLimit actually do when the heap budget is spent:
 *      a catchable error, a corrupt runtime, or a process abort.
 *
 * The interrupt handler and the memory limit are the product's mechanisms:
 * Engine::create sets the memory limit, and Engine::init_broker installs the
 * interrupt handler that polls the cancellation flag.
 *
 * `status` reports whether every observation matched its expectation, so a
 * failed run means the instrument misbehaved. The `findings` object carries
 * the verdicts themselves.
 */
#if defined(_WIN32)
#include <windows.h>
#else
/* Only the monotonic clock differs by platform: the probes read it through
 * `timer_init`/`now_ms` so the same case list runs on every destination. */
#define _POSIX_C_SOURCE 200809L
#include <time.h>
#endif

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "quickjs.h"

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

/* Mirrors the product's interrupt closure: QuickJS polls it from the
 * interpreter and from libregexp, and returning 1 raises the uncatchable
 * "interrupted" error. */
typedef struct {
  double deadline_ms; /* 0 disables the deadline */
  double start_ms;
  long polls;
  int fired;
} Interrupt;

static int on_interrupt(JSRuntime *rt, void *opaque) {
  Interrupt *state = opaque;
  (void)rt;
  state->polls++;
  if (state->deadline_ms > 0 &&
      now_ms() - state->start_ms >= state->deadline_ms) {
    state->fired = 1;
    return 1;
  }
  return 0;
}

typedef struct {
  bool threw;
  char exception[320];
  char value[320];
  double ms;
  long polls;
  int fired;
  size_t malloc_size;
  size_t malloc_limit;
  size_t memory_used;
  long obj_count;
} Observation;

static void print_json_string(const char *text) {
  putchar('"');
  for (const unsigned char *cursor = (const unsigned char *)text; *cursor;
       cursor++) {
    switch (*cursor) {
      case '"': fputs("\\\"", stdout); break;
      case '\\': fputs("\\\\", stdout); break;
      case '\n': fputs("\\n", stdout); break;
      case '\r': fputs("\\r", stdout); break;
      case '\t': fputs("\\t", stdout); break;
      default:
        if (*cursor < 0x20) {
          printf("\\u%04x", *cursor);
        } else {
          putchar(*cursor);
        }
    }
  }
  putchar('"');
}

/* Runs one script with the deadline and heap budget under test. */
static Observation observe(JSRuntime *rt, JSContext *ctx, Interrupt *interrupt,
                           const char *source, double deadline_ms,
                           size_t memory_limit) {
  Observation result;
  memset(&result, 0, sizeof(result));
  JS_RunGC(rt);
  JS_SetMemoryLimit(rt, memory_limit);
  interrupt->deadline_ms = deadline_ms;
  interrupt->start_ms = now_ms();
  interrupt->polls = 0;
  interrupt->fired = 0;
  const double started = now_ms();
  JSValue value = JS_Eval(ctx, source, strlen(source), "<runtime-limits-probe>",
                          JS_EVAL_TYPE_GLOBAL);
  result.ms = now_ms() - started;
  result.polls = interrupt->polls;
  result.fired = interrupt->fired;
  if (JS_IsException(value)) {
    result.threw = true;
    JSValue exception = JS_GetException(ctx);
    JSValue name = JS_GetPropertyStr(ctx, exception, "name");
    JSValue message = JS_GetPropertyStr(ctx, exception, "message");
    const char *name_text = JS_ToCString(ctx, name);
    const char *message_text = JS_ToCString(ctx, message);
    if (name_text == NULL && message_text == NULL) {
      /* Inspecting an error object allocates; at the heap limit that can fail. */
      snprintf(result.exception, sizeof(result.exception),
               "unavailable (error object could not be inspected)");
    } else {
      snprintf(result.exception, sizeof(result.exception), "%s: %s",
               name_text == NULL ? "?" : name_text,
               message_text == NULL ? "?" : message_text);
    }
    if (name_text) JS_FreeCString(ctx, name_text);
    if (message_text) JS_FreeCString(ctx, message_text);
    JS_FreeValue(ctx, name);
    JS_FreeValue(ctx, message);
    JS_FreeValue(ctx, exception);
  } else {
    const char *text = JS_ToCString(ctx, value);
    if (text) {
      snprintf(result.value, sizeof(result.value), "%s", text);
      JS_FreeCString(ctx, text);
    }
  }
  JS_FreeValue(ctx, value);
  JSMemoryUsage usage;
  JS_ComputeMemoryUsage(rt, &usage);
  result.malloc_size = (size_t)usage.malloc_size;
  result.malloc_limit = (size_t)usage.malloc_limit;
  result.memory_used = (size_t)usage.memory_used_size;
  result.obj_count = (long)usage.obj_count;
  return result;
}

static void emit_case(const char *name, const char *source, double deadline_ms,
                      size_t memory_limit, const Observation *observation,
                      const char *expectation, bool passed) {
  printf("    {");
  printf("\"name\": ");
  print_json_string(name);
  printf(", \"source\": ");
  print_json_string(source);
  printf(", \"deadlineMs\": %.1f", deadline_ms);
  printf(", \"memoryLimitBytes\": %llu", (unsigned long long)memory_limit);
  printf(", \"measuredMs\": %.1f", observation->ms);
  printf(", \"overshootMs\": %.1f",
         deadline_ms > 0 ? observation->ms - deadline_ms : 0.0);
  printf(", \"interruptPolls\": %ld", observation->polls);
  printf(", \"interruptFired\": %s", observation->fired ? "true" : "false");
  printf(", \"threw\": %s", observation->threw ? "true" : "false");
  printf(", \"exception\": ");
  print_json_string(observation->exception);
  printf(", \"value\": ");
  print_json_string(observation->value);
  printf(", \"mallocSize\": %llu", (unsigned long long)observation->malloc_size);
  printf(", \"mallocLimit\": %llu",
         (unsigned long long)observation->malloc_limit);
  printf(", \"memoryUsedSize\": %llu",
         (unsigned long long)observation->memory_used);
  printf(", \"objCount\": %ld", observation->obj_count);
  printf(", \"expectation\": ");
  print_json_string(expectation);
  printf(", \"passed\": %s}\n", passed ? "true" : "false");
}

typedef struct {
  char name[96];
  bool passed;
} Check;

static Check checks[64];
static int check_count = 0;
static bool record(const char *label, bool condition) {
  snprintf(checks[check_count].name, sizeof(checks[check_count].name), "%s",
           label);
  checks[check_count].passed = condition;
  check_count++;
  return condition;
}

static bool first_case = true;
static void case_boundary(void) {
  if (!first_case) fputs(",\n", stdout);
  first_case = false;
}

static bool is_interrupted(const Observation *observation) {
  return observation->threw &&
         strstr(observation->exception, "interrupted") != NULL;
}

int main(void) {
  timer_init();
  const size_t mib = 1024 * 1024;

  JSRuntime *rt = JS_NewRuntime();
  if (rt == NULL) {
    fprintf(stderr, "JS_NewRuntime failed\n");
    return 2;
  }
  JSContext *ctx = JS_NewContext(rt);
  if (ctx == NULL) {
    fprintf(stderr, "JS_NewContext failed\n");
    return 2;
  }
  Interrupt interrupt;
  memset(&interrupt, 0, sizeof(interrupt));
  JS_SetInterruptHandler(rt, on_interrupt, &interrupt);

  printf("{\n  \"engine\": \"QuickJS %s (pinned vendored sources)\",\n",
         JS_GetVersion());
  printf("  \"cases\": [\n");

  /* 1. Wall-clock deadline against a tight interpreter loop. */
  double overshoot[4] = {0};
  {
    const double deadlines[] = {1, 10, 100, 500};
    const char *source = "while(true) { }";
    for (int index = 0; index < 4; index++) {
      const double deadline = deadlines[index];
      Observation observation =
          observe(rt, ctx, &interrupt, source, deadline, 0);
      overshoot[index] = observation.ms - deadline;
      case_boundary();
      emit_case("cpuLoopDeadline", source, deadline, 0, &observation,
                "uncatchable InternalError: interrupted at the deadline",
                is_interrupted(&observation) && observation.fired);
      char label[96];
      snprintf(label, sizeof(label), "cpuLoopInterruptedAt%gMs", deadline);
      record(label, is_interrupted(&observation) && observation.fired);
      snprintf(label, sizeof(label), "cpuLoopOvershootAt%gMsUnder10Ms", deadline);
      // 10 ms, not 2 ms: this bound catches an engine whose deadline never fires
      // (which overshoots by hundreds of milliseconds — see the heavy-loop rows)
      // without failing on a shared CI runner's scheduling noise. macOS run
      // 35992076835 went red here with the row's own numbers still in the band
      // the evidence records; the exact overshoot stays in the case JSON either
      // way, so widening this gate loses no observation.
      record(label, observation.ms - deadline < 10.0);
    }
  }

  /* 2. A script cannot swallow the deadline error and keep running. */
  {
    const char *source =
        "var caught = 0; try { while(true) caught++; } catch (e) { caught = "
        "99; } caught";
    Observation observation =
        observe(rt, ctx, &interrupt, source, 50, 0);
    case_boundary();
    emit_case("deadlineUncatchable", source, 50, 0, &observation,
              "the try/catch block cannot swallow the deadline error",
              is_interrupted(&observation));
    record("deadlineUncatchable", is_interrupted(&observation));
  }

  /* 3. Control: without a deadline the same shape of loop is left alone. */
  {
    const char *source =
        "var sum = 0; for (var i = 0; i < 5000000; i++) sum += i; sum > 0";
    Observation observation = observe(rt, ctx, &interrupt, source, 0, 0);
    case_boundary();
    emit_case("noDeadlineControl", source, 0, 0, &observation,
              "no deadline means no interruption",
              !observation.threw && strcmp(observation.value, "true") == 0);
    record("noDeadlineControl", !observation.threw &&
                                    strcmp(observation.value, "true") == 0);
  }

  /* 4. A catastrophically backtracking regular expression. */
  {
    const char *source = "/(a+)+$/.test('a'.repeat(64) + '!')";
    Observation observation =
        observe(rt, ctx, &interrupt, source, 200, 0);
    case_boundary();
    emit_case("regexBacktrackingDeadline", source, 200, 0, &observation,
              "libregexp polls the same handler",
              is_interrupted(&observation));
    record("regexBacktrackingInterrupted", is_interrupted(&observation));
    record("regexBacktrackingOvershootUnder10Ms", observation.ms - 200 < 10.0);
  }

  /* 5. Allocation-heavy loops and large string building. */
  {
    const char *source =
        "(function() { var blocks = []; while(true) { blocks.push(new "
        "Array(1024).fill(7)); } })()";
    Observation observation =
        observe(rt, ctx, &interrupt, source, 100, 0);
    case_boundary();
    emit_case("allocationLoopDeadline", source, 100, 0, &observation,
              "allocation-heavy execution reaches the deadline eventually",
              is_interrupted(&observation));
    record("allocationLoopInterrupted", is_interrupted(&observation));
  }
  {
    const char *source =
        "(function() { var text = ''; while(true) { text += 'abcdefghij'; } "
        "})()";
    Observation observation =
        observe(rt, ctx, &interrupt, source, 100, 0);
    case_boundary();
    emit_case("stringBuilderDeadline", source, 100, 0, &observation,
              "string building reaches the deadline",
              is_interrupted(&observation));
    record("stringBuilderInterrupted", is_interrupted(&observation));
  }

  /* 6. The poll quantum is 10000 interpreter polls, so the overshoot grows
   * with the native cost of one loop iteration. This body allocates a fixed
   * 50 KB string per iteration. */
  double heavy_overshoot = 0;
  {
    const char *source = "while(true) { 'x'.repeat(50000); }";
    Observation observation =
        observe(rt, ctx, &interrupt, source, 100, 0);
    heavy_overshoot = observation.ms - 100;
    case_boundary();
    emit_case("heavyLoopBodyDeadline", source, 100, 0, &observation,
              "measure the overshoot with a native-heavy loop body",
              is_interrupted(&observation));
    record("heavyLoopBodyInterrupted", is_interrupted(&observation));
    record("heavyLoopBodyOvershootExceedsDeadline", heavy_overshoot > 100);
  }

  /* 7. One long native call performs no interpreter polls at all. */
  double single_call_ms = 0;
  {
    const char *source = "'y'.repeat(104857600).length";
    Observation observation = observe(rt, ctx, &interrupt, source, 100, 0);
    single_call_ms = observation.ms;
    case_boundary();
    emit_case("singleNativeCallDeadline", source, 100, 0, &observation,
              "measure whether one long C-level call can pass the deadline",
              !observation.threw);
    record("singleNativeCallCompletedWithoutInterrupt", !observation.threw);
    record("singleNativeCallPassedDeadlineWithoutPolls",
           !observation.threw && observation.polls == 0 &&
               observation.ms > 100);
  }

  /* 8. Heap limit: a retained-allocation loop fails with a JS error. The
   * allocator must start below the limit, so earlier garbage is collected. */
  const size_t heap_limit = 8 * mib;
  bool heap_limit_catchable = false;
  bool runtime_usable_after = false;
  bool allocator_inside_limit = false;
  bool heap_reclaimed = false;
  double oom_retry_ms = 0;
  {
    JS_RunGC(rt);
    JSMemoryUsage baseline;
    JS_ComputeMemoryUsage(rt, &baseline);
    Observation base;
    memset(&base, 0, sizeof(base));
    base.malloc_size = (size_t)baseline.malloc_size;
    base.malloc_limit = (size_t)baseline.malloc_limit;
    base.memory_used = (size_t)baseline.memory_used_size;
    base.obj_count = (long)baseline.obj_count;
    case_boundary();
    emit_case("heapLimitBaseline", "(GC only)", 0, heap_limit, &base,
              "the allocator is below the limit before the limit is tested",
              base.malloc_size < heap_limit);
    record("heapLimitStartsBelowLimit", base.malloc_size < heap_limit);
  }
  {
    const char *source =
        "(function() { var blocks = []; var text = null; try { while(true) "
        "blocks.push(new Array(4096).fill(7)); } catch (e) { text = e.name + "
        "': ' + e.message; } return text; })()";
    Observation observation =
        observe(rt, ctx, &interrupt, source, 0, heap_limit);
    case_boundary();
    emit_case("heapLimitCatchable", source, 0, heap_limit, &observation,
              "the heap limit surfaces as a catchable out-of-memory error",
              !observation.threw &&
                  strstr(observation.value, "out of memory") != NULL);
    heap_limit_catchable =
        !observation.threw && strstr(observation.value, "out of memory");
    record("heapLimitCatchable", heap_limit_catchable);
  }
  {
    const char *source = "6 * 7";
    Observation observation =
        observe(rt, ctx, &interrupt, source, 0, heap_limit);
    case_boundary();
    emit_case("runtimeUsableAfterHeapLimit", source, 0, heap_limit, &observation,
              "the same runtime evaluates again after an out-of-memory error",
              !observation.threw && strcmp(observation.value, "42") == 0);
    runtime_usable_after =
        !observation.threw && strcmp(observation.value, "42") == 0;
    allocator_inside_limit = observation.malloc_size <= heap_limit;
    record("runtimeUsableAfterHeapLimit", runtime_usable_after);
    record("allocatorStayedInsideLimit", allocator_inside_limit);
  }
  {
    const char *source = "true";
    Observation observation =
        observe(rt, ctx, &interrupt, source, 0, heap_limit);
    case_boundary();
    emit_case("heapReclaimedAfterGc", source, 0, heap_limit, &observation,
              "the retained blocks are reclaimed once the script drops them",
              observation.malloc_size < heap_limit / 2);
    heap_reclaimed = observation.malloc_size < heap_limit / 2;
    record("heapReclaimedAfterGc", heap_reclaimed);
  }

  /* 9. Catching the out-of-memory error cannot buy more heap, but the retry
   * loop still runs far past its deadline: every failed allocation retries
   * garbage collection before the next interpreter poll. */
  {
    const char *source =
        "(function() { var retries = 0; var last = null; for (;;) { try { "
        "last = new Array(200000).fill(0); } catch (e) { retries++; } } })()";
    Observation observation =
        observe(rt, ctx, &interrupt, source, 300, heap_limit);
    oom_retry_ms = observation.ms;
    case_boundary();
    emit_case("heapLimitUnescapable", source, 300, heap_limit, &observation,
              "the retry loop cannot exceed the budget, and stops at the "
              "deadline",
              is_interrupted(&observation));
    record("heapLimitUnescapable", is_interrupted(&observation));
  }

  /* 10. Single oversized allocations of both flavors. */
  {
    const char *source = "'x'.repeat(268435456)";
    Observation observation =
        observe(rt, ctx, &interrupt, source, 0, heap_limit);
    case_boundary();
    emit_case("hugeStringOverLimit", source, 0, heap_limit, &observation,
              "one oversized string fails with a JS error, not an abort",
              observation.threw &&
                  strstr(observation.exception, "out of memory") != NULL);
    record("hugeStringOverLimit",
           observation.threw &&
               strstr(observation.exception, "out of memory") != NULL);
  }
  {
    const char *source = "new Uint8Array(67108864)";
    Observation observation =
        observe(rt, ctx, &interrupt, source, 0, heap_limit);
    case_boundary();
    emit_case("hugeTypedArrayOverLimit", source, 0, heap_limit, &observation,
              "one oversized typed array fails with a JS error",
              observation.threw &&
                  strstr(observation.exception, "out of memory") != NULL);
    record("hugeTypedArrayOverLimit",
           observation.threw &&
               strstr(observation.exception, "out of memory") != NULL);
  }

  /* 11. Memory pressure without a limit still completes. */
  {
    const char *source =
        "(function() { var blocks = []; for (var i = 0; i < 4000; i++) "
        "blocks.push(new Array(1024).fill(i)); return blocks.length; })()";
    Observation observation = observe(rt, ctx, &interrupt, source, 0, 0);
    case_boundary();
    emit_case("unlimitedHeapControl", source, 0, 0, &observation,
              "without a limit the same work completes",
              !observation.threw && strcmp(observation.value, "4000") == 0);
    record("unlimitedHeapControl",
           !observation.threw && strcmp(observation.value, "4000") == 0);
  }

  printf("\n  ],\n");
  printf("  \"findings\": {\n");
  printf("    \"heapLimitEnforced\": %s,\n",
         (heap_limit_catchable && runtime_usable_after &&
          allocator_inside_limit && heap_reclaimed)
             ? "true"
             : "false");
  printf("    \"deadlineInterruptsInterpreterWork\": %s,\n",
         overshoot[0] < 2.0 && overshoot[1] < 2.0 && overshoot[2] < 2.0 &&
                 overshoot[3] < 2.0
             ? "true"
             : "false");
  printf("    \"deadlineIsHardBound\": false,\n");
  printf("    \"deadlineHeavyLoopBodyOvershootMs\": %.1f,\n", heavy_overshoot);
  printf("    \"deadlineOomRetryOvershootMs\": %.1f,\n", oom_retry_ms - 300);
  printf("    \"deadlineSingleNativeCallMeasuredMs\": %.1f,\n", single_call_ms);
  printf("    \"deadlineSingleNativeCallInterrupted\": false\n");
  printf("  },\n");
  printf("  \"checks\": {");
  for (int index = 0; index < check_count; index++) {
    if (index) printf(", ");
    print_json_string(checks[index].name);
    printf(": %s", checks[index].passed ? "true" : "false");
  }
  bool all_passed = true;
  for (int index = 0; index < check_count; index++) {
    if (!checks[index].passed) all_passed = false;
  }
  printf("},\n  \"status\": \"%s\"\n}\n", all_passed ? "pass" : "fail");

  JS_FreeContext(ctx);
  JS_FreeRuntime(rt);
  return all_passed ? 0 : 1;
}
