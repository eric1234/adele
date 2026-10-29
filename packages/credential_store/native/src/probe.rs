//! Explicit fixture-only executable. Never run against the user's session bus.
#[path = "lib.rs"]
mod bridge;

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
use std::io::Read;
#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
use zeroize::{Zeroize, Zeroizing};

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
fn main() {
    let fixture = std::env::var("ADELE_CREDENTIAL_STORAGE_FIXTURE").unwrap_or_default();
    let bus = std::env::var("DBUS_SESSION_BUS_ADDRESS").unwrap_or_default();
    if std::env::var("ADELE_CREDENTIAL_STORAGE_SMOKE").as_deref() != Ok("1")
        || !std::path::Path::new(&fixture).is_absolute()
        || !bus.starts_with(&format!("unix:path={fixture}/run/"))
    {
        eprintln!("credential probe requires the explicit disposable fixture");
        std::process::exit(64);
    }
    let arguments: Vec<String> = std::env::args().collect();
    if arguments.len() != 3 {
        eprintln!("usage: credential_probe read|contains|write|delete|verify|corrupt REFERENCE");
        std::process::exit(64);
    }
    if arguments[1] == "corrupt" {
        let result = bridge::guarded(|| corrupt(&arguments[2]));
        println!("{} {}", result.err().unwrap_or(0), u8::from(result.is_ok()));
        return;
    }
    let operation = match arguments[1].as_str() {
        "read" | "verify" => 1,
        "write" => 2,
        "delete" => 3,
        "contains" => 4,
        _ => std::process::exit(64),
    };
    let mut input = Zeroizing::new(Vec::new());
    if (operation == 2 || arguments[1] == "verify")
        && std::io::stdin()
            .take((bridge::MAXIMUM_BYTES + 1) as u64)
            .read_to_end(&mut input)
            .is_err()
    {
        std::process::exit(65);
    }
    let mut output = Zeroizing::new(vec![0u8; bridge::MAXIMUM_BYTES]);
    let mut length = 0;
    let status = unsafe {
        bridge::adele_credentials_request_v1(
            operation,
            arguments[2].as_ptr(),
            arguments[2].len(),
            if operation == 2 {
                input.as_ptr()
            } else {
                std::ptr::null()
            },
            if operation == 2 { input.len() } else { 0 },
            if operation == 1 {
                output.as_mut_ptr()
            } else {
                std::ptr::null_mut()
            },
            if operation == 1 { output.len() } else { 0 },
            &mut length,
        )
    };
    let verified = arguments[1] != "verify" || (status == 0 && output[..length] == input[..]);
    // Only bounded status/verification cross stdout, never the stored value.
    println!("{status} {}", u8::from(verified));
    input.zeroize();
    output.zeroize();
}

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
fn corrupt(reference: &str) -> Result<(), u32> {
    use keyring_core::api::CredentialStoreApi;
    bridge::reference(reference.as_bytes())?;
    let store = zbus_secret_service_keyring_store::Store::new().map_err(|_| 3u32)?;
    let entry = store
        .build(bridge::SERVICE, reference, None)
        .map_err(|_| 3u32)?;
    let invalid = [0xff, 0xfe, 0x80];
    entry.set_secret(&invalid).map_err(|_| 3u32)?;
    let mut output = Zeroizing::new(vec![0u8; bridge::MAXIMUM_BYTES]);
    for operation in [1, 4] {
        let mut length = 99;
        let code = unsafe {
            bridge::adele_credentials_request_v1(
                operation,
                reference.as_ptr(),
                reference.len(),
                std::ptr::null(),
                0,
                if operation == 1 {
                    output.as_mut_ptr()
                } else {
                    std::ptr::null_mut()
                },
                if operation == 1 { output.len() } else { 0 },
                &mut length,
            )
        };
        if code != 6 || length != 0 || output.iter().any(|byte| *byte != 0) {
            return Err(3);
        }
    }
    let actual = Zeroizing::new(entry.get_secret().map_err(|_| 3u32)?);
    if actual.as_slice() != invalid {
        return Err(3);
    }
    Ok(())
}

#[cfg(not(all(target_os = "linux", target_arch = "x86_64")))]
fn main() {
    eprintln!("credential probe is unsupported on this platform");
    std::process::exit(64);
}
