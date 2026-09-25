// Running a webxdc app (NIP-DC), rung B: the unpacked .xdc is served
// from memory on 127.0.0.1 and opened in the system browser, and the
// webxdc.js shim talks back over that same loopback.
//
//   tile click ──► xdc_launch ──► xdg-open http://127.0.0.1:p/<token>/
//                                        │
//   sendUpdate() ──► POST api/send ──► outbox ──► xdc_drain ──► send_text
//                                                                  │
//   setUpdateListener ◄── GET api/updates ◄── updates ◄── load_timeline
//
// State rides ordinary text messages, because marmot-c publishes no
// custom kinds or tags: one line, `wnxdc1:<session>:<base64 payload>`,
// where <session> is the message id of the .xdc that was shared. Those
// lines never render here, but they ARE visible to every other client
// in the group, and no other client understands them. NIP-DC's kind
// 4932 is what this should be once marmot-c can send it.
//
// ponytail: one app at a time, one request at a time, 1s polling, and
// no kind-20932 realtime channel (that needs raw relay access, which
// this binary has at no layer).
package main

import "core:crypto"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"

import marmot "../marmot"

XDC_SENTINEL :: "wnxdc1:"
XDC_MAX_UPDATE :: 128 * 1024 // decoded payload cap, per update
XDC_MAX_HEADER :: 8 * 1024
XDC_POLL_MS :: 250

// Everything the server thread and the UI thread share. Both take the
// mutex; nothing here is touched without it.
Xdc_Session :: struct {
	mutex:     sync.Mutex,
	view:      ^Xdc_View, // borrowed from the xdc_views cache
	session:   string, // sharing message id hex, the NIP-DC identifier
	group_id:  string,
	self_addr: string, // npub
	self_name: string,
	token:     string, // path prefix, so a stray local page can't poke it
	updates:   [dynamic]string, // payload JSON in timeline order
	outbox:    [dynamic]string, // payloads waiting for the UI thread to send
	staging:   [dynamic]string, // the reload being collected
	pending:   [dynamic]string, // sent, not yet back from the group
	port:      int,
	serving:   bool,
}

xdc: Xdc_Session

// ── Transport: the sentinel line ────────────────────────────────────

xdc_encode :: proc(session: string, payload: []u8, allocator := context.allocator) -> string {
	b64 := base64.encode(payload, base64.ENC_TABLE, context.temp_allocator)
	return fmt.aprintf("%s%s:%s", XDC_SENTINEL, session, b64, allocator = allocator)
}

// A sentinel line splits into its session and its decoded payload.
// ok = false for every ordinary message, which is most of them.
xdc_decode :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	session: string,
	payload: []u8,
	ok: bool,
) {
	line := strings.trim_space(text)
	if !strings.has_prefix(line, XDC_SENTINEL) {
		return
	}
	rest := line[len(XDC_SENTINEL):]
	sess, _, b64 := strings.partition(rest, ":")
	if len(sess) == 0 || len(b64) == 0 {
		return
	}
	bytes, err := base64.decode(b64, base64.DEC_TABLE, nil, allocator)
	if err != nil || len(bytes) == 0 || len(bytes) > XDC_MAX_UPDATE {
		delete(bytes, allocator)
		return
	}
	return sess, bytes, true
}

// ── Collection: called by load_timeline, in timeline order ──────────

xdc_collect_begin :: proc() {
	sync.lock(&xdc.mutex)
	for u in xdc.staging {
		delete(u)
	}
	clear(&xdc.staging)
	sync.unlock(&xdc.mutex)
}

xdc_collect :: proc(session: string, payload: []u8) {
	sync.lock(&xdc.mutex)
	defer sync.unlock(&xdc.mutex)
	if session != xdc.session {
		delete(payload) // nothing is listening for this app's updates
		return
	}
	append(&xdc.staging, string(payload))
}

