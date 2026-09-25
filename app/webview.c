// wn-webview: the process that runs a webxdc app, so the app can draw
// it inside a modal of its own.
//
// The page renders offscreen (a GtkOffscreenWindow, never mapped) into
// a cairo surface; the pixels are copied into a shared-memory buffer
// the parent maps and uploads as a streaming texture. Input travels
// the other way through a ring in the same buffer, synthesized onto
// the view's GdkWindow.
//
//   parent: input ring ──►  ┌──────────┐  ──► pixels ──► texture
//                           │ shm file │
//   child:  events  ◄────── └──────────┘  ◄── cairo draw, 60Hz
//
// It is a separate process because webkit_web_view_load_uri takes over
// the calling thread's GL context: in-process, the app's own renderer
// went black the moment a page loaded. Out of process the parent
// touches nothing but memory, and a crashing app cannot take the
// messenger down with it.
//
// WEBKIT_DISABLE_COMPOSITING_MODE is required: with accelerated
// compositing on, the page renders into a GL surface the offscreen
// draw never sees, and every frame comes back blank.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

#include "webview.h"
#include "helper_ipc.h"

#define WN_TICK_MS 16 // ~60Hz draw

struct WnWeb {
    GtkWidget *win;
    GtkWidget *view;
    char *origin; // the launch URL; navigation may not leave it
    cairo_surface_t *surface;
    cairo_t *cr;
    struct WnShm *shm;
    int w, h;         // current page size
    int cap_w, cap_h; // what the shared buffer can hold
};

// Our own origin, plus the in-page schemes a running app uses. Any
// other destination is refused rather than navigated to.
static gboolean on_decide(WebKitWebView *view, WebKitPolicyDecision *decision,
                          WebKitPolicyDecisionType type, gpointer data) {
    (void)view;
    struct WnWeb *web = data;
    if (type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION &&
        type != WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
        return FALSE;
    }

    WebKitNavigationAction *action = webkit_navigation_policy_decision_get_navigation_action(
        WEBKIT_NAVIGATION_POLICY_DECISION(decision));
    const char *uri = webkit_uri_request_get_uri(webkit_navigation_action_get_request(action));
    if (uri && (strncmp(uri, web->origin, strlen(web->origin)) == 0 ||
                strncmp(uri, "blob:", 5) == 0 || strncmp(uri, "about:", 6) == 0)) {
        return FALSE;
    }

    webkit_policy_decision_ignore(decision);
    return TRUE;
}

// Draw the page and publish it. cairo's ARGB32 is premultiplied BGRA
// in memory on little endian; pages are opaque, so the swizzle is all
// that is needed.
// The parent asks for a size in device pixels and a page zoom, so the
// page renders at the resolution it is displayed at instead of being
// scaled up afterwards. Capacity is fixed at startup; a request past
// it is clamped.
static int wn_resize(struct WnWeb *web) {
    unsigned want_w = __atomic_load_n(&web->shm->want_w, __ATOMIC_ACQUIRE);
    unsigned want_h = __atomic_load_n(&web->shm->want_h, __ATOMIC_ACQUIRE);
    unsigned zoom = __atomic_load_n(&web->shm->zoom_milli, __ATOMIC_ACQUIRE);
    if (want_w < 1 || want_h < 1) {
        return 0;
    }
    if ((int)want_w > web->cap_w) {
        want_w = web->cap_w;
    }
    if ((int)want_h > web->cap_h) {
        want_h = web->cap_h;
    }
    if (zoom >= 100 && zoom <= 4000) {
        double level = zoom / 1000.0;
        if (level != webkit_web_view_get_zoom_level(WEBKIT_WEB_VIEW(web->view))) {
            webkit_web_view_set_zoom_level(WEBKIT_WEB_VIEW(web->view), level);
        }
    }
    if ((int)want_w == web->w && (int)want_h == web->h) {
        return 0;
    }

    web->w = want_w;
    web->h = want_h;
    cairo_destroy(web->cr);
    cairo_surface_destroy(web->surface);
    web->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, web->w, web->h);
    web->cr = cairo_create(web->surface);
    gtk_widget_set_size_request(web->view, web->w, web->h);
    gtk_window_resize(GTK_WINDOW(web->win), web->w, web->h);
    return 1;
}

