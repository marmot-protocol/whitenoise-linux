// Declarative-macro toolkit for the glue layers. One home for the repeated
// shapes that used to be hand-copied per site: process-wide state cells,
// event-loop hops, callback-binding ceremony, status setters, and row-model
// mutation. Everything is re-exported through the crate prelude, so modules
// pick the macros up from their usual `use crate::*;`.
//
// The event-loop and binding macros pass the upgraded handle into a
// call-site-written closure (`|ui, args| …`) rather than interpolating a body
// next to a macro-local binding, which is what keeps them compatible with
// macro hygiene.

use crate::*;

// ─── Process-wide state cells ──────────────────────────────────────────────

/// A process-wide `Mutex<T>` singleton accessor, replacing the hand-written
/// `static S: OnceLock<Mutex<T>>` + `get_or_init` pair.
///
/// ```ignore
/// global_cell!(pub(crate) fn audio_meta() -> HashMap<String, String> = HashMap::new());
/// ```
macro_rules! global_cell {
    ($vis:vis fn $name:ident() -> $ty:ty = $init:expr) => {
        $vis fn $name() -> &'static ::std::sync::Mutex<$ty> {
            static S: ::std::sync::OnceLock<::std::sync::Mutex<$ty>> =
                ::std::sync::OnceLock::new();
            S.get_or_init(|| ::std::sync::Mutex::new($init))
        }
    };
}
pub(crate) use global_cell;

/// CRUD wrappers over a `global_cell!` map with `String` keys, replacing the
/// hand-written lock/get/clone and lock/insert boilerplate. Generate only the
/// ops the call sites use, or the unused ones warn as dead code.
///
/// ```ignore
/// map_ops!(pub(crate) audio_meta<String, String>:
///     get audio_meta_get, put audio_meta_put, remove audio_meta_remove);
/// ```
macro_rules! map_ops {
    (
        $vis:vis $cell:ident < $v:ty > :
        $(get $get:ident,)? $(put $put:ident,)? $(remove $remove:ident)? $(,)?
    ) => {
        $( $vis fn $get(key: &str) -> ::core::option::Option<$v> {
            $cell().lock().ok()?.get(key).cloned()
        } )?
        $( $vis fn $put(key: ::std::string::String, val: $v) {
            if let ::core::result::Result::Ok(mut m) = $cell().lock() {
                m.insert(key, val);
            }
        } )?
        $( $vis fn $remove(key: &str) {
            if let ::core::result::Result::Ok(mut m) = $cell().lock() {
                m.remove(key);
            }
        } )?
    };
}
pub(crate) use map_ops;

/// CRUD wrappers over a `global_cell!` string-keyed set.
///
/// ```ignore
/// set_ops!(pub(crate) offline_inflight:
///     contains offline_inflight_contains, insert offline_inflight_insert,
///     remove offline_inflight_remove);
/// ```
macro_rules! set_ops {
    (
        $vis:vis $cell:ident :
        $(contains $contains:ident,)? $(insert $insert:ident,)? $(remove $remove:ident)? $(,)?
    ) => {
        $( $vis fn $contains(key: &str) -> bool {
            $cell().lock().map(|s| s.contains(key)).unwrap_or(false)
        } )?
        $( $vis fn $insert(key: &str) {
            if let ::core::result::Result::Ok(mut s) = $cell().lock() {
                s.insert(key.to_string());
            }
        } )?
        $( $vis fn $remove(key: &str) {
            if let ::core::result::Result::Ok(mut s) = $cell().lock() {
                s.remove(key);
            }
        } )?
    };
}
pub(crate) use set_ops;

// ─── Event-loop hops ───────────────────────────────────────────────────────

/// Typed core of [`ui_update!`]: the declared parameter gives the call-site
/// closure its signature up front, so bodies whose first use of the handle is
/// a method call still infer.
pub(crate) fn run_on_ui(
    weak: Weak<WhiteNoiseLinux>,
    f: impl FnOnce(WhiteNoiseLinux) + Send + 'static,
) {
    let _ = slint::invoke_from_event_loop(move || {
        if let ::core::option::Option::Some(ui) = weak.upgrade() {
            f(ui);
        }
    });
}

