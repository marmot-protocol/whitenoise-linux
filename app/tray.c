#include <gio/gio.h>
#include <string.h>

#define WATCHER "org.kde.StatusNotifierWatcher"
#define WATCHER_PATH "/StatusNotifierWatcher"
#define ITEM "org.kde.StatusNotifierItem"
#define ITEM_PATH "/StatusNotifierItem"
#define MENU "com.canonical.dbusmenu"
#define MENU_PATH "/MenuBar"
#define PROPERTY(name, type) "<property name='" name "' type='" type "' access='read'/>"
#define ARG(type) "<arg type='" type "' direction='in'/>"
#define OUT(type) "<arg type='" type "' direction='out'/>"
#define METHOD(name, args) "<method name='" name "'>" args "</method>"

// clang-format off
static const char tray_xml[] =
    "<node><interface name='" ITEM "'>"
    PROPERTY("Category", "s") PROPERTY("Id", "s") PROPERTY("Title", "s")
    PROPERTY("Status", "s") PROPERTY("WindowId", "i") PROPERTY("IconName", "s")
    PROPERTY("IconPixmap", "a(iiay)") PROPERTY("ToolTip", "(sa(iiay)ss)")
    PROPERTY("Menu", "o") PROPERTY("ItemIsMenu", "b")
    METHOD("Activate", ARG("i") ARG("i"))
    METHOD("ProvideXdgActivationToken", ARG("s"))
    "<signal name='NewToolTip'/></interface><interface name='" MENU "'>"
    PROPERTY("Version", "u") PROPERTY("TextDirection", "s") PROPERTY("Status", "s")
    PROPERTY("IconThemePath", "as")
    METHOD("GetLayout", ARG("i") ARG("i") ARG("as") OUT("u") OUT("(ia{sv}av)"))
    METHOD("GetGroupProperties", ARG("ai") ARG("as") OUT("a(ia{sv})"))
    METHOD("GetProperty", ARG("i") ARG("s") OUT("v"))
    METHOD("Event", ARG("i") ARG("s") ARG("v") ARG("u"))
    METHOD("EventGroup", ARG("a(isvu)") OUT("ai"))
    METHOD("AboutToShow", ARG("i") OUT("b"))
    METHOD("AboutToShowGroup", ARG("ai") OUT("ai") OUT("ai"))
    "</interface></node>";
// clang-format on

// The bus thread owns the exported objects. It only wakes SDL; it never touches a window.
enum { PENDING, UNAVAILABLE, READY };
enum { SHOW = 1, QUIT = 2 };
enum { ROOT, SHOW_ENTRY, QUIT_ENTRY, ENTRY_COUNT };
static struct {
    GThread *thread;
    GMainContext *context;
    GCancellable *cancel;
    GMutex lock;
    char *next_tooltip;
    char *show_token;
    char *tooltip;
    char *labels[ENTRY_COUNT];
    GVariant *icon;
    void (*wake)(void);
    gint status;
    gint actions;
} tray;

typedef struct {
    const char *name;
    GHashTable *readers;
    gboolean watcher_online;
    char *token_sender;
    char *token;
} Tray_Bus;

static void set_status(gint status) {
    if (g_atomic_int_get(&tray.status) != status) {
        g_atomic_int_set(&tray.status, status);
        tray.wake();
    }
}

static void send_action(Tray_Bus *session, const char *sender, guint action) {
    g_mutex_lock(&tray.lock);
    if (action == SHOW) {
        g_clear_pointer(&tray.show_token, g_free);
        if (g_strcmp0(sender, session->token_sender) == 0) {
            tray.show_token = g_steal_pointer(&session->token);
            g_clear_pointer(&session->token_sender, g_free);
        }
    }
    g_atomic_int_or(&tray.actions, action);
    g_mutex_unlock(&tray.lock);
    tray.wake();
}

static void unwatch_name(gpointer id) {
    g_bus_unwatch_name(GPOINTER_TO_UINT(id));
}

static void reader_arrived(GDBusConnection *bus, const char *name, const char *owner,
                           gpointer data) {
    (void)bus;
    (void)owner;
    Tray_Bus *session = data;
    if (session->watcher_online && g_hash_table_contains(session->readers, name)) {
        set_status(READY);
    }
}