static void wn_publish(struct WnWeb *web) {
    cairo_save(web->cr);
    cairo_set_source_rgb(web->cr, 1, 1, 1);
    cairo_paint(web->cr);
    cairo_restore(web->cr);

    // The view sits at its allocation inside the offscreen window;
    // without the shift, that offset clips the page's left edge.
    GtkAllocation alloc;
    gtk_widget_get_allocation(web->view, &alloc);
    cairo_save(web->cr);
    cairo_translate(web->cr, -alloc.x, -alloc.y);
    gtk_widget_draw(web->view, web->cr);
    cairo_restore(web->cr);
    cairo_surface_flush(web->surface);

    const unsigned char *src = cairo_image_surface_get_data(web->surface);
    int stride = cairo_image_surface_get_stride(web->surface);
    unsigned char *dst = web->shm->pixels;
    for (int y = 0; y < web->h; y++) {
        const unsigned char *row = src + (size_t)y * stride;
        unsigned char *out = dst + (size_t)y * web->w * 4;
        for (int x = 0; x < web->w; x++) {
            out[x * 4 + 0] = row[x * 4 + 2];
            out[x * 4 + 1] = row[x * 4 + 1];
            out[x * 4 + 2] = row[x * 4 + 0];
            out[x * 4 + 3] = 255;
        }
    }
    web->shm->w = web->w;
    web->shm->h = web->h;
    __atomic_add_fetch(&web->shm->seq, 1, __ATOMIC_RELEASE);
}

// GTK3 drops an event with no device attached, so every synthesized
// event picks up the default seat's pointer or keyboard.
static void wn_dispatch(struct WnWeb *web, GdkEvent *event, gboolean keyboard) {
    GdkWindow *window = gtk_widget_get_window(web->view);
    if (!window) {
        gdk_event_free(event);
        return;
    }
    event->any.window = g_object_ref(window);
    event->any.send_event = TRUE;

    GdkSeat *seat = gdk_display_get_default_seat(gdk_display_get_default());
    gdk_event_set_device(event,
                         keyboard ? gdk_seat_get_keyboard(seat) : gdk_seat_get_pointer(seat));

    gtk_main_do_event(event);
    gdk_event_free(event);
}

// An offscreen window is never the active toplevel, so WebKit thinks
// the document has no focus: editors ignore clicks and typing. A
// synthesized focus-in makes the view believe otherwise. Re-sent on
// every click, because WebKit drops the state when it re-evaluates the
// (never-active) toplevel.
static void wn_focus_in(struct WnWeb *web) {
    GdkEvent *event = gdk_event_new(GDK_FOCUS_CHANGE);
    event->focus_change.in = TRUE;
    wn_dispatch(web, event, TRUE);
}

