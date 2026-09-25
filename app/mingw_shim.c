// Windows cross builds only. Odin emits objects for the MSVC CRT, which
// supplies these two symbols; the LLVM-MinGW UCRT toolchain does not.
//
// _fltused: MSVC's "this program uses floating point" marker. Only its
// presence matters; the value mirrors Odin's own no-CRT definition.
int _fltused = 0x9875;

// __chkstk: stack probe the compiler calls before frames larger than a page.
// On x64 MinGW's ___chkstk_ms has the same contract (size in rax, probe each
// page, rsp unchanged), so a tail jump preserves every register it relies on.
__asm__(".globl __chkstk\n"
        "__chkstk:\n"
        "  jmp ___chkstk_ms\n");