static void reader_left(GDBusConnection *bus, const char *name, gpointer data) {
    (void)bus;
    Tray_Bus *session = data;
    if (g_hash_table_remove(session->readers, name) && g_hash_table_size(session->readers) == 0 &&
        g_atomic_int_get(&tray.status) == READY) {
        set_status(UNAVAILABLE);
    }
}

static GVariant *tray_property(GDBusConnection *bus, const char *sender, const char *path,
                               const char *interface, const char *prop, GError **error,
                               gpointer data) {
    (void)path;
    (void)error;
    if (strcmp(interface, ITEM) == 0) {
        if (strcmp(prop, "Category") == 0) {
            return g_variant_new_string("Communications");
        }
        if (strcmp(prop, "Id") == 0) {
            return g_variant_new_string("dev.ipf.whitenoise");
        }
        if (strcmp(prop, "Title") == 0) {
            return g_variant_new_string("White Noise");
        }
        if (strcmp(prop, "Status") == 0) {
            return g_variant_new_string("Active");
        }
        if (strcmp(prop, "WindowId") == 0) {
            return g_variant_new_int32(0);
        }
        if (strcmp(prop, "IconName") == 0) {
            return g_variant_new_string("");
        }
        if (strcmp(prop, "IconPixmap") == 0) {
            // Plasma's watcher can report a host while its panel is gone.
            // Watch the clients that fetch the icon, not the watcher's claim.
            Tray_Bus *session = data;
            if (session->watcher_online && !g_hash_table_contains(session->readers, sender)) {
                guint id =
                    g_bus_watch_name_on_connection(bus, sender, G_BUS_NAME_WATCHER_FLAGS_NONE,
                                                   reader_arrived, reader_left, session, NULL);
                g_hash_table_insert(session->readers, g_strdup(sender), GUINT_TO_POINTER(id));
            }
            return g_variant_ref(tray.icon);
        }
        if (strcmp(prop, "ToolTip") == 0) {
            return g_variant_new("(sa(iiay)ss)", "", NULL, tray.tooltip, "");
        }
        if (strcmp(prop, "Menu") == 0) {
            return g_variant_new_object_path(MENU_PATH);
        }
        if (strcmp(prop, "ItemIsMenu") == 0) {
            return g_variant_new_boolean(FALSE);
        }
    } else {
        if (strcmp(prop, "Version") == 0) {
            return g_variant_new_uint32(3);
        }
        if (strcmp(prop, "TextDirection") == 0) {
            return g_variant_new_string("ltr");
        }
        if (strcmp(prop, "Status") == 0) {
            return g_variant_new_string("normal");
        }
        if (strcmp(prop, "IconThemePath") == 0) {
            return g_variant_new_strv(NULL, 0);
        }
    }
    return NULL;
}

static GVariant *entry_property(gint id, const char *prop) {
    if (id == ROOT && strcmp(prop, "children-display") == 0) {
        return g_variant_new_string("submenu");
    }
    if (id != ROOT && strcmp(prop, "label") == 0) {
        return g_variant_new_string(tray.labels[id]);
    }
    return NULL;
}

static GVariant *entry_props(gint id, GVariant *names) {
    GVariantBuilder props;
    g_variant_builder_init(&props, G_VARIANT_TYPE_VARDICT);
    if (g_variant_n_children(names) == 0) {
        const char *prop = id == ROOT ? "children-display" : "label";
        g_variant_builder_add(&props, "{sv}", prop, entry_property(id, prop));
    } else {
        GVariantIter iter;
        const char *prop;
        g_variant_iter_init(&iter, names);
        while (g_variant_iter_next(&iter, "&s", &prop)) {
            GVariant *value = entry_property(id, prop);
            if (value) {
                g_variant_builder_add(&props, "{sv}", prop, value);
            }
        }
    }
    return g_variant_builder_end(&props);
}

