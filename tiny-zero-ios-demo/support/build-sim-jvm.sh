#!/usr/bin/env bash
set -euo pipefail

# Build a Zero JVM static library for the iOS Simulator (arm64).
#
# Reuses the source tree prepared by tiny-zero-ios-build (same pinned commit,
# same jni.cpp keeper anchor and the same generated symbol_keeper.cpp), so the
# simulator slice behaves like the device slice. The runtime image
# (lib/modules) is platform independent and is taken from the device build.

DEMO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TINY_ROOT="${TINY_ROOT:-$DEMO_ROOT/../tiny-zero-ios-build}"
# shellcheck disable=SC1091
source "$TINY_ROOT/config/build.env"

SRC="$TINY_ROOT/work/mobile"
[[ -d "$SRC" ]] || { echo "ERROR: $SRC missing; run tiny-zero-ios-build/build.sh first" >&2; exit 1; }

CONF=ios-aarch64-zero-sim-release
SIMSDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SIMFFI="$HOME/ios-sim-support/libffi"
[[ -f "$SIMFFI/lib/libffi.a" ]] || { echo "ERROR: simulator libffi missing at $SIMFFI" >&2; exit 1; }

cd "$SRC"

# The simulator process runs under macOS memory rules: an RWX mprotect is
# only allowed on MAP_JIT mappings. Upstream's __IOS__ branch of anon_mmap
# deliberately drops MAP_JIT (real-device rules), which makes the Zero code
# cache commit fail with "Could not reserve enough space in CodeCache".
# Re-enable MAP_JIT for simulator targets only (TARGET_OS_SIMULATOR is 0 in
# device builds, so this patch is inert there).
python3 - <<'PY'
import sys
path = "src/hotspot/os/bsd/os_bsd.cpp"
src = open(path).read()
old = """  const int flags = MAP_PRIVATE | MAP_NORESERVE | MAP_ANONYMOUS
#ifdef __IOS__
      ;
"""
new = """  const int flags = MAP_PRIVATE | MAP_NORESERVE | MAP_ANONYMOUS
#ifdef __IOS__
#if defined(TARGET_OS_SIMULATOR) && TARGET_OS_SIMULATOR
      | (exec ? MAP_JIT : 0) // simulator runs under macOS RWX rules
#endif
      ;
"""
if new in src:
    print("MAP_JIT patch already applied")
elif old in src:
    open(path, "w").write(src.replace(old, new, 1))
    print("MAP_JIT patch applied")
else:
    sys.exit("cannot apply MAP_JIT patch; upstream os_bsd.cpp shape changed")
PY

# Zero interpreter entry fallback: an invokevirtual target that has not been
# linked reports from_interpreted_entry() == nullptr, which would crash the
# call (SIGSEGV at a null entry point). Fall back to the interpreter entry
# table, the same source Method::link_method uses. TEMP-DEBUG prints trace the
# remaining unlinked-state crashes.
python3 - <<'PY'
import sys
path = "src/hotspot/cpu/zero/zeroInterpreter_zero.cpp"
src = open(path).read()
old = """    // Call the interpreter
    if (JvmtiExport::can_post_interpreter_events()) {
"""
new = """    // Call the interpreter
    if (JvmtiExport::can_post_interpreter_events()) {
"""
old2 = """    // Examine the message from the interpreter to decide what to do
    if (istate->msg() == BytecodeInterpreter::call_method) {
      Method* callee = istate->callee();

      // Trim back the stack to put the parameters at the top
      stack->set_sp(istate->stack() + 1);
"""
new2 = """    // Examine the message from the interpreter to decide what to do
    if (istate->msg() == BytecodeInterpreter::call_method) {
      Method* callee = istate->callee();

      // TINY-ZERO FIX: an invokevirtual target that has not been linked yet
      // reports from_interpreted_entry() == nullptr; fall back to the
      // interpreter entry table, the same source Method::link_method uses.
      if (istate->callee_entry_point() == nullptr && callee != nullptr) {
        istate->set_callee_entry_point(
            AbstractInterpreter::entry_for_method(methodHandle(thread, callee)));
      }

      // Trim back the stack to put the parameters at the top
      stack->set_sp(istate->stack() + 1);
"""
old3 = """  istate->set_bcp(method->is_native() ? nullptr : method->code_base());
  istate->set_constants(method->constants()->cache());
"""
new3 = """  istate->set_bcp(method->is_native() ? nullptr : method->code_base());
  // TINY-ZERO FIX: a klass that has not been rewritten/linked yet (early
  // bootstrap on this port) has no constant pool cache, which the zero
  // interpreter dereferences immediately; run the rewriter on demand.
  {
    ConstantPoolCache* cpc = method->constants()->cache();
    if (cpc == nullptr) {
      method->method_holder()->link_class(thread);
      cpc = method->constants()->cache();
    }
    istate->set_constants(cpc);
  }
"""
old4 = """#include "interpreter/rewriter.hpp"
"""
new4 = """#include "interpreter/rewriter.hpp"
"""
if old4 not in src:
    # insert after the first interpreter include
    anchor4 = """#include "interpreter/interpreter.hpp"
"""
    if anchor4 in src:
        src = src.replace(anchor4, anchor4 + new4, 1)