// The collected list becomes what the shim polls. Serials are the
// positions in it, which is why the whole list is replaced rather than
// appended to: timeline order is the only ordering there is.
xdc_collect_end :: proc() {
	sync.lock(&xdc.mutex)
	defer sync.unlock(&xdc.mutex)
	if len(xdc.staging) == 0 && len(xdc.updates) == 0 {
		return
	}
	for u in xdc.updates {
		delete(u)
	}
	clear(&xdc.updates)
	append(&xdc.updates, ..xdc.staging[:])
	clear(&xdc.staging) // the strings moved into updates

	// An update that came back from the group is no longer pending.
	for i := len(xdc.pending) - 1; i >= 0; i -= 1 {
		for confirmed in xdc.updates {
			if confirmed != xdc.pending[i] {
				continue
			}
			delete(xdc.pending[i])
			ordered_remove(&xdc.pending, i)
			break
		}
	}
}

// ── Frame-loop drain: sendUpdate() becomes a message ────────────────

xdc_drain :: proc(ui: ^Ui_State, client: ^marmot.Client) {
	sync.lock(&xdc.mutex)
	if len(xdc.outbox) == 0 {
		sync.unlock(&xdc.mutex)
		return
	}
	out := slice_clone_strings(xdc.outbox[:])
	clear(&xdc.outbox)
	session, group := strings.clone(xdc.session), strings.clone(xdc.group_id)
	sync.unlock(&xdc.mutex)
	defer {
		delete(session)
		delete(group)
		delete(out)
	}

	for payload in out {
		defer delete(payload)
		line := xdc_encode(session, transmute([]u8)payload)
		defer delete(line)

		// Not a ui.pending row: a state update is not a message the
		// user wrote, so it gets no optimistic bubble. The ack comes
		// back as an ordinary reload, which is also how the app sees
		// its own update.
		send_ticket += 1
		p := Pending_Send {
			ticket   = send_ticket,
			group_id = group,
			body     = line,
		}
		spawn_send(ui, client, &p) // clones everything it keeps
	}
}

@(private = "file")
slice_clone_strings :: proc(src: []string) -> []string {
	out := make([]string, len(src))
	copy(out, src)
	return out
}

// ── Launch ──────────────────────────────────────────────────────────

xdc_launch :: proc(
	ui: ^Ui_State,
	client: ^marmot.Client,
	view: ^Xdc_View,
	session, group_id: string,
) {
	if !WEBXDC_SUPPORTED {
		toast(ui, tr("Webxdc apps are only supported on Linux."))
		return
	}
	info := profile_info(client, ui.account_ref)
	token: [16]u8
	crypto.rand_bytes(token[:])

	sync.lock(&xdc.mutex)
	delete(xdc.session)
	delete(xdc.group_id)
	delete(xdc.token)
	delete(xdc.self_addr)
	delete(xdc.self_name)
	for u in xdc.updates {
		delete(u)
	}
	clear(&xdc.updates)
	xdc.view = view
	xdc.session = strings.clone(session)
	xdc.group_id = strings.clone(group_id)
	token_hex, _ := hex.encode(token[:])
	xdc.token = string(token_hex)
	// selfAddr is the npub. ui.profile is only filled once the profile
	// page has loaded, so derive it from the account when it is not.
	addr := ui.profile.npub
	derived := ""
	if len(addr) == 0 {
		derived = hex_npub(ui.account_ref)
		addr = len(derived) > 0 ? derived : ui.account_ref
	}
	xdc.self_addr = strings.clone(addr)
	xdc.self_name = strings.clone(len(info.name) > 0 ? info.name : addr)
	if len(derived) > 0 {
		delete(derived)
	}
	if !xdc.serving {
		xdc.serving = xdc_serve_start()
	}
	url := fmt.aprintf("http://127.0.0.1:%d/", xdc.port)
	serving := xdc.serving
	sync.unlock(&xdc.mutex)
	defer delete(url)

	if !serving {
		ui.client_status = fmt.aprintf("couldn't open %s. Please try again.", view.name)
		return
	}
	// The next reload fills the update list for this session.
	load_timeline(client, ui)

	fmt.eprintfln("webxdc: serving %s at %s", view.name, url)
	if !web_open(url, view.name) {
		ui.client_status = fmt.aprintf("couldn't open %s. Please try again.", view.name)
	}
}

