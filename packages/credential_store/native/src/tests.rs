use super::*;
use std::ptr::{null, null_mut};

const KEY: &[u8] = b"cred1_0123456789abcdef0123456789abcdef";

#[test]
fn reference_validation_is_canonical() {
    assert!(reference(KEY).is_ok());
    for bytes in [
        &b""[..],
        &KEY[..37],
        b"cred1_0123456789abcdef0123456789abcdeF",
        b"cred2_0123456789abcdef0123456789abcdef",
        b"cred1_0123456789abcdef0123456789abcdeg",
        b"cred1_0123456789abcdef0123456789abcde\0",
    ] {
        assert_eq!(reference(bytes).err(), Some(INVALID_REFERENCE));
    }
    let mut malformed = KEY.to_vec();
    malformed[10] = 0xff;
    assert_eq!(reference(&malformed).err(), Some(INVALID_REFERENCE));
}

#[test]
fn secret_validation_is_strict_and_byte_bounded() {
    for bytes in [
        vec![],
        vec![0],
        vec![b'a', 0, b'b'],
        vec![0xff],
        vec![0xed, 0xa0, 0x80], // A UTF-8 encoding of a surrogate is invalid.
        vec![0xc0, 0x80],
        vec![b'x'; MAXIMUM_BYTES + 1],
    ] {
        assert_eq!(secret(&bytes), Err(INVALID_SECRET));
        assert_eq!(read_result(1, bytes).err(), Some(CORRUPT_DATA));
    }
    assert_eq!(secret(&vec![b'x'; MAXIMUM_BYTES]), Ok(()));
    let unicode = "\u{1f512}".repeat(MAXIMUM_BYTES / 4);
    assert_eq!(unicode.len(), MAXIMUM_BYTES);
    assert_eq!(secret(unicode.as_bytes()), Ok(()));
    assert_eq!(
        secret(format!("{unicode}x").as_bytes()),
        Err(INVALID_SECRET)
    );
}

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
#[test]
fn backend_errors_have_fixed_non_diagnostic_categories() {
    use keyring_core::Error;
    let io = || Box::new(std::io::Error::other("private-backend-payload"));
    assert_eq!(failure(Error::NoEntry), MISSING);
    assert_eq!(failure(Error::NoDefaultStore), UNAVAILABLE);
    assert_eq!(failure(Error::NoStorageAccess(io())), UNAVAILABLE);
    assert_eq!(failure(Error::PlatformFailure(io())), FAILED);
    assert_eq!(failure(Error::BadEncoding(vec![0xff])), CORRUPT_DATA);
    assert_eq!(
        failure(Error::BadDataFormat(vec![1], "private".into())),
        CORRUPT_DATA
    );
    assert_eq!(
        failure(Error::BadStoreFormat("private".into())),
        CORRUPT_DATA
    );
    assert_eq!(
        failure(Error::Invalid("private".into(), "private".into())),
        FAILED
    );
    assert_eq!(failure(Error::TooLong("private".into(), 1)), FAILED);
    assert_eq!(failure(Error::Ambiguous(vec![])), FAILED);
    assert_eq!(
        failure(Error::NotSupportedByStore("private".into())),
        FAILED
    );
}

