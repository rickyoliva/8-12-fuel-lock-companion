//! Minimal C FFI shim over `idevice`'s RPPairing host.

mod ffi_util;
mod logging;
mod pairing;
mod pairing_port;

use std::ffi::{c_char, c_void};

pub use pairing::{PairCancel, PairResult, PinCb, ReadyCb};

#[no_mangle]
pub extern "C" fn si_log_init(cb: logging::LogCallback, ctx: *mut c_void) -> i32 {
    logging::init(cb, ctx)
}

#[no_mangle]
pub extern "C" fn si_log_set_verbose(verbose: i32) {
    logging::set_verbose(verbose != 0)
}

/// Free a `*mut c_char` previously returned by this library.
///
/// # Safety
/// `p` must be null or a pointer returned by one of this library's functions.
#[no_mangle]
pub unsafe extern "C" fn si_string_free(p: *mut c_char) {
    ffi_util::string_free(p);
}

/// Run the RPPairing host, blocking until a device pairs, fails, or is cancelled.
///
/// # Safety
/// See `pairing::run_host`. `out` must point to a writable `PairResult`.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn si_pairing_run_host(
    bind_addr: *const c_char,
    port: u16,
    name: *const c_char,
    model: *const c_char,
    out_path: *const c_char,
    host_alt_irk_hex: *const c_char,
    host_identifier: *const c_char,
    ready_cb: ReadyCb,
    pin_cb: PinCb,
    ctx: *mut c_void,
    cancel: *const PairCancel,
    out: *mut PairResult,
) -> i32 {
    pairing::run_host(
        bind_addr,
        port,
        name,
        model,
        out_path,
        host_alt_irk_hex,
        host_identifier,
        ready_cb,
        pin_cb,
        ctx,
        cancel,
        out,
    )
}

#[no_mangle]
pub extern "C" fn si_pairing_cancel_new() -> *mut PairCancel {
    Box::into_raw(Box::default())
}

/// # Safety
/// `cancel` must be null or a handle from `si_pairing_cancel_new` not yet freed.
#[no_mangle]
pub unsafe extern "C" fn si_pairing_cancel(cancel: *const PairCancel) {
    if let Some(cancel) = cancel.as_ref() {
        cancel.cancel();
    }
}

/// # Safety
/// `cancel` must be null or a handle from `si_pairing_cancel_new` not yet freed
/// and no longer in use.
#[no_mangle]
pub unsafe extern "C" fn si_pairing_cancel_free(cancel: *mut PairCancel) {
    if !cancel.is_null() {
        drop(Box::from_raw(cancel));
    }
}

/// # Safety
/// `r` must be null or a `PairResult` populated by `si_pairing_run_host`.
#[no_mangle]
pub unsafe extern "C" fn si_pairing_result_free(r: *mut PairResult) {
    pairing::result_free(r)
}

/// Knock on `device_ip`'s dynamic ports (49152-65535), except lockdownd's
/// 62078 and the `tried_count` ports in `tried`, 32 at a time, in order, until
/// one answers the RPPairing handshake (`attemptPairVerify`).
///
/// Returns 0 with the port in `*out_port` when one answered, 1 when none did,
/// 2 when knocking had to stop, and -1 for an invalid IP address.
/// `*out_summary` says what happened; free it with `si_string_free`.
///
/// # Safety
/// See `pairing_port::find_ffi`.
#[no_mangle]
pub unsafe extern "C" fn si_find_pairing_port(
    device_ip: *const c_char,
    tried: *const u16,
    tried_count: usize,
    out_port: *mut u16,
    out_summary: *mut *mut c_char,
) -> i32 {
    pairing_port::find_ffi(device_ip, tried, tried_count, out_port, out_summary)
}

/// Ask `device_ip:port` for the RPPairing handshake (`attemptPairVerify`), with
/// 8 s to connect and 10 s to answer.
///
/// Returns 0 when the port answered as the pairing service, 1 when it refused
/// the connection, 2 when something took the connection and didn't answer as
/// the service, 3 when nothing took or refused it within 8 s, 4 when the
/// connection failed some other way, and -1 for an invalid IP address.
/// `*out_summary` says what the port did; free it with `si_string_free`.
///
/// # Safety
/// See `pairing_port::probe_ffi`.
#[no_mangle]
pub unsafe extern "C" fn si_probe_pairing_port(
    device_ip: *const c_char,
    port: u16,
    out_summary: *mut *mut c_char,
) -> i32 {
    pairing_port::probe_ffi(device_ip, port, out_summary)
}
