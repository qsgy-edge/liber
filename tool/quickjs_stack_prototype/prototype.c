/* THROWAWAY Windows feasibility probe. Includes the exact pinned engine so
 * suspended native frames can be detached from JSRuntime's private state.
 * This is NOT a replacement for fjs or an approved production patch. */
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <windows.h>
#include "quickjs.c"

#define LIMIT 32
#define SCRIPT_LIMIT (1024 * 1024)
typedef struct Suspended {
    JSStackFrame *frame;
    uintptr_t top, limit;
    JSValue exception;
    bool out_of_memory, building_trace;
    JSValueLink *parent_promise;
} Suspended;
typedef struct Task {
    int id, done, cancelled;
    LPVOID fiber;
    SOCKET socket;
    char *source, *json;
    int error, interrupt_calls;
    ULONGLONG deadline;
    Suspended state;
} Task;
static JSRuntime *runtime;
static JSContext *context;
static LPVOID scheduler;
static Task *active;
static Task tasks[LIMIT];
static int server_port;
static int restore_private_state = 1;

static void save_state(Suspended *s) {
    s->frame=runtime->current_stack_frame;
    s->top=runtime->stack_top; s->limit=runtime->stack_limit;
    s->exception=runtime->current_exception;
    s->out_of_memory=runtime->in_out_of_memory;
    s->building_trace=runtime->in_build_stack_trace;
    s->parent_promise=runtime->parent_promise;
    runtime->current_exception=JS_NULL;
    runtime->current_stack_frame=NULL;
    runtime->in_out_of_memory=false;
    runtime->in_build_stack_trace=false;
    runtime->parent_promise=NULL;
}
static void load_state(Suspended *s) {
    if(restore_private_state) runtime->current_stack_frame=s->frame;
    runtime->stack_top=s->top; runtime->stack_limit=s->limit;
    runtime->current_exception=s->exception; s->exception=JS_NULL;
    runtime->in_out_of_memory=s->out_of_memory;
    runtime->in_build_stack_trace=s->building_trace;
    runtime->parent_promise=s->parent_promise;
}
static void suspend_task(void) {
    Task *self=active;
    save_state(&self->state);
    active=NULL;
    SwitchToFiber(scheduler);
    /* resume() restores private runtime state before switching here. */
}
static int interrupt(JSRuntime *rt, void *opaque) {
    (void)rt; (void)opaque;
    if(active) active->interrupt_calls++;
    if(active && active->deadline && GetTickCount64()>=active->deadline)
        active->cancelled=1;
    return active && active->cancelled;
}
static JSValue ajax(JSContext *ctx, JSValueConst self, int argc, JSValueConst *argv) {
    (void)self;
    if(!active || argc!=1) return JS_ThrowInternalError(ctx,"No active request");
    const char *url=JS_ToCString(ctx,argv[0]);
    if(!url) return JS_EXCEPTION;
    char prefix[128]; snprintf(prefix,sizeof(prefix),"http://127.0.0.1:%d",server_port);
    size_t prefix_len=strlen(prefix);
    if(strncmp(url,prefix,prefix_len)!=0 || url[prefix_len]!='/') {
        JS_FreeCString(ctx,url); return JS_ThrowInternalError(ctx,"Only local replay allowed");
    }
    Task *owner=active;
    owner->socket=socket(AF_INET,SOCK_STREAM,IPPROTO_TCP);
    struct sockaddr_in addr={0}; addr.sin_family=AF_INET;
    addr.sin_port=htons((unsigned short)server_port); addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    DWORD timeout=5000;
    setsockopt(owner->socket,SOL_SOCKET,SO_RCVTIMEO,(const char*)&timeout,sizeof(timeout));
    if(connect(owner->socket,(struct sockaddr*)&addr,sizeof(addr))!=0) {
        JS_FreeCString(ctx,url); closesocket(owner->socket); owner->socket=INVALID_SOCKET;
        return JS_ThrowInternalError(ctx,"Replay connect failed");
    }
    char request[16384];
    int size=snprintf(request,sizeof(request),"GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nConnection: close\r\n\r\n",url+prefix_len,server_port);
    JS_FreeCString(ctx,url);
    if(size<0 || size>=(int)sizeof(request) || send(owner->socket,request,size,0)!=size)
        return JS_ThrowInternalError(ctx,"Replay write failed");
    printf("{\"type\":\"waiting\",\"id\":%d}\n",owner->id); fflush(stdout);
    suspend_task();
    if(owner->cancelled) {
        closesocket(owner->socket); owner->socket=INVALID_SOCKET;
        return JS_ThrowInternalError(ctx,"Execution cancelled");
    }
    char response[65536]; int length=0, got;
    while(length<(int)sizeof(response)-1 && (got=recv(owner->socket,response+length,sizeof(response)-1-length,0))>0) length+=got;
    closesocket(owner->socket); owner->socket=INVALID_SOCKET;
    response[length]=0;
    char *body=strstr(response,"\r\n\r\n");
    if(!body) return JS_ThrowInternalError(ctx,"Replay response missing");
    if(!strcmp(body+4,"__trace__")) return JS_NewError(ctx);
    return JS_NewString(ctx,body+4);
}
static char *json_value(JSValueConst value) {
    JSValue encoded=JS_JSONStringify(context,value,JS_UNDEFINED,JS_UNDEFINED);
    if(JS_IsException(encoded)) {JSValue e=JS_GetException(context);JS_FreeValue(context,e);return strdup("null");}
    if(JS_IsUndefined(encoded)) return strdup("null");
    const char *text=JS_ToCString(context,encoded);
    char *copy=strdup(text?text:"null");
    if(text) JS_FreeCString(context,text);
    JS_FreeValue(context,encoded);
    return copy;
}
static VOID WINAPI execute(LPVOID parameter) {
    Task *task=parameter;
    JS_UpdateStackTop(runtime);
    JSValue value=JS_Eval(context,task->source,strlen(task->source),"prototype-rule.js",JS_EVAL_TYPE_GLOBAL);
    task->error=JS_IsException(value);
    if(task->error) value=JS_GetException(context);
    if(task->error) {
        const char *message=JS_ToCString(context,value);
        JSValue text=JS_NewString(context,message?message:"exception");
        task->json=json_value(text);JS_FreeValue(context,text);
        if(message) JS_FreeCString(context,message);
    } else task->json=json_value(value);
    JS_FreeValue(context,value);
    task->done=1;
    printf("{\"type\":\"done\",\"id\":%d,\"cancelled\":%s,\"error\":%s,\"interruptCalls\":%d,\"value\":%s}\n",task->id,task->cancelled?"true":"false",task->error?"true":"false",task->interrupt_calls,task->json);
    fflush(stdout);
    suspend_task();
    abort();
}
static void resume_task(Task *task) {
    Suspended main_state;
    save_state(&main_state);
    load_state(&task->state);
    active=task;
    SwitchToFiber(task->fiber);
    active=NULL;
    load_state(&main_state);
}
static void destroy(Task *task) {
    if(task->fiber) DeleteFiber(task->fiber);
    if(task->socket!=INVALID_SOCKET) closesocket(task->socket);
    JS_FreeValue(context,task->state.exception);
    free(task->source);free(task->json);
    memset(task,0,sizeof(*task));task->socket=INVALID_SOCKET;
}
int main(int argc,char **argv) {
    if(argc<2) return 2;
    server_port=atoi(argv[1]);
    if(argc>2) restore_private_state=0;
    WSADATA data;if(WSAStartup(MAKEWORD(2,2),&data))return 3;
    scheduler=ConvertThreadToFiberEx(NULL,FIBER_FLAG_FLOAT_SWITCH);
    if(!scheduler)return 4;
    runtime=JS_NewRuntime();context=JS_NewContext(runtime);
    JS_SetMaxStackSize(runtime,512*1024);
    JS_SetMemoryLimit(runtime,32*1024*1024);
    JS_SetInterruptHandler(runtime,interrupt,NULL);
    JSValue global=JS_GetGlobalObject(context), java=JS_NewObject(context);
    JS_SetPropertyStr(context,java,"ajax",JS_NewCFunction(context,ajax,"ajax",1));
    JS_SetPropertyStr(context,global,"java",java);JS_FreeValue(context,global);
    for(int i=0;i<LIMIT;i++) tasks[i].socket=INVALID_SOCKET;
    printf("{\"type\":\"ready\"}\n");fflush(stdout);
    char *line=malloc(SCRIPT_LIMIT+128);
    int exit_status=0;
    while(fgets(line,SCRIPT_LIMIT+128,stdin)) {
        line[strcspn(line,"\r\n")]=0;
        if(!strcmp(line,"quit"))break;
        if(!strcmp(line,"gc")) {JS_RunGC(runtime);puts("{\"type\":\"gc\"}");fflush(stdout);continue;}
        char *op=strtok(line,"\t"), *number=strtok(NULL,"\t");
        if(!op||!number){exit_status=5;break;}
        int id=atoi(number);if(id<0||id>=LIMIT){exit_status=5;break;}
        Task *task=&tasks[id];
        if(!strcmp(op,"drop")) {
            if(!task->done){exit_status=6;break;}
            destroy(task);puts("{\"type\":\"dropped\"}");fflush(stdout);continue;
        }
        if(!strcmp(op,"start")) {
            char *duration=strtok(NULL,"\t"),*source=strtok(NULL,"");
            if(task->fiber||!duration||!source){exit_status=7;break;}
            JSValue parsed=JS_ParseJSON(context,source,strlen(source),"command.json");
            const char *decoded=JS_ToCString(context,parsed);
            if(JS_IsException(parsed)||!decoded){exit_status=10;break;}
            task->id=id;task->source=strdup(decoded);task->state.exception=JS_NULL;
            JS_FreeCString(context,decoded);JS_FreeValue(context,parsed);
            task->deadline=atoi(duration)?GetTickCount64()+atoi(duration):0;
            task->fiber=CreateFiberEx(64*1024,4*1024*1024,FIBER_FLAG_FLOAT_SWITCH,execute,task);
            if(!task->fiber){exit_status=8;break;}
        }else if(!task->fiber||task->done){exit_status=9;break;}
        if(!strcmp(op,"cancel"))task->cancelled=1;
        resume_task(task);
    }
    for(int i=0;i<LIMIT;i++) {
        if(tasks[i].fiber&&!tasks[i].done) {tasks[i].cancelled=1;resume_task(&tasks[i]);}
        destroy(&tasks[i]);
    }
    free(line);JS_RunGC(runtime);JS_FreeContext(context);JS_FreeRuntime(runtime);
    ConvertFiberToThread();WSACleanup();
    return exit_status;
}