static GVariant *entry_layout(gint id, gint depth, GVariant *names) {
    GVariantBuilder children;
    g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
    if (id == ROOT && depth != 0) {
        for (gint item = SHOW_ENTRY; item < ENTRY_COUNT; item++) {
            g_variant_builder_add(&children, "v", entry_layout(item, 0, names));
        }
    }
    return g_variant_new("(i@a{sv}av)", id, entry_props(id, names), &children);
}

static gboolean entry_event(Tray_Bus *session, const char *sender, gint id, const char *event) {
    if (id < ROOT || id >= ENTRY_COUNT) {
        return FALSE;
    }
    if (strcmp(event, "clicked") == 0) {
        if (id == SHOW_ENTRY) {
            send_action(session, sender, SHOW);
        }
        if (id == QUIT_ENTRY) {
            send_action(session, sender, QUIT);
        }
    }
    return TRUE;
}

static void tray_method(GDBusConnection *bus, const char *sender, const char *path,
                        const char *interface, const char *method, GVariant *args,
                        GDBusMethodInvocation *call, gpointer data) {
    (void)bus;
    (void)path;
    Tray_Bus *session = data;
    GVariant *reply = NULL;
    if (strcmp(interface, ITEM) == 0) {
        if (strcmp(method, "ProvideXdgActivationToken") == 0) {
            const char *token;
            g_variant_get(args, "(&s)", &token);
            g_free(session->token);
            g_free(session->token_sender);
            session->token = g_strdup(token);
            session->token_sender = g_strdup(sender);
        } else {
            send_action(session, sender, SHOW);
        }
    } else if (strcmp(method, "GetLayout") == 0) {
        gint id, depth;
        GVariant *names;
        g_variant_get(args, "(ii@as)", &id, &depth, &names);
        if (id >= ROOT && id < ENTRY_COUNT) {
            reply = g_variant_new("(u@(ia{sv}av))", 1u, entry_layout(id, depth, names));
        }
        g_variant_unref(names);
        if (!reply) {
            goto invalid;
        }
    } else if (strcmp(method, "GetGroupProperties") == 0) {
        GVariant *ids, *names;
        g_variant_get(args, "(@ai@as)", &ids, &names);
        GVariantBuilder props;
        g_variant_builder_init(&props, G_VARIANT_TYPE("a(ia{sv})"));
        GVariantIter iter;
        g_variant_iter_init(&iter, ids);
        if (g_variant_iter_n_children(&iter) == 0) {
            for (gint id = ROOT; id < ENTRY_COUNT; id++) {
                g_variant_builder_add(&props, "(i@a{sv})", id, entry_props(id, names));
            }
        } else {
            gint id;
            while (g_variant_iter_next(&iter, "i", &id)) {
                if (id >= ROOT && id < ENTRY_COUNT) {
                    g_variant_builder_add(&props, "(i@a{sv})", id, entry_props(id, names));
                }
            }
        }
        reply = g_variant_new("(a(ia{sv}))", &props);
        g_variant_unref(ids);
        g_variant_unref(names);
    } else if (strcmp(method, "GetProperty") == 0) {
        gint id;
        const char *prop;
        g_variant_get(args, "(i&s)", &id, &prop);
        if (id < ROOT || id >= ENTRY_COUNT) {
            goto invalid;
        }
        GVariant *value = entry_property(id, prop);
        if (!value && (strcmp(prop, "enabled") == 0 || strcmp(prop, "visible") == 0)) {
            value = g_variant_new_boolean(TRUE);
        }
        if (!value && strcmp(prop, "disposition") == 0) {
            value = g_variant_new_string("normal");
        }
        if (!value && strcmp(prop, "label") == 0) {
            value = g_variant_new_string("");
        }
        if (!value) {
            goto invalid;
        }
        reply = g_variant_new("(v)", value);
    } else if (strcmp(method, "Event") == 0) {
        gint id;
        const char *event;
        g_variant_get_child(args, 0, "i", &id);
        g_variant_get_child(args, 1, "&s", &event);
        if (!entry_event(session, sender, id, event)) {
            goto invalid;
        }
    } else if (strcmp(method, "EventGroup") == 0) {
        GVariantIter *events;
        g_variant_get(args, "(a(isvu))", &events);
        GVariantBuilder errors;
        g_variant_builder_init(&errors, G_VARIANT_TYPE("ai"));
        gint id;
        const char *event;
        while (g_variant_iter_next(events, "(i&svu)", &id, &event, NULL, NULL)) {
            if (!entry_event(session, sender, id, event)) {
                g_variant_builder_add(&errors, "i", id);
            }
        }
        g_variant_iter_free(events);
        reply = g_variant_new("(ai)", &errors);
    } else if (strcmp(method, "AboutToShow") == 0) {
        reply = g_variant_new("(b)", FALSE);
    } else if (strcmp(method, "AboutToShowGroup") == 0) {
        reply = g_variant_new("(aiai)", NULL, NULL);
    }
    g_dbus_method_invocation_return_value(call, reply);
    return;

invalid:
    g_dbus_method_invocation_return_error_literal(call, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS,
                                                  "Unknown tray menu entry or property");
}

