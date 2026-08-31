// Word-level diff for the edit-history modal, mirroring the slint
// app's edit_diff.rs: unchanged words follow the longest common
// subsequence, everything else is Removed/Added.
package main

import "core:strings"

Diff_Kind :: enum {
	Same,
	Removed,
	Added,
}

Diff_Run :: struct {
	kind: Diff_Kind,
	text: string, // one word, a slice of the input text
}

// Word diff of prev -> next. Whitespace collapses (the modal reflows
// words as chips anyway). O(n*m) LCS table; message-sized texts keep
// it tiny. Within a gap, removed words come before added ones.
diff_words :: proc(prev, next: string, allocator := context.temp_allocator) -> [dynamic]Diff_Run {
	a := strings.fields(prev, allocator)
	b := strings.fields(next, allocator)
	n, m := len(a), len(b)

	// dp[i * (m+1) + j] = LCS length of a[i:] vs b[j:].
	dp := make([]int, (n + 1) * (m + 1), allocator)
	for i := n - 1; i >= 0; i -= 1 {
		for j := m - 1; j >= 0; j -= 1 {
			at := i * (m + 1) + j
			if a[i] == b[j] {
				dp[at] = dp[at + m + 2] + 1
			} else {
				dp[at] = max(dp[at + m + 1], dp[at + 1])
			}
		}
	}

	out := make([dynamic]Diff_Run, allocator)
	i, j := 0, 0
	for i < n && j < m {
		if a[i] == b[j] {
			append(&out, Diff_Run{.Same, a[i]})
			i += 1
			j += 1
		} else if dp[(i + 1) * (m + 1) + j] >= dp[i * (m + 1) + j + 1] {
			append(&out, Diff_Run{.Removed, a[i]})
			i += 1
		} else {
			append(&out, Diff_Run{.Added, b[j]})
			j += 1
		}
	}
	for ; i < n; i += 1 {
		append(&out, Diff_Run{.Removed, a[i]})
	}
	for ; j < m; j += 1 {
		append(&out, Diff_Run{.Added, b[j]})
	}
	return out
}