/// Hop to the Slint event loop and run `f` with the upgraded window handle.
/// Replaces the `invoke_from_event_loop` + `upgrade() else { return }` pair;
/// the weak handle is cloned so `Fn`/multi-shot callers keep using theirs
/// (no more `weak2`/`weak3` chains). Write the closure with `move`, exactly
/// as the hand-written form did.
///
/// ```ignore
/// ui_update!(weak, move |ui| set_status_feedback(&ui, msg, true));
/// ```
macro_rules! ui_update {
    ($weak:expr, $f:expr) => {
        $crate::run_on_ui($weak.clone(), $f)
    };
}
pub(crate) use ui_update;

// ─── Callback binding ──────────────────────────────────────────────────────

/// Bind an `AppState` callback, absorbing the capture-clone/`as_weak`/
/// upgrade ceremony. The caller writes the handler as a closure whose first
/// parameter is the upgraded handle; zero-arg callbacks write `|ui|`.
/// `[cap, …]` lists the surrounding locals the handler captures (cloned per
/// binding, matching the old hand-written `let cap = cap.clone();` lines).
///
/// ```ignore
/// wire!(ui, on_promote_admin [backend_cell, group_ids], |ui, member_id| {
///     …body…
/// });
/// ```
macro_rules! wire {
    ($ui:expr, $cb:ident [$($cap:ident),* $(,)?], |$uiv:ident $(, $arg:ident)* $(,)?| $body:block) => {
        $ui.global::<AppState>().$cb({
            $( let $cap = $cap.clone(); )*
            let weak = $ui.as_weak();
            move |$($arg),*| {
                let ::core::option::Option::Some($uiv) = weak.upgrade() else { return };
                $body
            }
        })
    };
}
pub(crate) use wire;

// ─── Status setters ────────────────────────────────────────────────────────

/// Generate a `show_X_status(ui, message, kind)` setter that keeps a status
/// property and its outcome kind from drifting apart.
///
/// ```ignore
/// status_setter!(pub(crate), show_network_status, set_network_status, set_network_status_kind);
/// ```
macro_rules! status_setter {
    ($vis:vis, $name:ident, $set:ident, $set_kind:ident) => {
        $vis fn $name(ui: &WhiteNoiseLinux, message: impl Into<SharedString>, kind: StatusKind) {
            ui.$set(message.into());
            ui.$set_kind(kind as i32);
        }
    };
}
pub(crate) use status_setter;

// ─── Row-model mutation ────────────────────────────────────────────────────

/// Mutate in place every row of a `ModelRc<T>` that satisfies `matches`,
/// replacing the hand-written downcast/loop/`set_row_data` block.
pub(crate) fn update_rows_where<T: Clone + 'static>(
    model: &ModelRc<T>,
    matches: impl Fn(&T) -> bool,
    mut apply: impl FnMut(&mut T),
) {
    let Some(vm) = model.as_any().downcast_ref::<VecModel<T>>() else {
        return;
    };
    for i in 0..vm.row_count() {
        let Some(mut row) = vm.row_data(i) else {
            continue;
        };
        if !matches(&row) {
            continue;
        }
        apply(&mut row);
        vm.set_row_data(i, row);
    }
}

/// Index of the first row satisfying `matches`, if any.
pub(crate) fn find_row<T: Clone + 'static>(
    model: &ModelRc<T>,
    matches: impl Fn(&T) -> bool,
) -> Option<usize> {
    let vm = model.as_any().downcast_ref::<VecModel<T>>()?;
    (0..vm.row_count()).find(|&i| vm.row_data(i).is_some_and(|r| matches(&r)))
}

/// `update_rows_where` that stops after the first hit. Returns true when a
/// row was updated.
pub(crate) fn update_first_row_where<T: Clone + 'static>(
    model: &ModelRc<T>,
    matches: impl Fn(&T) -> bool,
    mut apply: impl FnMut(&mut T),
) -> bool {
    let Some(i) = find_row(model, matches) else {
        return false;
    };
    let Some(vm) = model.as_any().downcast_ref::<VecModel<T>>() else {
        return false;
    };
    let Some(mut row) = vm.row_data(i) else {
        return false;
    };
    apply(&mut row);
    vm.set_row_data(i, row);
    true
}

/// Mutate the row at `idx` in place. Returns true when a row was updated.
pub(crate) fn update_row_at<T: Clone + 'static>(
    model: &ModelRc<T>,
    idx: usize,
    apply: impl FnOnce(&mut T),
) -> bool {
    let Some(vm) = model.as_any().downcast_ref::<VecModel<T>>() else {
        return false;
    };
    let Some(mut row) = vm.row_data(idx) else {
        return false;
    };
    apply(&mut row);
    vm.set_row_data(idx, row);
    true
}