static const GDBusInterfaceVTable tray_vtable = {.method_call = tray_method,
                                                 .get_property = tray_property};

static void watcher_appeared(GDBusConnection *bus, const char *name, const char *owner,
                             gpointer data) {
    (void)owner;
    Tray_Bus *session = data;
    session->watcher_online = TRUE;
    g_dbus_connection_call(bus, name, WATCHER_PATH, WATCHER, "RegisterStatusNotifierItem",
                           g_variant_new("(s)", session->name), NULL,
                           G_DBUS_CALL_FLAGS_NO_AUTO_START, -1, tray.cancel, NULL, NULL);
}

static void watcher_vanished(GDBusConnection *bus, const char *name, gpointer data) {
    (void)bus;
    (void)name;
    Tray_Bus *session = data;
    session->watcher_online = FALSE;
    g_hash_table_remove_all(session->readers);
    set_status(UNAVAILABLE);
}

static gboolean startup_expired(gpointer unused) {
    (void)unused;
    if (g_atomic_int_get(&tray.status) == PENDING) {
        set_status(UNAVAILABLE);
    }
    return G_SOURCE_REMOVE;
}

static gpointer tray_bus(gpointer unused) {
    (void)unused;
    g_main_context_push_thread_default(tray.context);
    g_autofree char *address =
        g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, tray.cancel, NULL);
    g_autoptr(GDBusConnection) bus = address
                                         ? g_dbus_connection_new_for_address_sync(
                                               address,
                                               G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
                                                   G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,
                                               NULL, tray.cancel, NULL)
                                         : NULL;
    if (bus) {
        g_autofree char *suffix = g_strdup(g_dbus_connection_get_unique_name(bus) + 1);
        g_autofree char *name = g_strdup_printf("dev.ipf.whitenoise.StatusNotifierItem.n%s",
                                                g_strdelimit(suffix, ".", '_'));
        g_autoptr(GVariant) owned = g_dbus_connection_call_sync(
            bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
            "RequestName", g_variant_new("(su)", name, 4u), G_VARIANT_TYPE("(u)"),
            G_DBUS_CALL_FLAGS_NONE, 1000, tray.cancel, NULL);
        g_autoptr(GDBusNodeInfo) node = g_dbus_node_info_new_for_xml(tray_xml, NULL);
        g_autoptr(GHashTable) readers =
            g_hash_table_new_full(g_str_hash, g_str_equal, g_free, unwatch_name);
        Tray_Bus session = {.name = name, .readers = readers};
        guint item = g_dbus_connection_register_object(bus, ITEM_PATH, node->interfaces[0],
                                                       &tray_vtable, &session, NULL, NULL);
        guint menu = g_dbus_connection_register_object(bus, MENU_PATH, node->interfaces[1],
                                                       &tray_vtable, &session, NULL, NULL);
        guint code = 0;
        if (owned) {
            g_variant_get(owned, "(u)", &code);
        }
        if (code == 1 && item && menu) {
            guint watcher =
                g_bus_watch_name_on_connection(bus, WATCHER, G_BUS_NAME_WATCHER_FLAGS_NONE,
                                               watcher_appeared, watcher_vanished, &session, NULL);
            g_autoptr(GSource) deadline = g_timeout_source_new(1500);
            g_source_set_callback(deadline, startup_expired, NULL, NULL);
            g_source_attach(deadline, tray.context);
            while (!g_cancellable_is_cancelled(tray.cancel)) {
                g_mutex_lock(&tray.lock);
                char *title = g_steal_pointer(&tray.next_tooltip);
                g_mutex_unlock(&tray.lock);
                if (title) {
                    g_free(tray.tooltip);
                    tray.tooltip = title;
                    g_dbus_connection_emit_signal(bus, NULL, ITEM_PATH, ITEM, "NewToolTip", NULL,
                                                  NULL);
                }
                g_main_context_iteration(tray.context, TRUE);
            }
            g_source_destroy(deadline);
            g_bus_unwatch_name(watcher);
            g_hash_table_remove_all(readers);
        }
        if (item) {
            g_dbus_connection_unregister_object(bus, item);
        }
        if (menu) {
            g_dbus_connection_unregister_object(bus, menu);
        }
        g_dbus_connection_close_sync(bus, NULL, NULL);
        while (g_main_context_iteration(tray.context, FALSE)) {
        }
        g_free(session.token_sender);
        g_free(session.token);
    }
    set_status(UNAVAILABLE);
    g_main_context_pop_thread_default(tray.context);
    return NULL;
}

