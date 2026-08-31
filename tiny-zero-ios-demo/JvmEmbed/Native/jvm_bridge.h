#ifndef TINYVM_JVM_BRIDGE_H
#define TINYVM_JVM_BRIDGE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * C bridge between a Swift app and an embedded Tiny Zero JVM.
 *
 * The JVM is created on a dedicated pthread ("JVM main thread"), which runs
 * the given Java main class and reports every stdout/stderr line through
 * log_fn (via the IosBootstrap helper class on the class path). Exit
 * conditions (normal or failed) are reported through exit_fn.
 *
 * -Duser.home=<user_home> is passed to the VM so the embedded program stores
 * all of its state below the app container directory; use a directory that is
 * writable on real devices (the data container root is read-only there,
 * Documents/ is writable on both).
 *
 * All functions return 0 on success, non-zero on failure; a static buffer
 * with a human readable reason is available via tinyvm_last_error().
 */

typedef void (*tinyvm_log_fn)(const char *line);
typedef void (*tinyvm_exit_fn)(int exit_code, const char *reason);

/*
 * jar_paths:         colon-separated java.class.path
 * user_home:         app container dir, passed as -Duser.home
 * main_class:        main class, dot or slash form (e.g. "com.example.Main")
 * program_args:      NULL-terminated argv for main(), may be NULL
 * extra_vm_options:  NULL-terminated extra JVM options, may be NULL
 *
 * The anchor of the generated symbol keeper is called here before the VM is
 * created, so a normal link of libtinyjvm.a keeps every kept JNI/JIMAGE
 * symbol without -all_load/-force_load.
 */
int tinyvm_start(const char *jar_paths,
                 const char *user_home,
                 const char *main_class,
                 char **program_args,
                 char **extra_vm_options,
                 tinyvm_log_fn log_fn,
                 tinyvm_exit_fn exit_fn);

/*
 * Asks the Java side to stop by calling System.exit(0) from an attached
 * thread, then observes: a healthy exit removes the whole process before the
 * timeout. If the VM is still booting or the exit path stalls, an error is
 * reported and the process is left alone - the host never force-kills.
 */
int tinyvm_stop(int timeout_seconds);

bool tinyvm_is_running(void);

const char *tinyvm_last_error(void);

/*
 * Collects the system DNS servers through libresolv (dlopen'ed because the
 * SDK headers mark res_9_* unavailable for iOS; works on both simulator and
 * real devices) and writes them in resolv.conf format to
 * <user_home>/<resolv_conf_relative_path> (e.g. ".vproxy/resolv.conf" for
 * vproxy, whose resolver prefers that file over /etc/resolv.conf).
 */
int tinyvm_write_dns_config(const char *user_home,
                            const char *resolv_conf_relative_path);

#ifdef __cplusplus
}
#endif

#endif /* TINYVM_JVM_BRIDGE_H */