#[test]
fn invalid_abi_inputs_never_call_a_backend() {
    let mut output = [0xa5; MAXIMUM_BYTES];
    let mut length = 99;
    let invalid = [
        (
            1,
            null(),
            38,
            null(),
            0,
            output.as_mut_ptr(),
            MAXIMUM_BYTES,
            INVALID_REFERENCE,
        ),
        (
            1,
            KEY.as_ptr(),
            37,
            null(),
            0,
            output.as_mut_ptr(),
            MAXIMUM_BYTES,
            INVALID_REFERENCE,
        ),
        (0, KEY.as_ptr(), 38, null(), 0, null_mut(), 0, FAILED),
        (5, KEY.as_ptr(), 38, null(), 0, null_mut(), 0, FAILED),
        (
            1,
            KEY.as_ptr(),
            38,
            null(),
            0,
            null_mut(),
            MAXIMUM_BYTES,
            FAILED,
        ),
        (
            1,
            KEY.as_ptr(),
            38,
            null(),
            0,
            output.as_mut_ptr(),
            MAXIMUM_BYTES - 1,
            FAILED,
        ),
        (
            4,
            KEY.as_ptr(),
            38,
            null(),
            0,
            output.as_mut_ptr(),
            0,
            FAILED,
        ),
        (4, KEY.as_ptr(), 38, null(), 0, null_mut(), 1, FAILED),
        (3, KEY.as_ptr(), 38, KEY.as_ptr(), 1, null_mut(), 0, FAILED),
        (
            2,
            KEY.as_ptr(),
            38,
            null(),
            0,
            null_mut(),
            0,
            INVALID_SECRET,
        ),
        (
            2,
            KEY.as_ptr(),
            38,
            null(),
            1,
            null_mut(),
            0,
            INVALID_SECRET,
        ),
        (
            2,
            KEY.as_ptr(),
            38,
            KEY.as_ptr(),
            MAXIMUM_BYTES + 1,
            null_mut(),
            0,
            INVALID_SECRET,
        ),
    ];
    for (op, key, key_len, value, value_len, out, capacity, expected) in invalid {
        let called = std::cell::Cell::new(false);
        let code = unsafe {
            request_with(
                op,
                key,
                key_len,
                value,
                value_len,
                out,
                capacity,
                &mut length,
                |_, _, _| {
                    called.set(true);
                    Err(FAILED)
                },
            )
        };
        assert_eq!(code, expected);
        assert!(!called.get());
        assert_eq!(length, 0);
        assert!(output.iter().all(|byte| *byte == 0xa5));
    }
    assert_eq!(
        unsafe { adele_credentials_request_v1(1, null(), 0, null(), 0, null_mut(), 0, null_mut()) },
        FAILED
    );
}

#[test]
fn exported_abi_rejects_malformed_bytes_before_keyring_access() {
    for value in [&b"\0"[..], &b"\xff"[..], &b"\xc0\x80"[..]] {
        let mut length = 42;
        let code = unsafe {
            adele_credentials_request_v1(
                2,
                KEY.as_ptr(),
                KEY.len(),
                value.as_ptr(),
                value.len(),
                null_mut(),
                0,
                &mut length,
            )
        };
        assert_eq!(code, INVALID_SECRET);
        assert_eq!(length, 0);
    }
    assert_eq!(adele_credentials_abi_version(), 1);
}

#[test]
fn caller_owns_unchanged_inputs_and_exact_read_buffer() {
    let key = KEY.to_vec();
    let value = vec![b'x'; MAXIMUM_BYTES];
    let mut length = 99;
    let code = unsafe {
        request_with(
            2,
            key.as_ptr(),
            key.len(),
            value.as_ptr(),
            value.len(),
            null_mut(),
            0,
            &mut length,
            |op, reference, bytes| {
                assert_eq!(op, 2);
                assert!(reference.as_bytes() == KEY);
                assert!(bytes == value);
                Ok(Zeroizing::new(Vec::new()))
            },
        )
    };
    assert_eq!(code, OK);
    assert_eq!(length, 0);
    assert!(key == KEY);
    assert!(value.iter().all(|byte| *byte == b'x'));
    // Guard bytes belong to the caller too; no native allocation/free crosses
    // the ABI and repeated calls do not retain or invalidate these allocations.
    let mut output = vec![0xa5; MAXIMUM_BYTES + 2];
    for _ in 0..3 {
        let code = unsafe {
            request_with(
                1,
                key.as_ptr(),
                key.len(),
                null(),
                0,
                output.as_mut_ptr().add(1),
                MAXIMUM_BYTES,
                &mut length,
                |_, _, _| read_result(1, value.clone()),
            )
        };
        assert_eq!(code, OK);
        assert_eq!(length, MAXIMUM_BYTES);
        assert_eq!(output[0], 0xa5);
        assert_eq!(output[MAXIMUM_BYTES + 1], 0xa5);
        assert!(output[1..=MAXIMUM_BYTES] == value);
    }
}