// ── The server ──────────────────────────────────────────────────────

@(private = "file")
listener: net.TCP_Socket
@(private = "file")
xdc_worker: ^thread.Thread
@(private = "file")
xdc_connection: net.TCP_Socket
@(private = "file")
xdc_stopping: bool

@(private)
xdc_stop :: proc() {
	if xdc_worker == nil {return}
	sync.lock(&xdc.mutex)
	xdc_stopping = true
	net.shutdown(listener, .Both)
	if xdc_connection != {} {net.shutdown(xdc_connection, .Both)}
	sync.unlock(&xdc.mutex)
	thread.join(xdc_worker)
	thread.destroy(xdc_worker)
	net.close(listener)
	xdc_worker = nil
}

// Caller holds the mutex. Binds an ephemeral loopback port and leaves
// one thread accepting for the rest of the process.
@(private = "file")
xdc_serve_start :: proc() -> bool {
	sock, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if err != nil {
		fmt.eprintfln("webxdc: listen failed: %v", err)
		return false
	}
	endpoint, ep_err := net.bound_endpoint(sock)
	if ep_err != nil {
		net.close(sock)
		fmt.eprintfln("webxdc: bound_endpoint failed: %v", ep_err)
		return false
	}
	listener = sock
	xdc.port = endpoint.port
	xdc_worker = thread.create_and_start(xdc_serve)
	return true
}

@(private = "file")
xdc_serve :: proc() {
	context.allocator = reload_allocator()
	for {
		client, _, err := net.accept_tcp(listener)
		if err != nil {
			return
		}
		sync.lock(&xdc.mutex)
		if xdc_stopping {
			sync.unlock(&xdc.mutex)
			net.close(client)
			return
		}
		xdc_connection = client
		sync.unlock(&xdc.mutex)
		xdc_handle(client)
		sync.lock(&xdc.mutex)
		xdc_connection = {}
		net.close(client)
		sync.unlock(&xdc.mutex)
	}
}

@(private = "file")
xdc_handle :: proc(sock: net.TCP_Socket) {
	buf := make([]u8, XDC_MAX_HEADER + XDC_MAX_UPDATE)
	defer delete(buf)

	// A POST arrives as headers first and body after, often in separate
	// segments, so read until Content-Length bytes of body are in hand.
	// Reading once left every sendUpdate with an empty body.
	total, head_end, want := 0, -1, 0
	for total < len(buf) {
		n, err := net.recv_tcp(sock, buf[total:])
		if err != nil || n <= 0 {
			break
		}
		total += n
		if head_end < 0 {
			if cut := strings.index(string(buf[:total]), "\r\n\r\n"); cut >= 0 {
				head_end = cut + 4
				want = xdc_content_length(string(buf[:cut]))
			}
		}
		if head_end >= 0 && total - head_end >= want {
			break
		}
	}
	if head_end < 0 {
		return
	}
	head := string(buf[:head_end - 4])
	body := string(buf[head_end:total])

	_ = head
	line, _, _ := strings.partition(head, "\r\n")
	method, _, tail := strings.partition(line, " ")
	target, _, _ := strings.partition(tail, " ")
	path, _, query := strings.partition(target, "?")

	sync.lock(&xdc.mutex)
	api := fmt.tprintf("/%s/api/", xdc.token)
	view, token_len := xdc.view, len(xdc.token)
	sync.unlock(&xdc.mutex)

	if token_len == 0 || view == nil {
		xdc_reply(sock, "404 Not Found", "text/plain", "not found")
		return
	}

	// The app's own files answer at the root, because a bundler emits
	// absolute paths ("/assets/index.js") that no prefix survives. The
	// update API keeps the unguessable prefix: another local process
	// may read files that came from the group anyway, but it may not
	// read this app's state or post as the user.
	switch {
	case path == "/webxdc.js":
		js := xdc_shim()
		defer delete(js)
		xdc_reply(sock, "200 OK", "text/javascript", js)
	case path == fmt.tprintf("%supdates", api):
		payload := xdc_updates_json(query)
		defer delete(payload)
		xdc_reply(sock, "200 OK", "application/json", payload)
	case path == fmt.tprintf("%ssend", api) && method == "POST":
		xdc_queue_send(body)
		xdc_reply(sock, "200 OK", "application/json", "{}")
	case strings.has_prefix(path, api):
		xdc_reply(sock, "404 Not Found", "text/plain", "not found")
	case:
		xdc_file(sock, view, path == "/" ? "index.html" : strings.trim_prefix(path, "/"))
	}
}

