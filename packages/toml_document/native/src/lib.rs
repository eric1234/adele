use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

use serde_json::{Value as Json, json};
use toml_edit::{DocumentMut, Item, Table, Value};

struct Failure {
    kind: &'static str,
    message: String,
}

impl Failure {
    fn new(kind: &'static str, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }
}

fn scalar(item: &Item) -> Result<Json, Failure> {
    match item {
        Item::Value(Value::String(value)) => Ok(json!(value.value())),
        Item::Value(Value::Integer(value)) => Ok(json!(value.value())),
        Item::Value(Value::Boolean(value)) => Ok(json!(value.value())),
        _ => Err(Failure::new(
            "type",
            "Expected a string, integer, or boolean scalar.",
        )),
    }
}

fn replacement(value: &Json) -> Result<Value, Failure> {
    match value {
        Json::String(value) => Ok(Value::from(value.as_str())),
        Json::Bool(value) => Ok(Value::from(*value)),
        Json::Number(value) if value.is_i64() => Ok(Value::from(value.as_i64().unwrap())),
        _ => Err(Failure::new(
            "type",
            "Expected a string, signed 64-bit integer, or boolean.",
        )),
    }
}

fn parent_table<'a>(mut table: &'a mut Table, path: &[&str]) -> Result<&'a mut Table, Failure> {
    for key in path {
        table = table
            .get_mut(key)
            .and_then(Item::as_table_mut)
            .ok_or_else(|| {
                Failure::new(
                    "path",
                    format!("Parent key {key:?} is missing or is not a regular table."),
                )
            })?;
    }
    Ok(table)
}

fn operate(request: &str) -> Result<Json, Failure> {
    let request: Json = serde_json::from_str(request)
        .map_err(|error| Failure::new("edit", format!("Invalid bridge request: {error}")))?;
    let source = request["document"]
        .as_str()
        .ok_or_else(|| Failure::new("edit", "Missing document text."))?;
    let mut document = source
        .parse::<DocumentMut>()
        .map_err(|error| Failure::new("parse", error.to_string()))?;
    let operation = request["operation"].as_str().unwrap_or("");
    if operation == "parse" {
        return Ok(json!({"document": source}));
    }
    let path = request["path"]
        .as_array()
        .ok_or_else(|| Failure::new("path", "Expected a nonempty list of literal keys."))?;
    let path: Vec<&str> = path
        .iter()
        .map(|key| {
            key.as_str()
                .ok_or_else(|| Failure::new("path", "Every key path segment must be a string."))
        })
        .collect::<Result<_, _>>()?;
    let (key, parents) = path
        .split_last()
        .ok_or_else(|| Failure::new("path", "The key path must not be empty."))?;
    let table = parent_table(document.as_table_mut(), parents)?;
    match operation {
        "read" => {
            let item = table
                .get(key)
                .ok_or_else(|| Failure::new("path", format!("Key {key:?} does not exist.")))?;
            return Ok(json!({"value": scalar(item)?}));
        }
        "set" => {
            let mut value = replacement(&request["value"])?;
            if let Some(item) = table.get_mut(key) {
                let old = scalar(item)?;
                if old == request["value"] {
                    return Ok(json!({"document": source}));
                }
                let current = item.as_value_mut().unwrap();
                if std::mem::discriminant(current) != std::mem::discriminant(&value) {
                    return Err(Failure::new(
                        "type",
                        format!("Key {key:?} has a different scalar type."),
                    ));
                }
                // Retain surrounding whitespace/comments; spelling of the new
                // scalar itself belongs to toml_edit, not a custom formatter.
                *value.decor_mut() = current.decor().clone();
                *current = value;
            } else {
                table.insert(key, Item::Value(value));
            }
        }
        "remove" => {
            if let Some(item) = table.get(key) {
                scalar(item)?;
                table.remove(key);
            } else {
                return Ok(json!({"document": source}));
            }
        }
        _ => return Err(Failure::new("edit", "Unknown document operation.")),
    }
    let edited = document.to_string();
    // Do not publish a result that cannot be parsed, including edge cases in
    // structural serialization. The caller's snapshot remains unchanged.
    edited
        .parse::<DocumentMut>()
        .map_err(|error| Failure::new("edit", format!("Edited document is invalid: {error}")))?;
    Ok(json!({"document": edited}))
}

/// Borrows a valid NUL-terminated UTF-8 request for this call only. Returns one
/// owned NUL-terminated UTF-8 JSON response, released exactly once by free.
///
/// # Safety
/// `request` must be null or point to a readable NUL-terminated byte string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn adele_toml_request(request: *const c_char) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if request.is_null() {
            return Err(Failure::new("edit", "Null bridge request."));
        }
        // SAFETY: the caller supplies a live, NUL-terminated request buffer.
        let request = unsafe { CStr::from_ptr(request) }
            .to_str()
            .map_err(|error| Failure::new("edit", format!("Invalid UTF-8: {error}")))?;
        operate(request)
    }))
    .unwrap_or_else(|_| Err(Failure::new("edit", "Native TOML operation panicked.")));
    let response = match result {
        Ok(value) => value,
        Err(error) => json!({"error": {"kind": error.kind, "message": error.message}}),
    };
    // JSON escapes embedded NUL characters; this cannot contain a raw NUL.
    CString::new(response.to_string()).unwrap().into_raw()
}

/// Releases a response returned by adele_toml_request; null is a no-op.
///
/// # Safety
/// A non-null pointer must be an unreleased response from this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn adele_toml_free(response: *mut c_char) {
    if !response.is_null() {
        // SAFETY: ownership of exactly this allocation returns from the caller.
        drop(unsafe { CString::from_raw(response) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_reports_malformed_requests_and_releases_responses() {
        for input in [None, Some(c"not JSON"), Some(c"{\"document\":\"a =\"}")] {
            let pointer =
                unsafe { adele_toml_request(input.map_or(std::ptr::null(), |s| s.as_ptr())) };
            assert!(!pointer.is_null());
            let response: Json =
                serde_json::from_str(unsafe { CStr::from_ptr(pointer) }.to_str().unwrap()).unwrap();
            assert!(response["error"]["message"].as_str().unwrap().len() > 5);
            unsafe { adele_toml_free(pointer) };
        }
        unsafe { adele_toml_free(std::ptr::null_mut()) };
    }
}