static void wn_apply(struct WnWeb *web, const struct WnEvent *in) {
    switch (in->kind) {
    case WN_EV_MOVE: {
        GdkEvent *event = gdk_event_new(GDK_MOTION_NOTIFY);
        event->motion.x = in->x;
        event->motion.y = in->y;
        event->motion.x_root = in->x;
        event->motion.y_root = in->y;
        event->motion.state = in->mods;
        event->motion.time = GDK_CURRENT_TIME;
        wn_dispatch(web, event, FALSE);
        break;
    }
    case WN_EV_DOWN:
    case WN_EV_UP: {
        GdkEvent *event =
            gdk_event_new(in->kind == WN_EV_DOWN ? GDK_BUTTON_PRESS : GDK_BUTTON_RELEASE);
        event->button.x = in->x;
        event->button.y = in->y;
        event->button.x_root = in->x;
        event->button.y_root = in->y;
        event->button.button = in->arg;
        event->button.state = in->mods;
        event->button.time = GDK_CURRENT_TIME;
        wn_dispatch(web, event, FALSE);
        if (in->kind == WN_EV_DOWN) {
            wn_focus_in(web);
        }
        break;
    }
    case WN_EV_SCROLL: {
        GdkEvent *event = gdk_event_new(GDK_SCROLL);
        event->scroll.x = in->x;
        event->scroll.y = in->y;
        event->scroll.x_root = in->x;
        event->scroll.y_root = in->y;
        event->scroll.direction = GDK_SCROLL_SMOOTH;
        event->scroll.delta_x = in->dx;
        event->scroll.delta_y = in->dy;
        event->scroll.time = GDK_CURRENT_TIME;
        wn_dispatch(web, event, FALSE);
        break;
    }
    case WN_EV_KEY_DOWN:
    case WN_EV_KEY_UP: {
        GdkEvent *event =
            gdk_event_new(in->kind == WN_EV_KEY_DOWN ? GDK_KEY_PRESS : GDK_KEY_RELEASE);
        event->key.keyval = in->arg;
        event->key.state = in->mods;
        event->key.time = GDK_CURRENT_TIME;

        // WebKit maps the keyval back to a keycode for its own key
        // handling; without one, printable keys arrive as dead keys.
        GdkKeymapKey *keys = NULL;
        int n = 0;
        if (gdk_keymap_get_entries_for_keyval(gdk_keymap_get_for_display(gdk_display_get_default()),
                                              in->arg, &keys, &n) &&
            n > 0) {
            event->key.hardware_keycode = keys[0].keycode;
            event->key.group = keys[0].group;
        }
        g_free(keys);

        wn_dispatch(web, event, TRUE);
        break;
    }
    default:
        break;
    }
}

// One tick: drain what the parent queued, then publish a frame. The
// parent going away (quit set, or the pipe on stdin closing) ends it.
static gboolean on_tick(gpointer data) {
    struct WnWeb *web = data;
    struct WnShm *shm = web->shm;

    if (__atomic_load_n(&shm->quit, __ATOMIC_ACQUIRE)) {
        gtk_main_quit();
        return G_SOURCE_REMOVE;
    }

    unsigned head = __atomic_load_n(&shm->head, __ATOMIC_ACQUIRE);
    while (shm->tail != head) {
        wn_apply(web, &shm->events[shm->tail % WN_EV_CAP]);
        shm->tail++;
    }

    // A resized widget has not been allocated yet; drawing it now trips
    // a GTK assertion and paints nothing. Publish on the next tick.
    if (wn_resize(web)) {
        return G_SOURCE_CONTINUE;
    }
    wn_publish(web);
    return G_SOURCE_CONTINUE;
}

// The parent holds the write end of our stdin; when it dies, ours
// reads EOF and the app goes with it.
static gboolean on_parent_gone(GIOChannel *source, GIOCondition condition, gpointer data) {
    (void)source;
    (void)condition;
    (void)data;
    gtk_main_quit();
    return G_SOURCE_REMOVE;
}

// WN_DEBUG only: the page's console and uncaught errors, forwarded to
// our stdout. WebKit's own write-console-messages-to-stdout lives in
// the web process and never reached the app's log.
static void on_console(WebKitUserContentManager *ucm, WebKitJavascriptResult *result,
                       gpointer data) {
    (void)ucm;
    (void)data;
    JSCValue *value = webkit_javascript_result_get_js_value(result);
    char *text = jsc_value_to_string(value);
    g_printerr("webxdc console: %s\n", text);
    g_free(text);
}

