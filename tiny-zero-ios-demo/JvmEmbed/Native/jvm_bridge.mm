#include "jvm_bridge.h"

#include <jni.h>

#include <algorithm>
#include <cstdarg>
#include <pthread.h>
#include <string>
#include <vector>

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

// Defined by the generated symbol_keeper.cpp inside libtinyjvm.a.
extern "C" void tiny_symbol_keeper_anchor();

// Defined below the anonymous namespace; referenced by jvm_thread_main.
extern "C" JNIEXPORT void JNICALL Java_IosBootstrap_nativeLog(JNIEnv *env, jclass cls, jstring line);

namespace {

JavaVM *g_vm = nullptr;
pthread_t g_thread = 0;
volatile bool g_running = false;
tinyvm_log_fn g_log_fn = nullptr;
tinyvm_exit_fn g_exit_fn = nullptr;
char g_err[512] = {0};

struct StartArgs {
  std::string jar_paths;
  std::string user_home;
  std::string main_class;  // slash form
  std::vector<std::string> program_args;
  std::vector<std::string> extra_vm_options;
};

// pthread_jit_write_protect_np exists only in the macOS/simulator libsystem
// (the SDK headers mark it unavailable for iOS), so it is resolved at
// runtime like the merged signals_posix lazy W^X fix does: the real function
// runs on the simulator; on a real device it is absent (null) and skipped,
// which is correct — devices have no MAP_JIT pages to align.
void align_thread_wx_state() {
  typedef int (*jit_protect_fn)(int);
  static jit_protect_fn fn =
      reinterpret_cast<jit_protect_fn>(dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np"));
  if (fn != nullptr) {
    fn(0);
  }
}

void vreport_error(const char *fmt, va_list ap) {
  vsnprintf(g_err, sizeof(g_err), fmt, ap);
}

void report_error(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void report_error(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vreport_error(fmt, ap);
  va_end(ap);
}

void forward_log(const char *line) {
  if (g_log_fn != nullptr && line != nullptr) {
    g_log_fn(line);
  }
}

// Failure path of the JVM thread: fill the error buffer, tear down a
// partially created VM, and run the exit callback.
void *jvm_fail(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void *jvm_fail(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vreport_error(fmt, ap);
  va_end(ap);
  if (g_vm != nullptr) {
    g_vm->DestroyJavaVM();
    g_vm = nullptr;
  }
  g_running = false;
  if (g_exit_fn) g_exit_fn(1, g_err);
  return nullptr;
}

void *jvm_thread_main(void *arg) {
  StartArgs args = *static_cast<StartArgs *>(arg);
  delete static_cast<StartArgs *>(arg);

  // Align the real per-thread MAP_JIT protection with what the W^X healing
  // assumes as its initial state (_jit_exec_enabled == false, i.e.
  // write-enabled): on macOS 26 the system default is write-protected, and
  // the healing's own enable/disable calls are compiled out for iOS targets.
  align_thread_wx_state();

  // NOTE: -Djava.home is deliberately NOT passed: hotspot's os_bsd.cpp
  // (__IOS__ + statically linked) derives java_home = <executable dir>/lib
  // and overrides the property, so the runtime image must simply be placed
  // at <bundle>/lib/lib/modules.
  std::vector<std::string> opts;
  opts.push_back("-Djava.class.path=" + args.jar_paths);
  opts.push_back("-Duser.home=" + args.user_home);
  opts.push_back("-Xrs");
  opts.push_back("-Djava.awt.headless=true");
  // SerialGC matches the Tiny Zero configuration; the default G1 hits a
  // ShouldNotCall() in the Zero signal path during early VM init.
  opts.push_back("-XX:+UseSerialGC");
  // Interpreter only: JIT compiler threads writing the code cache race with
  // the lazy per-thread W^X flipping.
  opts.push_back("-Xint");
  // SIGSEGV-based (implicit) null checks cannot be recovered on the Darwin
  // zero/simulator signal paths.
  opts.push_back("-XX:+UnlockDiagnosticVMOptions");
  opts.push_back("-XX:-ImplicitNullChecks");
  opts.push_back("-XX:-UseCompactObjectHeaders");
  // The runtime image was produced without a CDS archive.
  opts.push_back("-Xshare:off");
  // Bootstrap on the zero interpreter allocates heavily before VM init
  // completes; a larger young gen avoids "GC triggered before VM
  // initialization completed".
  opts.push_back("-Xms4g");
  opts.push_back("-XX:NewSize=1536m");
  // The zero interpreter recurses through C++ frames per Java call; deep
  // <clinit> chains during bootstrap overflow the default stack.
  opts.push_back("-Xss32m");
  // Avoid mixing rewritten and non-rewritten bytecode states across the
  // on-demand linking during bootstrap.
  opts.push_back("-XX:-RewriteBytecodes");
  // No attach mechanism; avoids the ".java_pidNNN: file name is too long"
  // warning in the deep simulator sandbox path.
  opts.push_back("-XX:+DisableAttachMechanism");
  for (const auto &o : args.extra_vm_options) {
    opts.push_back(o);
  }

  std::vector<JavaVMOption> options(opts.size());
  for (size_t i = 0; i < opts.size(); i++) {
    options[i].optionString = const_cast<char *>(opts[i].c_str());
  }
  JavaVMInitArgs vm_args = {};
  vm_args.version = JNI_VERSION_1_8;
  vm_args.nOptions = static_cast<jint>(options.size());
  vm_args.options = options.data();
  vm_args.ignoreUnrecognized = JNI_FALSE;

  JNIEnv *env = nullptr;
  jint rc = JNI_CreateJavaVM(&g_vm, reinterpret_cast<void **>(&env), &vm_args);
  if (rc != JNI_OK) {
    return jvm_fail("JNI_CreateJavaVM failed with %d", rc);
  }
  forward_log("[native] JVM created");

  // IosBootstrap: register nativeLog and redirect stdout/stderr, so
  // everything the JVM writes reaches the app UI. Without this step the JVM
  // would be completely silent. Application classes resolve natives through
  // their class loader (the Java ClassLoader.findNative path), which finds
  // nothing in a fully static build, so the bridge's native method is
  // registered explicitly.
  jclass boot = env->FindClass("IosBootstrap");
  if (boot == nullptr) {
    env->ExceptionClear();
    return jvm_fail("FindClass(IosBootstrap) failed; bootstrap jar on java.class.path?");
  }
  JNINativeMethod method;
  method.name = const_cast<char *>("nativeLog");
  method.signature = const_cast<char *>("(Ljava/lang/String;)V");
  method.fnPtr = reinterpret_cast<void *>(&Java_IosBootstrap_nativeLog);
  if (env->RegisterNatives(boot, &method, 1) != JNI_OK) {
    if (env->ExceptionCheck()) env->ExceptionDescribe();
    env->ExceptionClear();
    return jvm_fail("RegisterNatives(IosBootstrap.nativeLog) failed");
  }
  jmethodID redirect = env->GetStaticMethodID(boot, "redirect", "()V");
  if (redirect == nullptr) {
    env->ExceptionClear();
    return jvm_fail("GetStaticMethodID(IosBootstrap.redirect) failed");
  }
  env->CallStaticVoidMethod(boot, redirect);

  jclass clazz = env->FindClass(args.main_class.c_str());
  if (clazz == nullptr) {
    if (env->ExceptionCheck()) env->ExceptionDescribe();
    env->ExceptionClear();
    return jvm_fail("FindClass(%s) failed; jar on java.class.path?", args.main_class.c_str());
  }

  jmethodID main = env->GetStaticMethodID(clazz, "main", "([Ljava/lang/String;)V");
  if (main == nullptr) {
    env->ExceptionClear();
    return jvm_fail("GetStaticMethodID(%s.main) failed", args.main_class.c_str());
  }

  jclass stringClass = env->FindClass("java/lang/String");
  if (stringClass == nullptr) {
    env->ExceptionClear();
    return jvm_fail("FindClass(java/lang/String) failed");
  }
  jobjectArray jargs =
      env->NewObjectArray(static_cast<jsize>(args.program_args.size()), stringClass, nullptr);
  if (jargs == nullptr) {
    env->ExceptionClear();
    return jvm_fail("NewObjectArray(main args) failed");
  }
  for (size_t i = 0; i < args.program_args.size(); i++) {
    env->SetObjectArrayElement(jargs, static_cast<jsize>(i),
                               env->NewStringUTF(args.program_args[i].c_str()));
  }

  env->CallStaticVoidMethod(clazz, main, jargs);
  if (env->ExceptionCheck()) {
    env->ExceptionDescribe();
    env->ExceptionClear();
    return jvm_fail("%s.main threw an exception (see log above)", args.main_class.c_str());
  }

  g_vm->DestroyJavaVM();
  g_vm = nullptr;
  forward_log("[native] JVM destroyed");
  g_running = false;
  if (g_exit_fn) g_exit_fn(0, "main returned");
  return nullptr;
}

}  // namespace

// Called from Java via JNI: IosBootstrap.nativeLog(String).
// Must have external C linkage or the JNI lookup by name fails.
extern "C" JNIEXPORT void JNICALL Java_IosBootstrap_nativeLog(JNIEnv *env, jclass cls, jstring line) {
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

extern "C" int tinyvm_start(const char *jar_paths, const char *user_home,
                            const char *main_class, char **program_args, char **extra_vm_options,
                            tinyvm_log_fn log_fn, tinyvm_exit_fn exit_fn) {
  if (g_running) {
    report_error("JVM already running");
    return 1;
  }
  if (jar_paths == nullptr || user_home == nullptr || main_class == nullptr) {
    report_error("null argument");
    return 1;
  }

  g_err[0] = '\0';
  g_log_fn = log_fn;
  g_exit_fn = exit_fn;

  // Pull the generated symbol keeper (and with it every kept JNI/JIMAGE
  // symbol) into the final link: nothing inside the static archives
  // references the anchor, so this call is what makes a normal link
  // sufficient - no -all_load/-force_load.
  tiny_symbol_keeper_anchor();

  auto *args = new StartArgs();
  args->jar_paths = jar_paths;
  args->user_home = user_home;
  args->main_class = main_class;
  std::replace(args->main_class.begin(), args->main_class.end(), '.', '/');
  for (char **p = program_args; p != nullptr && *p != nullptr; p++) {
    args->program_args.emplace_back(*p);
  }
  for (char **p = extra_vm_options; p != nullptr && *p != nullptr; p++) {
    args->extra_vm_options.emplace_back(*p);
  }

  g_running = true;
  if (pthread_create(&g_thread, nullptr, jvm_thread_main, args) != 0) {
    delete args;
    report_error("pthread_create failed");
    g_running = false;
    return 1;
  }
  return 0;
}

extern "C" int tinyvm_stop(int timeout_seconds) {
  if (!g_running) {
    return 0;
  }
  forward_log("[native] stop: System.exit(0)");

  long long budget_ms = static_cast<long long>(timeout_seconds) * 1000;

  // g_vm appears only when JNI_CreateJavaVM returns; wait for a still
  // booting JVM within the budget instead of pretending the stop worked.
  for (long long left = budget_ms; g_vm == nullptr && g_running && left > 0; left -= 100) {
    usleep(100 * 1000);
  }
  if (g_vm == nullptr) {
    report_error(g_running
                     ? "JVM is still starting after %ds; retry stop or close the app"
                     : "JVM already gone",
                 timeout_seconds);
    return 1;
  }

  // System.exit runs on its own thread because this mobile snapshot's exit
  // path can deadlock the calling thread inside Runtime.exit (logging).
  pthread_t exit_thread;
  int prc = pthread_create(&exit_thread, nullptr, [](void *) -> void * {
    JNIEnv *env = nullptr;
    if (g_vm != nullptr &&
        g_vm->AttachCurrentThread(reinterpret_cast<void **>(&env), nullptr) == JNI_OK) {
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
  if (prc != 0) {
    report_error("pthread_create for System.exit failed: %s", strerror(prc));
    return 1;
  }
  pthread_detach(exit_thread);

  // Observe, never force: a healthy System.exit removes the whole process
  // before this loop finishes. If the upstream exit path stalls, report and
  // leave the process alive — the user closes the app manually.
  for (long long left = budget_ms; g_running && left > 0; left -= 100) {
    usleep(100 * 1000);
  }
  if (g_running) {
    report_error("System.exit did not complete within %ds", timeout_seconds);
    return 1;
  }
  return 0;
}

extern "C" bool tinyvm_is_running(void) { return g_running; }

extern "C" const char *tinyvm_last_error(void) { return g_err; }

extern "C" int tinyvm_write_dns_config(const char *user_home,
                                       const char *resolv_conf_relative_path) {
  if (user_home == nullptr || resolv_conf_relative_path == nullptr) {
    report_error("null argument");
    return 1;
  }

  // struct __res_9_state is not in the iOS SDK headers; the buffer below is
  // far larger than the actual struct. res_9_sockaddr_union holds a
  // sockaddr_storage; 128 bytes per slot is sufficient.
  typedef int (*ninit_t)(void *);
  typedef int (*getservers_t)(void *, void *, int);
  typedef void (*ndestroy_t)(void *);
  void *h = dlopen("libresolv.9.dylib", RTLD_LAZY);
  if (h == nullptr) {
    report_error("cannot collect DNS servers: dlopen(libresolv.9.dylib) failed: %s", dlerror());
    return 1;
  }
  auto ninit = reinterpret_cast<ninit_t>(dlsym(h, "res_9_ninit"));
  auto getservers = reinterpret_cast<getservers_t>(dlsym(h, "res_9_getservers"));
  auto ndestroy = reinterpret_cast<ndestroy_t>(dlsym(h, "res_9_ndestroy"));
  if (ninit == nullptr || getservers == nullptr || ndestroy == nullptr) {
    report_error("cannot collect DNS servers: libresolv.9.dylib lacks res_9_* symbols");
    return 1;
  }
  alignas(16) unsigned char state[4096];
  unsigned char addrs[16][128];
  memset(state, 0, sizeof(state));
  if (ninit(state) != 0) {
    report_error("cannot collect DNS servers: res_9_ninit failed");
    return 1;
  }
  std::string servers;
  int n = getservers(state, addrs, 16);
  char buf[INET6_ADDRSTRLEN];
  for (int i = 0; i < n; i++) {
    sockaddr *sa = reinterpret_cast<sockaddr *>(&addrs[i]);
    void *in;
    if (sa->sa_family == AF_INET) {
      in = &reinterpret_cast<sockaddr_in *>(sa)->sin_addr;
    } else if (sa->sa_family == AF_INET6) {
      in = &reinterpret_cast<sockaddr_in6 *>(sa)->sin6_addr;
    } else {
      continue;
    }
    if (inet_ntop(sa->sa_family, in, buf, sizeof(buf)) == nullptr) {
      continue;
    }
    servers += "nameserver ";
    servers += buf;
    servers += "\n";
  }
  ndestroy(state);
  if (servers.empty()) {
    report_error("no DNS servers found (libresolv gave nothing)");
    return 1;
  }

  std::string path = std::string(user_home) + "/" + resolv_conf_relative_path;
  std::string dir = path.substr(0, path.find_last_of('/'));
  // mkdir -p: walk every path prefix, including the final directory itself.
  for (size_t pos = dir.find('/', 1);; pos = dir.find('/', pos + 1)) {
    std::string prefix = dir.substr(0, pos); // npos yields the whole dir
    if (mkdir(prefix.c_str(), 0755) != 0 && errno != EEXIST) {
      report_error("mkdir %s failed: %s", prefix.c_str(), strerror(errno));
      return 1;
    }
    if (pos == std::string::npos) {
      break;
    }
  }
  FILE *out = fopen(path.c_str(), "w");
  if (out == nullptr) {
    report_error("cannot write %s: %s", path.c_str(), strerror(errno));
    return 1;
  }
  fputs("# generated by the embedding app before starting the JVM\n", out);
  fputs(servers.c_str(), out);
  // fclose flushes; its result covers any buffered write failure.
  if (fclose(out) != 0) {
    report_error("writing %s failed: %s", path.c_str(), strerror(errno));
    return 1;
  }
  std::string note = "[native] wrote " + path;
  forward_log(note.c_str());
  return 0;
}
