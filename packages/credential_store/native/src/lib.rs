//! Synchronous ABI v1. The bridge retains no caller pointers or store/entry handles.
use std::panic::{AssertUnwindSafe, catch_unwind};
use zeroize::Zeroizing;

pub const MAXIMUM_BYTES: usize = 2560;
#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
pub(crate) const SERVICE: &str = "dev.adele.credentials.v1";
const OK: u32 = 0;
const MISSING: u32 = 1;
const UNAVAILABLE: u32 = 2;
const FAILED: u32 = 3;
const INVALID_REFERENCE: u32 = 4;
const INVALID_SECRET: u32 = 5;
const CORRUPT_DATA: u32 = 6;

pub(crate) fn reference(bytes: &[u8]) -> Result<&str, u32> {
    if bytes.len() != 38
        || !bytes.starts_with(b"cred1_")
        || !bytes[6..]
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
    {
        return Err(INVALID_REFERENCE);
    }
    std::str::from_utf8(bytes).map_err(|_| INVALID_REFERENCE)
}

fn secret(bytes: &[u8]) -> Result<(), u32> {
    if bytes.is_empty()
        || bytes.len() > MAXIMUM_BYTES
        || bytes.contains(&0)
        || std::str::from_utf8(bytes).is_err()
    {
        return Err(INVALID_SECRET);
    }
    Ok(())
}

#[cfg(any(test, all(target_os = "linux", target_arch = "x86_64")))]
fn read_result(operation: u32, bytes: Vec<u8>) -> Result<Zeroizing<Vec<u8>>, u32> {
    let bytes = Zeroizing::new(bytes);
    secret(&bytes).map_err(|_| CORRUPT_DATA)?;
    // Contains validates the one secret but never returns any secret bytes.
    Ok(if operation == 1 {
        bytes
    } else {
        Zeroizing::new(Vec::new())
    })
}

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
fn failure(error: keyring_core::Error) -> u32 {
    use keyring_core::Error;
    use zeroize::Zeroize;
    match error {
        Error::NoEntry => MISSING,
        Error::NoStorageAccess(_) | Error::NoDefaultStore => UNAVAILABLE,
        Error::BadEncoding(mut bytes) | Error::BadDataFormat(mut bytes, _) => {
            bytes.zeroize();
            CORRUPT_DATA
        }
        Error::BadStoreFormat(_) => CORRUPT_DATA,
        // Already-validated inputs do not justify guessing which field a
        // backend rejected. Ambiguity and all unknown errors fail closed.
        _ => FAILED,
    }
}

fn operate(operation: u32, reference: &str, value: &[u8]) -> Result<Zeroizing<Vec<u8>>, u32> {
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        use keyring_core::{Error, api::CredentialStoreApi};
        // Fresh explicit ownership permits recovery on a later request, without
        // global default-store mutation or blind retry of an uncertain write.
        let store =
            zbus_secret_service_keyring_store::Store::new().map_err(|error| match error {
                Error::PlatformFailure(_) | Error::NoStorageAccess(_) | Error::NoDefaultStore => {
                    UNAVAILABLE
                }
                Error::NoEntry => FAILED,
                other => failure(other),
            })?;
        let entry = store
            .build(SERVICE, reference, None)
            .map_err(|error| match error {
                Error::NoEntry => FAILED,
                other => failure(other),
            })?;
        match operation {
            1 | 4 => read_result(operation, entry.get_secret().map_err(failure)?),
            2 => {
                entry.set_secret(value).map_err(failure)?;
                Ok(Zeroizing::new(Vec::new()))
            }
            3 => {
                entry.delete_credential().map_err(failure)?;
                Ok(Zeroizing::new(Vec::new()))
            }
            _ => Err(FAILED),
        }
    }
    #[cfg(not(all(target_os = "linux", target_arch = "x86_64")))]
    {
        let _ = (operation, reference, value);
        Err(UNAVAILABLE)
    }
}

