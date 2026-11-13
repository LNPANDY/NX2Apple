// Probe.framework: the payload of the dlopen probe (docs/probe-dlopen.md). One C function with a
// known answer: the shell app dlsyms it in the framework it loaded and calls it, so a 42 back
// proves the call went through the bundle framework and not somewhere else. Deliberately free of
// every dependency: no Foundation, no libSystem calls beyond the C library, nothing that could
// make the load fail for a reason other than the one under test.
int probe_answer(void) { return 42; }
