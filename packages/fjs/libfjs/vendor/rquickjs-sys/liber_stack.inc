/* Liber extension; compiled inside the pinned quickjs.c translation unit.
 * Single-thread stack detachment only. No runtime/context may outlive its state. */
typedef struct LiberStackState {
    struct JSStackFrame *frame;
    uintptr_t top, limit;
    JSValue exception;
    bool out_of_memory, building_trace;
    JSValueLink *parent_promise;
} LiberStackState;
void *liber_stack_new(void) {
    LiberStackState *state = calloc(1, sizeof(*state));
    if (state) state->exception = JS_NULL;
    return state;
}
void liber_stack_capture(JSRuntime *rt, void *opaque) {
    LiberStackState *s = opaque;
    s->frame=rt->current_stack_frame;
    s->top=rt->stack_top; s->limit=rt->stack_limit;
    s->exception=rt->current_exception;
    s->out_of_memory=rt->in_out_of_memory;
    s->building_trace=rt->in_build_stack_trace;
    s->parent_promise=rt->parent_promise;
    rt->current_stack_frame=NULL; rt->current_exception=JS_NULL;
    rt->in_out_of_memory=false; rt->in_build_stack_trace=false;
    rt->parent_promise=NULL;
}
void liber_stack_restore(JSRuntime *rt, void *opaque) {
    LiberStackState *s = opaque;
    rt->current_stack_frame=s->frame;
    rt->stack_top=s->top; rt->stack_limit=s->limit;
    rt->current_exception=s->exception; s->exception=JS_NULL;
    rt->in_out_of_memory=s->out_of_memory;
    rt->in_build_stack_trace=s->building_trace;
    rt->parent_promise=s->parent_promise;
}
void liber_stack_free(JSRuntime *rt, void *opaque) {
    LiberStackState *s=opaque;
    if(s){JS_FreeValueRT(rt,s->exception); free(s);}
}
