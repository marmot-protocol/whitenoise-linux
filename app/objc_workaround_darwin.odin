#+build darwin
package main

import "base:intrinsics"

// ponytail: works around odin-lang/Odin#7793 in the pinned dev-2026-10.
// core:sys/info sends Foundation messages on macOS, and the backend then
// registers classes with objc_lookUpClass and sel_registerName. The checker
// only pulls those runtime procedures in for objc intrinsics or class
// implementations, so a plain message send aborts code generation with
// "missing procedure 'objc_lookUpClass'". This direct lookup adds them.
// Delete this file once the Odin pin includes upstream commit 15030692.
@(init, private = "file")
odin_7793_workaround :: proc "contextless" () {
	_ = intrinsics.objc_find_class("NSObject")
}