applied = 0
if new in src and new2 in src and new3 in src and "#include \"interpreter/rewriter.hpp\"" in src:
    print("zero entry fallback patch already applied")
elif old in src and old2 in src and old3 in src:
    src = src.replace(old, new, 1).replace(old2, new2, 1).replace(old3, new3, 1)
    anchor4 = """#include "interpreter/interpreter.hpp"
"""
    if anchor4 in src and "#include \"interpreter/rewriter.hpp\"" not in src:
        src = src.replace(anchor4, anchor4 + """#include "interpreter/rewriter.hpp"
""", 1)
    open(path, "w").write(src)
    print("zero entry fallback patch applied")
else:
    sys.exit("cannot apply zero entry fallback patch; upstream shape changed")
PY

# Throwable stack-trace guard: during the pre-init window the zero port's
# stack machinery cannot materialize elements (StackTraceElement.of returns
# null on a half-built backtrace), which turns getStackTrace() into an NPE
# and cascades into a NoClassDefFoundError construction storm. Return an
# empty trace until the VM is booted.
python3 - <<'PY'
import sys
path = "src/java.base/share/classes/java/lang/Throwable.java"
src = open(path).read()
old = """    private synchronized StackTraceElement[] getOurStackTrace() {
        // Initialize stack trace field with information from
        // backtrace if this is the first call to this method
        if (stackTrace == UNASSIGNED_STACK || stackTrace == null) {
"""
new = """    private synchronized StackTraceElement[] getOurStackTrace() {
        // TINY-ZERO FIX (simulator): before the VM is booted the stack
        // machinery cannot materialize elements yet; an empty trace keeps
        // bootstrap-time exception handling usable.
        if (!jdk.internal.misc.VM.isBooted()) {
            return UNASSIGNED_STACK;
        }
        // Initialize stack trace field with information from
        // backtrace if this is the first call to this method
        if (stackTrace == UNASSIGNED_STACK || stackTrace == null) {
"""
if new in src:
    print("Throwable guard patch already applied")
elif old in src:
    open(path, "w").write(src.replace(old, new, 1))
    print("Throwable guard patch applied")
else:
    sys.exit("cannot apply Throwable guard patch; upstream shape changed")
PY

# Native lookup handle: a statically linked iOS binary's JNI symbols may
# live in any linked image (debug dylib etc.); RTLD_FIRST restricts dlsym to
# the main executable and misses them, sending every native resolution to
# ClassLoader.findNative and deadlocking bootstrap in initialization
# reentry. Use RTLD_DEFAULT for static links.
python3 - <<'PY'
import sys
path = "src/hotspot/os/posix/os_posix.cpp"
src = open(path).read()
old = """void* os::get_default_process_handle() {
#ifdef __APPLE__
"""
new = """void* os::get_default_process_handle() {
#if defined(__APPLE__) && defined(__IOS__)
  // TINY-ZERO FIX: see build-sim-jvm.sh; search the global namespace for
  // statically linked builds so JNI symbols in any image are found.
  if (is_vm_statically_linked()) {
    return (void*)-2 /* RTLD_DEFAULT */;
  }
#endif
#ifdef __APPLE__
"""
if new in src:
    print("native handle patch already applied")
elif old in src:
    open(path, "w").write(src.replace(old, new, 1))
    print("native handle patch applied")
else:
    sys.exit("cannot apply native handle patch; upstream shape changed")
PY

# bsd_zero crash reporting: ucontext_get_pc used ShouldNotCallThis, so any
# error-reporting path that needs the faulting pc turned into a second fatal
# ("Native frames: unavailable"). Return the real pc (darwin arm64 layout),
# mirroring what linux_zero provides behind DecodeErrorContext — but
# unconditionally, since this is only called on the crash path.
python3 - <<'PY'
import sys
path = "src/hotspot/os_cpu/bsd_zero/os_bsd_zero.cpp"
src = open(path).read()
old = """address os::Posix::ucontext_get_pc(const ucontext_t* uc) {
  ShouldNotCallThis();
  return nullptr;
}
"""
new = """address os::Posix::ucontext_get_pc(const ucontext_t* uc) {
  // TINY-ZERO FIX: crash-path only; return the real pc so hs_err can print
  // native frames instead of hitting ShouldNotCallThis during reporting.
#if defined(AARCH64) && defined(__APPLE__)
  return (address)uc->uc_mcontext->__ss.__pc;
#else
  ShouldNotCallThis();
  return nullptr;
#endif
}
"""
if new in src:
    print("bsd_zero pc patch already applied")