@(private = "file")
xdc_content_length :: proc(head: string) -> int {
	rest := head
	for line in strings.split_lines_iterator(&rest) {
		key, _, value := strings.partition(line, ":")
		if !strings.equal_fold(strings.trim_space(key), "content-length") {
			continue
		}
		length, ok := strconv.parse_int(strings.trim_space(value))
		if !ok || length < 0 || length > XDC_MAX_UPDATE {
			return 0
		}
		return length
	}
	return 0
}

// Every response carries the sandbox: 'self' only, so the app cannot
// reach the network even though it runs in the user's browser.
@(private = "file")
xdc_reply :: proc(sock: net.TCP_Socket, status, content_type, body: string) {
	head := fmt.tprintf(
		"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nContent-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:; worker-src 'self' blob:; child-src 'self' blob:; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; form-action 'none'\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
		status,
		content_type,
		len(body),
	)
	xdc_write(sock, transmute([]u8)head)
	xdc_write(sock, transmute([]u8)body)
}

@(private = "file")
xdc_write :: proc(sock: net.TCP_Socket, bytes: []u8) {
	sent := 0
	for sent < len(bytes) {
		n, err := net.send_tcp(sock, bytes[sent:])
		if err != nil || n <= 0 {
			return
		}
		sent += n
	}
}

@(private = "file")
xdc_file :: proc(sock: net.TCP_Socket, view: ^Xdc_View, rel: string) {
	if strings.contains(rel, "..") {
		xdc_reply(sock, "403 Forbidden", "text/plain", "forbidden")
		return
	}
	for entry in view.arc.entries {
		if entry.name != rel {
			continue
		}
		bytes, ok := arc_entry_bytes(view.arc, entry.index)
		if !ok {
			break
		}
		defer delete(bytes)
		xdc_reply(sock, "200 OK", xdc_mime(rel), string(bytes))
		return
	}
	xdc_reply(sock, "404 Not Found", "text/plain", "not found")
}

@(private = "file")
xdc_mime :: proc(name: string) -> string {
	lower := strings.to_lower(name, context.temp_allocator)
	switch {
	case strings.has_suffix(lower, ".html"), strings.has_suffix(lower, ".htm"):
		return "text/html; charset=utf-8"
	case strings.has_suffix(lower, ".js"), strings.has_suffix(lower, ".mjs"):
		return "text/javascript"
	case strings.has_suffix(lower, ".css"):
		return "text/css"
	case strings.has_suffix(lower, ".json"):
		return "application/json"
	case strings.has_suffix(lower, ".svg"):
		return "image/svg+xml"
	case strings.has_suffix(lower, ".png"):
		return "image/png"
	case strings.has_suffix(lower, ".jpg"), strings.has_suffix(lower, ".jpeg"):
		return "image/jpeg"
	case strings.has_suffix(lower, ".gif"):
		return "image/gif"
	case strings.has_suffix(lower, ".webp"):
		return "image/webp"
	case strings.has_suffix(lower, ".wasm"):
		return "application/wasm"
	case strings.has_suffix(lower, ".woff2"):
		return "font/woff2"
	}
	return "application/octet-stream"
}