#[test]
fn missing_errors_and_corruption_do_not_publish_partial_output() {
    let mut output = [0xa5; MAXIMUM_BYTES];
    for code in [MISSING, UNAVAILABLE, FAILED, CORRUPT_DATA] {
        let mut length = 99;
        let status = unsafe {
            request_with(
                1,
                KEY.as_ptr(),
                KEY.len(),
                null(),
                0,
                output.as_mut_ptr(),
                output.len(),
                &mut length,
                |_, _, _| Err(code),
            )
        };
        assert_eq!(status, code);
        assert_eq!(length, 0);
        assert!(output.iter().all(|byte| *byte == 0xa5));
    }
    for bytes in [vec![], vec![0xff], vec![0], vec![b'x'; MAXIMUM_BYTES + 1]] {
        let mut length = 99;
        let status = unsafe {
            request_with(
                1,
                KEY.as_ptr(),
                KEY.len(),
                null(),
                0,
                output.as_mut_ptr(),
                output.len(),
                &mut length,
                |_, _, _| Ok(Zeroizing::new(bytes)),
            )
        };
        assert_eq!(status, CORRUPT_DATA);
        assert_eq!(length, 0);
        assert!(output.iter().all(|byte| *byte == 0xa5));
    }
}

#[test]
fn contains_validates_without_returning_secret_bytes() {
    assert!(read_result(4, b"fixture".to_vec()).unwrap().is_empty());
    assert_eq!(read_result(4, vec![0xff]).err(), Some(CORRUPT_DATA));
    let mut length = 99;
    let status = unsafe {
        request_with(
            4,
            KEY.as_ptr(),
            KEY.len(),
            null(),
            0,
            null_mut(),
            0,
            &mut length,
            |op, _, _| read_result(op, b"fixture".to_vec()),
        )
    };
    assert_eq!(status, OK);
    assert_eq!(length, 0);
}

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
#[test]
fn panic_and_panicking_payload_drop_are_redacted_in_subprocess() {
    let child = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "tests::panic_worker", "--nocapture"])
        .env("ADELE_CREDENTIAL_PANIC_TEST", "1")
        .output()
        .unwrap();
    assert!(child.status.success());
    assert!(child.stderr.is_empty());
    let stdout = String::from_utf8_lossy(&child.stdout);
    assert!(stdout.contains("1 passed"));
    assert!(!stdout.contains("sensitive-panic-canary"));
}

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
#[test]
fn panic_worker() {
    if std::env::var_os("ADELE_CREDENTIAL_PANIC_TEST").is_none() {
        return;
    }
    struct Payload;
    impl Drop for Payload {
        fn drop(&mut self) {
            std::panic::panic_any("sensitive-panic-canary-drop");
        }
    }
    let mut output = [0xa5; MAXIMUM_BYTES];
    for destructor_panics in [false, true] {
        let mut length = 99;
        let status = unsafe {
            request_with(
                1,
                KEY.as_ptr(),
                KEY.len(),
                null(),
                0,
                output.as_mut_ptr(),
                output.len(),
                &mut length,
                |_, _, _| {
                    if destructor_panics {
                        std::panic::panic_any(Payload);
                    }
                    std::panic::panic_any("sensitive-panic-canary");
                },
            )
        };
        assert_eq!(status, FAILED);
        assert_eq!(length, 0);
        assert!(output.iter().all(|byte| *byte == 0xa5));
    }
    assert_eq!(guarded(|| Ok(42)), Ok(42));
}