void wn_tray_start(const guint8 *rgba, gint w, gint h, const char *title, const char *show,
                   const char *quit, void (*wake)(void)) {
    gsize size = (gsize)w * h * 4;
    guint8 *argb = g_malloc(size);
    for (gsize i = 0; i < size; i += 4) {
        argb[i] = rgba[i + 3];
        memcpy(argb + i + 1, rgba + i, 3);
    }
    GVariantBuilder icon;
    g_variant_builder_init(&icon, G_VARIANT_TYPE("a(iiay)"));
    GVariant *pixels =
        g_variant_new_from_data(G_VARIANT_TYPE("ay"), argb, size, TRUE, g_free, argb);
    g_variant_builder_add(&icon, "(ii@ay)", w, h, pixels);
    tray.icon = g_variant_ref_sink(g_variant_builder_end(&icon));
    tray.tooltip = g_strdup(title);
    tray.labels[SHOW_ENTRY] = g_strdup(show);
    tray.labels[QUIT_ENTRY] = g_strdup(quit);
    tray.wake = wake;
    g_atomic_int_set(&tray.status, PENDING);
    tray.context = g_main_context_new();
    tray.cancel = g_cancellable_new();
    tray.thread = g_thread_new("wn-tray", tray_bus, NULL);
}

void wn_tray_tooltip(const char *title) {
    g_mutex_lock(&tray.lock);
    g_free(tray.next_tooltip);
    tray.next_tooltip = g_strdup(title);
    g_mutex_unlock(&tray.lock);
    g_main_context_wakeup(tray.context);
}

gint wn_tray_status(void) {
    return g_atomic_int_get(&tray.status);
}
guint wn_tray_actions(char **token) {
    if (g_atomic_int_get(&tray.actions) == 0) {
        return 0;
    }
    g_mutex_lock(&tray.lock);
    guint actions = g_atomic_int_and(&tray.actions, 0);
    *token = g_steal_pointer(&tray.show_token);
    g_mutex_unlock(&tray.lock);
    return actions;
}

void wn_tray_stop(void) {
    g_cancellable_cancel(tray.cancel);
    g_main_context_wakeup(tray.context);
    g_thread_join(tray.thread);
    g_clear_object(&tray.cancel);
    g_clear_pointer(&tray.context, g_main_context_unref);
    g_clear_pointer(&tray.icon, g_variant_unref);
    g_clear_pointer(&tray.tooltip, g_free);
    g_clear_pointer(&tray.next_tooltip, g_free);
    g_clear_pointer(&tray.show_token, g_free);
    g_clear_pointer(&tray.labels[SHOW_ENTRY], g_free);
    g_clear_pointer(&tray.labels[QUIT_ENTRY], g_free);
    g_atomic_int_set(&tray.actions, 0);
}