static const char *WN_CONSOLE_HOOK =
    "(() => {"
    "  const post = (tag, args) => { try { window.webkit.messageHandlers.wnlog.postMessage("
    "    tag + ': ' + Array.from(args).map(a => (a && a.stack) ? a.stack : String(a)).join(' ')); "
    "} catch (e) {} };"
    "  for (const level of ['log', 'warn', 'error']) {"
    "    const original = console[level];"
    "    console[level] = function () { post(level, arguments); original.apply(console, "
    "arguments); };"
    "  }"
    "  window.addEventListener('error', e => post('uncaught', [e.message + ' @ ' + e.filename + "
    "':' + e.lineno]));"
    "  window.addEventListener('unhandledrejection', e => post('rejected', [e.reason]));"
    "})();";

int main(int argc, char **argv) {
    if (argc < 5) {
        g_printerr("usage: wn-webview <url> <shm-token> <width> <height>\n");
        return 2;
    }
    const char *url = argv[1];
    // argv[3]/argv[4] are the buffer's capacity, not the page size: the
    // parent asks for a size per frame through the shared header.
    int w = atoi(argv[3]);
    int h = atoi(argv[4]);

    if (w < 1 || w > 3840 || h < 1 || h > 2160)
        return 2;
    size_t size = sizeof(struct WnShm) + (size_t)w * h * 4;
    WnIpc *ipc = wn_ipc_open(argv[2], size);
    if (!ipc) {
        g_printerr("wn-webview: cannot open shared memory\n");
        return 2;
    }
    struct WnShm *shm = wn_ipc_data(ipc);

    // Overridable: with compositing on, a page can use WebGL from a
    // worker (OffscreenCanvas), but the offscreen draw comes back
    // blank, so the default stays off.
    g_setenv("WEBKIT_DISABLE_COMPOSITING_MODE", "1", FALSE);
    if (!gtk_init_check(&argc, &argv)) {
        g_printerr("wn-webview: no display\n");
        return 2;
    }

    struct WnWeb *web = calloc(1, sizeof *web);
    web->origin = g_strdup(url);
    web->shm = shm;
    web->w = w;
    web->h = h;
    web->cap_w = w;
    web->cap_h = h;
    web->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    web->cr = cairo_create(web->surface);
    web->win = gtk_offscreen_window_new();

    // Ephemeral: nothing the app stores outlives the process.
    WebKitWebsiteDataManager *data = webkit_website_data_manager_new_ephemeral();
    WebKitWebContext *context = webkit_web_context_new_with_website_data_manager(data);
    WebKitUserContentManager *ucm = webkit_user_content_manager_new();
    web->view = g_object_new(WEBKIT_TYPE_WEB_VIEW, "web-context", context, "user-content-manager",
                             ucm, NULL);
    if (g_getenv("WN_DEBUG")) {
        webkit_user_content_manager_register_script_message_handler(ucm, "wnlog");
        g_signal_connect(ucm, "script-message-received::wnlog", G_CALLBACK(on_console), NULL);
        webkit_user_content_manager_add_script(
            ucm, webkit_user_script_new(WN_CONSOLE_HOOK, WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
                                        WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, NULL, NULL));
    }
    g_signal_connect(web->view, "decide-policy", G_CALLBACK(on_decide), web);

    gtk_container_add(GTK_CONTAINER(web->win), web->view);
    gtk_widget_set_size_request(web->view, w, h);
    gtk_window_resize(GTK_WINDOW(web->win), w, h);
    gtk_widget_show_all(web->win);
    gtk_widget_grab_focus(web->view);
    wn_focus_in(web);
    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(web->view), url);

    GIOChannel *stdin_channel = g_io_channel_unix_new(STDIN_FILENO);
    g_io_add_watch(stdin_channel, G_IO_HUP | G_IO_ERR, on_parent_gone, NULL);
    g_timeout_add(WN_TICK_MS, on_tick, web);
    gtk_main();
    wn_ipc_close(ipc);
    return 0;
}