// The updates after `serial`, in the webxdc listener shape. Payloads
// are stored as the app wrote them, so they splice into the array as
// raw JSON.
xdc_updates_json :: proc(query: string) -> string {
	from := 0
	if strings.has_prefix(query, "serial=") {
		from, _ = strconv.parse_int(query[len("serial="):])
	}

	sync.lock(&xdc.mutex)
	defer sync.unlock(&xdc.mutex)

	// Confirmed updates first, then the ones still in flight, so the
	// app's own send is delivered in the order it made it.
	all := make([dynamic]string, context.temp_allocator)
	append(&all, ..xdc.updates[:])
	append(&all, ..xdc.pending[:])

	out := strings.builder_make()
	strings.write_byte(&out, '[')
	for i in max(from, 0) ..< len(all) {
		if strings.builder_len(out) > 1 {
			strings.write_byte(&out, ',')
		}
		fmt.sbprintf(&out, `{{"payload":%s,"serial":%d,"max_serial":%d}}`, all[i], i + 1, len(all))
	}
	strings.write_byte(&out, ']')
	return strings.to_string(out)
}

@(private = "file")
xdc_queue_send :: proc(body: string) {
	if len(body) == 0 || len(body) > XDC_MAX_UPDATE {
		return
	}
	sync.lock(&xdc.mutex)
	defer sync.unlock(&xdc.mutex)
	append(&xdc.outbox, strings.clone(body))

	// The app sees its own update now, not after a relay round trip:
	// the same optimistic overlay the message rows use. The confirmed
	// copy replaces it in xdc_collect_end.
	append(&xdc.pending, strings.clone(body))
}

// The webxdc API surface the apps expect. Realtime channels and the
// chat/file integrations are stubs: no relay access for the first, no
// reason to grant an app the second.
@(private = "file")
xdc_shim :: proc() -> string {
	sync.lock(&xdc.mutex)
	base := fmt.tprintf("/%s/api/", xdc.token)
	addr := xdc_js_string(xdc.self_addr)
	name := xdc_js_string(xdc.self_name)
	sync.unlock(&xdc.mutex)

	return fmt.aprintf(
		`window.webxdc = (() => {{
  const base = "%s";
  let listener = null, serial = 0, realtime = false, timer = null, busy = false;
  // Exactly one poll in flight and one timer pending: a second loop
  // races on the serial and redelivers updates the listener saw.
  async function poll() {{
    if (busy) {{ return; }}
    busy = true;
    clearTimeout(timer);
    try {{
      const r = await fetch(base + "updates?serial=" + serial);
      for (const u of await r.json()) {{ serial = u.serial; if (listener) listener(u); }}
    }} catch (e) {{}}
    busy = false;
    timer = setTimeout(poll, %d);
  }}
  return {{
    selfAddr: "%s",
    selfName: "%s",
    sendUpdate(update, descr) {{
      // Poll straight after: an app that waits for its own update
      // should not wait out the poll interval for it.
      fetch(base + "send", {{method: "POST", body: JSON.stringify(update.payload)}}).then(poll);
    }},
    setUpdateListener(cb, ser) {{ listener = cb; serial = ser | 0; poll(); return Promise.resolve(); }},
    joinRealtimeChannel() {{
      // No transport for kind 20932, but the shape of the API is the
      // contract: a second join before leave() is an error.
      if (realtime) {{ throw new Error("realtime channel already joined"); }}
      realtime = true;
      return {{send() {{}}, setListener() {{}}, leave() {{ realtime = false; }}}};
    }},
    sendToChat() {{ return Promise.reject(new Error("not supported")); }},
    importFiles() {{ return Promise.reject(new Error("not supported")); }},
  }};
}})();
`,
		base,
		XDC_POLL_MS,
		addr,
		name,
	)
}

// A display name goes into a JS string literal; drop what would break
// out of it rather than writing an escaper.
@(private = "file")
xdc_js_string :: proc(s: string) -> string {
	out, _ := strings.remove_all(s, "\"", context.temp_allocator)
	out, _ = strings.remove_all(out, "\\", context.temp_allocator)
	out, _ = strings.remove_all(out, "\n", context.temp_allocator)
	return out
}
