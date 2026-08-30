#ifndef TINYVM_JVM_BRIDGE_H
#define TINYVM_JVM_BRIDGE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * C bridge between the Swift app and the embedded Tiny Zero JVM.
 *
 * The JVM is created on a dedicated pthread ("JVM main thread"), which runs
 * TinyHttpServer.main and reports every stdout/stderr line through log_fn.
 * Exit conditions (normal or failed) are reported through exit_fn.
 *
 * All functions return 0 on success, non-zero on failure; a static buffer
 * with a human readable reason is available via tinyvm_last_error().
 */

typedef void (*tinyvm_log_fn)(const char *line);
typedef void (*tinyvm_exit_fn)(int exit_code, const char *reason);

int tinyvm_start(const char *runtime_home,
                 const char *jar_path,
                 int port,
                 tinyvm_log_fn log_fn,
                 tinyvm_exit_fn exit_fn);

/** Asks the Java side to stop (wakes accept()) and waits for the JVM thread. */
int tinyvm_stop(int timeout_seconds);

bool tinyvm_is_running(void);

const char *tinyvm_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* TINYVM_JVM_BRIDGE_H */
