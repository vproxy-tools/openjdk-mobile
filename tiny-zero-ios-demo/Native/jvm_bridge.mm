#include "jvm_bridge.h"

#include <jni.h>

#include <cstdarg>
#include <pthread.h>

// Declared with C linkage at file scope: the SDK availability guards vary
// between macOS/iOS SDK generations.
extern "C" void pthread_jit_write_protect_np(int enabled) __API_AVAILABLE(macos(11.0), ios(14.0));

// Declared here: the SDK guards it behind availability macros that vary
// between macOS/iOS SDK generations.
extern "C" void pthread_jit_write_protect_np(int enabled) __API_AVAILABLE(macos(11.0), ios(14.0));
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <unistd.h>

namespace {

JavaVM *g_vm = nullptr;
pthread_t g_thread = 0;
volatile bool g_running = false;
tinyvm_log_fn g_log_fn = nullptr;
tinyvm_exit_fn g_exit_fn = nullptr;
char g_err[512] = {0};

struct StartArgs {
  char runtime_home[1024];
  char jar_path[1024];
  char port[16];
};

void report_error(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void report_error(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(g_err, sizeof(g_err), fmt, ap);
  va_end(ap);
}

void forward_log(const char *line) {
  if (g_log_fn != nullptr && line != nullptr) {
    g_log_fn(line);
  }
}

}  // namespace

// Called from Java via JNI: TinyHttpServer.nativeLog(String).
// Must have external C linkage or the JNI lookup by name fails.
extern "C" JNIEXPORT void JNICALL Java_TinyHttpServer_nativeLog(JNIEnv *env, jclass cls, jstring line) {
  (void)cls;
  if (line == nullptr) {
    return;
  }
  const char *utf = env->GetStringUTFChars(line, nullptr);
  if (utf != nullptr) {
    forward_log(utf);
    env->ReleaseStringUTFChars(line, utf);
  }
}

namespace {

void *jvm_thread_main(void *arg) {
  StartArgs args = *static_cast<StartArgs *>(arg);
  delete static_cast<StartArgs *>(arg);

  // Align the real per-thread MAP_JIT protection with what the server W^X
  // healing assumes as its initial state (_jit_exec_enabled == false, i.e.
  // write-enabled): on macOS 26 the system default is write-protected, and
  // the healing's own enable/disable calls are compiled out for iOS targets
  // unless patched for the simulator (see support/build-sim-jvm.sh).
  pthread_jit_write_protect_np(0);

  // NOTE: -Djava.home is deliberately NOT passed: hotspot's os_bsd.cpp
  // (__IOS__ + statically linked) derives java_home = <executable dir>/lib
  // and overrides the property, so the runtime image must simply be placed
  // at <bundle>/lib/lib/modules.
  (void)args.runtime_home;
  JavaVMOption options[15];
  std::string cp = std::string("-Djava.class.path=") + args.jar_path;
  options[0].optionString = const_cast<char *>(cp.c_str());
  options[1].optionString = const_cast<char *>("-Xrs");
  options[2].optionString = const_cast<char *>("-Djava.awt.headless=true");
  // Match the Tiny Zero device configuration (SerialGC); the default G1
  // hits a ShouldNotCall() in the Zero signal path during early VM init.
  options[3].optionString = const_cast<char *>("-XX:+UseSerialGC");
  // Interpreter only: the JIT compiler threads writing the code cache race
  // with the lazy per-thread W^X flipping; -Xint removes that concurrency
  // while validating the embedding.
  options[4].optionString = const_cast<char *>("-Xint");
  // Explicit null checks in generated code: implicit (SIGSEGV-based) null
  // checks cannot be recovered on the Darwin zero/simulator signal paths.
  options[5].optionString = const_cast<char *>("-XX:+UnlockDiagnosticVMOptions");
  options[6].optionString = const_cast<char *>("-XX:-ImplicitNullChecks");
  // Compact object headers change the object header layout used by the
  // generated vtable/type-check stubs; keep the classic layout while
  // validating the simulator embedding.
  options[7].optionString = const_cast<char *>("-XX:-UseCompactObjectHeaders");
  // The runtime image was produced without a CDS archive; make sure the
  // sharing machinery stays off so method entry state is linked normally.
  options[8].optionString = const_cast<char *>("-Xshare:off");
  // Bootstrap on the zero interpreter allocates heavily before VM init
  // completes; a larger young gen avoids "GC triggered before VM
  // initialization completed".
  options[9].optionString = const_cast<char *>("-Xms4g");
  // The zero interpreter recurses through C++ frames per Java call; deep
  // <clinit> chains during bootstrap overflow the default stack.
  options[10].optionString = const_cast<char *>("-Xss32m"); // zero recurses per Java call
  // Bootstrap on this port cannot fill stack traces yet (backtrace fields
  // are null before the stack machinery initializes); disable collection.
  options[11].optionString = const_cast<char *>("-XX:-StackTraceInThrowable");
  // Avoid mixing rewritten and non-rewritten bytecode states across the
  // on-demand linking during bootstrap.
  options[12].optionString = const_cast<char *>("-XX:-RewriteBytecodes");
  options[13].optionString = const_cast<char *>("-XX:NewSize=1536m");
  // No attach mechanism in the demo; avoids the ".java_pidNNN: file name is
  // too long" warning in the deep simulator sandbox path.
  options[14].optionString = const_cast<char *>("-XX:+DisableAttachMechanism");
  JavaVMInitArgs vm_args = {};
  vm_args.version = JNI_VERSION_1_8;
  vm_args.nOptions = 15;
  vm_args.options = options;
  vm_args.ignoreUnrecognized = JNI_FALSE;

  JNIEnv *env = nullptr;
  jint rc = JNI_CreateJavaVM(&g_vm, reinterpret_cast<void **>(&env), &vm_args);
  if (rc != JNI_OK) {
    report_error("JNI_CreateJavaVM failed with %d", rc);
    if (g_exit_fn) g_exit_fn(1, g_err);
    g_running = false;
    return nullptr;
  }
  forward_log("[native] JVM created (Zero, java.home set)");

  jclass clazz = env->FindClass("TinyHttpServer");
  if (clazz == nullptr) {
    env->ExceptionClear();
    report_error("FindClass(TinyHttpServer) failed; jar on java.class.path?");
    if (env->ExceptionCheck()) env->ExceptionDescribe();
    g_vm->DestroyJavaVM();
    g_vm = nullptr;
    if (g_exit_fn) g_exit_fn(1, g_err);
    g_running = false;
    return nullptr;
  }

  // Application classes resolve natives through their class loader (the
  // Java ClassLoader.findNative path), which finds nothing in a fully
  // static build; register the bridge's native method explicitly.
  {
    JNINativeMethod method;
    method.name = const_cast<char*>("nativeLog");
    method.signature = const_cast<char*>("(Ljava/lang/String;)V");
    method.fnPtr = reinterpret_cast<void*>(&Java_TinyHttpServer_nativeLog);
    if (env->RegisterNatives(clazz, &method, 1) != JNI_OK) {
      report_error("RegisterNatives(nativeLog) failed");
      env->ExceptionClear();
    }
  }

  jmethodID main = env->GetStaticMethodID(clazz, "main", "([Ljava/lang/String;)V");
  if (main == nullptr) {
    report_error("GetStaticMethodID(main) failed");
    g_vm->DestroyJavaVM();
    g_vm = nullptr;
    if (g_exit_fn) g_exit_fn(1, g_err);
    g_running = false;
    return nullptr;
  }

  jclass stringClass = env->FindClass("java/lang/String");
  jobjectArray jargs = env->NewObjectArray(1, stringClass, nullptr);
  env->SetObjectArrayElement(jargs, 0, env->NewStringUTF(args.port));

  env->CallStaticVoidMethod(clazz, main, jargs);
  if (env->ExceptionCheck()) {
    report_error("TinyHttpServer.main threw an exception (see log above)");
    env->ExceptionDescribe();
    env->ExceptionClear();
  }

  g_vm->DestroyJavaVM();
  g_vm = nullptr;
  forward_log("[native] JVM destroyed");
  g_running = false;
  if (g_exit_fn) g_exit_fn(0, "main returned");
  return nullptr;
}

}  // namespace

extern "C" int tinyvm_start(const char *runtime_home, const char *jar_path, int port,
                            tinyvm_log_fn log_fn, tinyvm_exit_fn exit_fn) {
  if (g_running) {
    report_error("JVM already running");
    return 1;
  }
  if (runtime_home == nullptr || jar_path == nullptr) {
    report_error("null argument");
    return 1;
  }

  g_err[0] = '\0';
  g_log_fn = log_fn;
  g_exit_fn = exit_fn;

  StartArgs *args = new StartArgs();
  snprintf(args->runtime_home, sizeof(args->runtime_home), "%s", runtime_home);
  snprintf(args->jar_path, sizeof(args->jar_path), "%s", jar_path);
  snprintf(args->port, sizeof(args->port), "%d", port);

  g_running = true;
  if (pthread_create(&g_thread, nullptr, jvm_thread_main, args) != 0) {
    report_error("pthread_create failed");
    g_running = false;
    return 1;
  }
  return 0;
}

extern "C" int tinyvm_stop(int timeout_seconds) {
  if (!g_running || g_vm == nullptr) {
    return 0;
  }
  // Stop without any program cooperation: call System.exit(0) from the
  // host, like sending SIGTERM-friendly termination to a regular java
  // process. java.lang.System is a bootstrap class, so FindClass works from
  // any attached thread. System.exit runs shutdown hooks and then exits the
  // whole process (vm_exit -> os::exit) — the embedding iOS app terminates
  // with it, which is the natural lifecycle for a plain Java program.
  // Zero program assumptions, single graceful stage: System.exit(0) is the
  // whole stop mechanism (java.lang.System is a bootstrap class, visible
  // from any attached thread; on a complete JVM this exits the process
  // together with its shutdown hooks). The host only observes: if the
  // upstream exit path stalls it reports an error and never forces.
  // Stage 1 runs on its own thread: this mobile snapshot's exit path can
  // deadlock the calling thread inside Runtime.exit (logging), so the stop
  // flow must not wait on that call returning.
  forward_log("[native] stop: stage 1 System.exit(0)");
  pthread_t exit_thread;
  pthread_create(&exit_thread, nullptr, [](void*) -> void* {
    JNIEnv *env = nullptr;
    if (g_vm != nullptr && g_vm->AttachCurrentThread(reinterpret_cast<void **>(&env), nullptr) == JNI_OK) {
      jclass system = env->FindClass("java/lang/System");
      if (system != nullptr) {
        jmethodID exit = env->GetStaticMethodID(system, "exit", "(I)V");
        if (exit != nullptr) {
          env->CallStaticVoidMethod(system, exit, 0);
        }
      }
      if (env->ExceptionCheck()) {
        env->ExceptionDescribe();
        env->ExceptionClear();
      }
      g_vm->DetachCurrentThread();
    }
    return nullptr;
  }, nullptr);
  pthread_detach(exit_thread);

  // Observe, never force: a healthy System.exit removes the whole process
  // before this loop finishes. If the upstream exit path stalls (see README
  // §6: intermittent, not reproducible on the current build), report and
  // leave the process alive — the user closes the app manually.
  for (int i = 0; i < timeout_seconds * 10 && g_running; i++) {
    usleep(100 * 1000);
  }
  if (g_running) {
    report_error("System.exit did not complete within %ds (upstream exit-path stall)", timeout_seconds);
    return 1;
  }
  return 0;
}

extern "C" bool tinyvm_is_running(void) { return g_running; }

extern "C" const char *tinyvm_last_error(void) { return g_err; }
