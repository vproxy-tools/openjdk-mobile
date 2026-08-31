/*
 * Zero-variant W^X shims.
 *
 * The HotSpot W^X bookkeeping symbols referenced unconditionally by shared
 * code (nmethod.cpp / deoptimization.cpp) are only *defined* in
 * os_cpu/bsd_aarch64/os_bsd_aarch64.cpp, which the Zero variant does not
 * compile (Zero uses os_cpu/bsd_zero). The Zero interpreter never toggles
 * W^X permissions, so disabled definitions are provided here to satisfy the
 * final static link. Symbol names are the exact mangled names observed in
 * the archives (see JvmEmbed/README.md "链接要求").
 */

extern "C" {

// The definitions are weak: the zero variant needs them (its os_cpu is
// bsd_zero, which does not compile the real ones), while the server
// simulator variant provides strong definitions in os_bsd_aarch64.o that
// then win over these stubs.
//
// os::_jit_exec_enabled  (static thread_local bool; default false)
__attribute__((visibility("default"), weak))
__thread bool _ZN2os17_jit_exec_enabledE = false;

// os::thread_wx_enable_write_impl()  (no-op on Zero)
__attribute__((visibility("default"), weak))
void _ZN2os27thread_wx_enable_write_implEv() {}

// DefaultWXWriteMode  (WXMode enum value; 0 == WXWrite, i.e. never armed)
enum WXModeShim { WXWriteShim = 0 };
__attribute__((weak)) WXModeShim DefaultWXWriteMode = WXWriteShim;

}  // extern "C"