elif old in src:
    open(path, "w").write(src.replace(old, new, 1))
    print("bsd_zero pc patch applied")
else:
    sys.exit("cannot apply bsd_zero pc patch; upstream shape changed")
PY

# Lazy W^X trampoline for the simulator: macOS 26 MAP_JIT pages are strictly
# either writable or executable, and the iOS build compiles out the upstream
# W^X healing (MACOS_AARCH64 is not defined for iOS targets). A BUS_ADRALN
# fault with si_addr == pc means "needs execute", otherwise "needs write";
# flip the per-thread protection and let the kernel retry the faulting
# instruction.
python3 - <<'PY'
import sys
path = "src/hotspot/os/posix/signals_posix.cpp"
src = open(path).read()
old = """static void javaSignalHandler(int sig, siginfo_t* info, void* context) {
  // Do not add any code here!
"""
new = """// Resolved through dlsym: the SDK headers mark pthread_jit_write_protect_np
// unavailable on iOS, but it exists in the simulator runtime. The file-scope
// initializer runs at library load time, before any signal can arrive.
extern "C" void* dlsym(void*, const char*);
static void (*const lazy_wx_flip)(int) =
    (void (*)(int))dlsym((void*)-2 /* RTLD_DEFAULT */, "pthread_jit_write_protect_np");

static void javaSignalHandler(int sig, siginfo_t* info, void* context) {
#if defined(__APPLE__) && defined(__aarch64__) && \\
    defined(TARGET_OS_SIMULATOR) && TARGET_OS_SIMULATOR
  // bsd_zero cannot recover from SIGSEGV in the interpreter (its signal path
  // is unfinished upstream); at least make the fault site visible.
  if (sig == SIGSEGV && info != nullptr && context != nullptr) {
    ucontext_t* uc0 = (ucontext_t*)context;
    ::fprintf(stderr, "[zero-sig] SIGSEGV addr=%p pc=%p\\n",
              info->si_addr, (void*)uc0->uc_mcontext->__ss.__pc);
  }
  if (sig == SIGBUS && info != nullptr && info->si_code == BUS_ADRALN
      && context != nullptr && lazy_wx_flip != nullptr) {
    ucontext_t* uc = (ucontext_t*)context;
    uintptr_t pc = (uintptr_t)uc->uc_mcontext->__ss.__pc;
    if ((uintptr_t)info->si_addr == pc) {
      lazy_wx_flip(1); // executing a write-protected page
    } else {
      lazy_wx_flip(0); // writing an exec-protected page
    }
    return;
  }
#endif
  // Do not add any code here!
"""
if new in src:
    print("lazy W^X patch already applied")
elif old in src:
    open(path, "w").write(src.replace(old, new, 1))
    print("lazy W^X patch applied")
else:
    sys.exit("cannot apply lazy W^X patch; upstream signals_posix.cpp shape changed")
PY

# Invalidate the configuration if it points at an SDK that no longer exists
# (e.g. after a macOS/Xcode upgrade), was produced by another clang, or
# predates the assembler flags fix (copy_bsd_aarch64.S used to compile to a
# macOS object because the .S step missed -target/-isysroot).
if [[ -f "build/$CONF/spec.gmk" ]] && ! grep -q "arm64-apple-ios14.5-simulator" build/$CONF/spec.gmk; then
  echo "stale configuration (SDK/asflags changed), reconfiguring..."
  rm -rf "build/$CONF"
fi

if [[ ! -f "build/$CONF/spec.gmk" ]]; then
  # JFR is disabled: it has no BSD SystemProcessInterface implementation
  # and the demo does not need it.
  bash configure \
    --with-conf-name="$CONF" \
    --with-debug-level=release \
    --disable-warnings-as-errors \
    --openjdk-target=aarch64-macos-ios \
    --with-jvm-variants=zero \
    --with-jvm-features="-jfr" \
    --with-native-debug-symbols=none \
    --enable-headless-only \
    --with-boot-jdk="$BOOT_JDK" \
    --with-libffi-include="$SIMFFI/include" \
    --with-libffi-lib="$SIMFFI/lib" \
    --with-cups-include="$CUPS_INCLUDE" \
    --with-sysroot="$SIMSDK" \
    --with-extra-asflags="-target arm64-apple-ios14.5-simulator -isysroot $SIMSDK" \
    2>&1 | tee "$TINY_ROOT/work/logs/configure-sim.log"