pub(crate) fn guarded<T>(operation: impl FnOnce() -> Result<T, u32>) -> Result<T, u32> {
    // This hook belongs ONLY to this cdylib's statically linked, hidden Rust
    // runtime. The build hook verifies that ownership before bundling Linux x64.
    // Suppressing this runtime's hook also covers its dependency worker threads.
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        static HOOK: std::sync::Once = std::sync::Once::new();
        HOOK.call_once(|| std::panic::set_hook(Box::new(|_| {})));
    }
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(result) => result,
        Err(payload) => {
            // A user-defined panic payload can panic again in Drop. Contain that
            // too; the secondary payload must not run another arbitrary Drop.
            if let Err(secondary) = catch_unwind(AssertUnwindSafe(|| drop(payload))) {
                std::mem::forget(secondary);
            }
            Err(FAILED)
        }
    }
}

/// This query does not initialize or contact a credential backend.
#[unsafe(no_mangle)]
pub extern "C" fn adele_credentials_abi_version() -> u32 {
    1
}

/// Operations: 1=read, 2=write, 3=delete, 4=contains.
/// Statuses: 0=ok, 1=missing, 2=unavailable, 3=failed, 4=invalid reference,
/// 5=invalid secret, 6=corrupt stored data. Unknown requests return 3.
/// Read requires a caller-owned 2560-byte output; other operations require null
/// output and zero capacity. Only successful reads write output bytes. The
/// output length is reset on entry and remains zero on any failure.
///
/// # Safety
/// All non-null pointers must be valid for their declared lengths. `output_len`
/// must be aligned and writable for one usize. Buffers must not overlap each
/// other or `output_len`. No pointer is retained; callers clear and free buffers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn adele_credentials_request_v1(
    operation: u32,
    key: *const u8,
    key_len: usize,
    value: *const u8,
    value_len: usize,
    output: *mut u8,
    capacity: usize,
    output_len: *mut usize,
) -> u32 {
    unsafe {
        request_with(
            operation, key, key_len, value, value_len, output, capacity, output_len, operate,
        )
    }
}

// The private callback permits deterministic unit tests of the actual ABI
// envelope. There is no runtime backend selector or exported injection seam.
#[allow(clippy::too_many_arguments)]
unsafe fn request_with(
    operation: u32,
    key: *const u8,
    key_len: usize,
    value: *const u8,
    value_len: usize,
    output: *mut u8,
    capacity: usize,
    output_len: *mut usize,
    run: impl FnOnce(u32, &str, &[u8]) -> Result<Zeroizing<Vec<u8>>, u32>,
) -> u32 {
    if output_len.is_null() {
        return FAILED;
    }
    unsafe { *output_len = 0 };
    let result = guarded(|| {
        if key.is_null() || key_len != 38 {
            return Err(INVALID_REFERENCE);
        }
        let key = reference(unsafe { std::slice::from_raw_parts(key, key_len) })?;
        if !matches!(operation, 1..=4) {
            return Err(FAILED);
        }
        if (operation == 1 && (output.is_null() || capacity != MAXIMUM_BYTES))
            || (operation != 1 && (!output.is_null() || capacity != 0))
        {
            return Err(FAILED);
        }
        if operation != 2 && (value_len != 0 || !value.is_null()) {
            return Err(FAILED);
        }
        if value_len > MAXIMUM_BYTES || (value.is_null() && value_len != 0) {
            return Err(INVALID_SECRET);
        }
        let value = if value_len == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(value, value_len) }
        };
        if operation == 2 {
            secret(value)?;
        }
        let bytes = run(operation, key, value)?;
        if operation == 1 {
            secret(&bytes).map_err(|_| CORRUPT_DATA)?;
        } else if !bytes.is_empty() {
            return Err(FAILED);
        }
        if !bytes.is_empty() {
            unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len()) };
        }
        unsafe { *output_len = bytes.len() };
        Ok(())
    });
    result.map_or_else(|code| code, |_| OK)
}

#[cfg(test)]
mod tests;