fi

make LOG=info JOBS="$JOBS" CONF="$CONF" static-libs-image jdk.unsupported-java

STATIC="build/$CONF/images/static-libs/lib"
for lib in libjava.a libjimage.a libnet.a libnio.a libzip.a; do
  [[ -f "$STATIC/$lib" ]] || { echo "ERROR: $STATIC/$lib missing" >&2; exit 1; }
done
[[ -f "$STATIC/zero/libjvm.a" ]] || { echo "ERROR: simulator libjvm.a missing" >&2; exit 1; }

cryptoki_libs=""
while IFS= read -r lib; do
  if [[ -n "$lib" ]]; then
    cryptoki_libs="$cryptoki_libs $lib"
  fi
done < <(find "build/$CONF/support/native/jdk.crypto.cryptoki" -type f -name '*.a' | LC_ALL=C sort)
[[ -n "$cryptoki_libs" ]] || { echo "ERROR: no cryptoki archive" >&2; exit 1; }

mkdir -p "$DEMO_ROOT/third_party"
libtool -static -o "$DEMO_ROOT/third_party/libtinyjvm-sim.a" \
  "$STATIC/zero/libjvm.a" \
  "$SIMFFI/lib/libffi.a" \
  "$STATIC/libjava.a" \
  "$STATIC/libjimage.a" \
  "$STATIC/libnet.a" \
  "$STATIC/libnio.a" \
  "$STATIC/libzip.a" \
  $cryptoki_libs

# Build the runtime image from THIS build's exploded classes so the
# Throwable guard patch above is included. Layout note: for a statically
# linked iOS JVM, hotspot derives java_home = <executable dir>/lib
# (os_bsd.cpp, __IOS__ branch) and set_boot_path then looks for
# <java_home>/lib/modules, so the folder reference must end up as
# <bundle>/lib/lib/modules.
mkdir -p "$DEMO_ROOT/work-generated"
JMODS="$DEMO_ROOT/work-generated/sim-jmods"
rm -rf "$JMODS"
mkdir -p "$JMODS"

# JDK 28 jlink requires the target java.base build descriptor to match the
# jlink runtime's, so synchronize it from the boot JDK (metadata only).
REL="jdk/internal/misc/resources/release.txt"
HOST_REL_DIR="$DEMO_ROOT/work-generated/sim-host-release"
rm -rf "$HOST_REL_DIR"
"$BOOT_JDK/bin/jimage" extract --include "regex:.*$REL" --dir "$HOST_REL_DIR" \
  "$BOOT_JDK/lib/modules" >/dev/null
HOST_REL="$HOST_REL_DIR/java.base/$REL"

for module in java.base jdk.unsupported jdk.crypto.cryptoki; do
  MODDIR="build/$CONF/jdk/modules/$module"
  [[ -d "$MODDIR" ]] || { echo "ERROR: missing exploded module $module" >&2; exit 1; }
  if [[ -f "$MODDIR/$REL" && -f "$HOST_REL" ]]; then
    cp "$HOST_REL" "$MODDIR/$REL"
  fi
  "$BOOT_JDK/bin/jmod" create --class-path "$MODDIR" \
    --target-platform macos-aarch64 "$JMODS/$module.jmod"
done

RUNTIME_OUT="$DEMO_ROOT/work-generated/sim-runtime"
rm -rf "$RUNTIME_OUT"
"$BOOT_JDK/bin/jlink" \
  --module-path "$JMODS" \
  --add-modules java.base,jdk.unsupported,jdk.crypto.cryptoki \
  --strip-debug --no-header-files --no-man-pages \
  --output "$RUNTIME_OUT"

mkdir -p "$DEMO_ROOT/third_party/lib/lib"
cp "$RUNTIME_OUT/lib/modules" "$DEMO_ROOT/third_party/lib/lib/modules"
cp "$RUNTIME_OUT/release" "$DEMO_ROOT/third_party/lib/release"
# java.home is <bundle>/lib; the runtime reads conf/security/java.security
# etc. from <java_home>/conf. The three-module jlink image does not carry
# them, so take the configuration set from the boot JDK.
rm -rf "$DEMO_ROOT/third_party/lib/conf"
cp -R "$BOOT_JDK/conf" "$DEMO_ROOT/third_party/lib/conf"

echo "OK: $DEMO_ROOT/third_party/libtinyjvm-sim.a"
