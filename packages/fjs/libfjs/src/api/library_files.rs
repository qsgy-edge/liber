//! Bounded desktop file IO. Paths carry no library, root or book identity policy.

use flutter_rust_bridge::frb;
use sha2::{Digest, Sha256};
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::{Read, Seek, Write};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};

const BUFFER_BYTES: usize = 256 * 1024;

/// Typed failures for verified filesystem operations.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LibraryFileError {
    /// Cancellation was observed between IO chunks.
    Cancelled,
    /// Exclusive creation refused an existing destination.
    AlreadyExists,
    /// Byte counts, digests, or the observed file identity changed.
    VerificationFailed,
    /// OS failure, including any failure to clean an owned partial.
    Io(String),
}

impl std::fmt::Display for LibraryFileError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Cancelled => write!(f, "file copy cancelled"),
            Self::AlreadyExists => write!(f, "destination already exists"),
            Self::VerificationFailed => write!(f, "file verification failed"),
            Self::Io(message) => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for LibraryFileError {}

type FileResult<T> = std::result::Result<T, LibraryFileError>;

fn io(error: std::io::Error) -> LibraryFileError {
    LibraryFileError::Io(error.to_string())
}

/// Verified byte count and SHA-256 receipt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryCopyResult {
    /// Number of bytes in the verified stream.
    pub bytes_copied: i64,
    /// Exact byte-stream fingerprint, never a book ID.
    pub sha256: String,
}

/// One copy at a time. Cancellation is sticky; use a fresh job for another copy.
#[frb(opaque)]
pub struct LibraryCopyJob {
    cancelled: AtomicBool,
    copied: AtomicI64,
    running: AtomicBool,
}

impl LibraryCopyJob {
    /// Creates a fresh, uncancelled copy job.
    #[frb(sync)]
    pub fn new() -> Self {
        Self {
            cancelled: AtomicBool::new(false),
            copied: AtomicI64::new(0),
            running: AtomicBool::new(false),
        }
    }

    /// Requests cancellation without waiting for a blocking OS operation.
    #[frb(sync)]
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Relaxed);
    }

    /// Bytes written so far; verification may still be in progress.
    #[frb(sync)]
    pub fn copied_bytes(&self) -> i64 {
        self.copied.load(Ordering::Relaxed)
    }

    /// FRB runs this on a worker. Cancellation is checked between bounded reads
    /// and writes, including verification; it cannot interrupt a blocking OS call.
    pub fn copy(
        &self,
        source_path: String,
        destination_path: String,
    ) -> Result<LibraryCopyResult, LibraryFileError> {
        if self.running.swap(true, Ordering::Acquire) {
            return Err(LibraryFileError::Io("copy job is already running".into()));
        }
        let _running = Running(&self.running);
        self.copied.store(0, Ordering::Relaxed);
        self.copy_paths(Path::new(&source_path), Path::new(&destination_path))
    }
}

struct Running<'a>(&'a AtomicBool);
impl Drop for Running<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

impl LibraryCopyJob {
    fn check_cancelled(&self) -> FileResult<()> {
        if self.cancelled.load(Ordering::Relaxed) {
            Err(LibraryFileError::Cancelled)
        } else {
            Ok(())
        }
    }

    fn copy_paths(
        &self,
        source_path: &Path,
        destination_path: &Path,
    ) -> FileResult<LibraryCopyResult> {
        self.check_cancelled()?;
        let mut source = open_regular(source_path)?;
        let before = source.metadata().map_err(io)?;
        let mut destination = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(destination_path)
            .map_err(|error| {
                if error.kind() == std::io::ErrorKind::AlreadyExists {
                    LibraryFileError::AlreadyExists
                } else {
                    io(error)
                }
            })?;
        // Capture the created file's identity while it is still open. Cleanup
        // must never delete a different file installed at this name meanwhile.
        let identity = match file_identity(&destination) {
            Ok(identity) => identity,
            Err(error) => {
                return Err(LibraryFileError::Io(format!(
                    "{error}; cleanup refused: cannot identify created partial {}",
                    destination_path.display()
                )));
            }
        };
        let result = (|| {
            let mut buffer = vec![0; BUFFER_BYTES];
            let mut digest = Sha256::new();
            let mut bytes = 0i64;
            loop {
                self.check_cancelled()?;
                let count = read_chunk(&mut source, &mut buffer)?;
                if count == 0 {
                    break;
                }
                destination.write_all(&buffer[..count]).map_err(io)?;
                digest.update(&buffer[..count]);
                bytes = bytes
                    .checked_add(count as i64)
                    .ok_or(LibraryFileError::VerificationFailed)?;
                self.copied.store(bytes, Ordering::Relaxed);
                #[cfg(test)]
                test_checkpoint(self, CopyPhase::Chunk, source_path, destination_path)?;
            }
            self.check_cancelled()?;
            destination.sync_all().map_err(io)?;
            let receipt = LibraryCopyResult {
                bytes_copied: bytes,
                sha256: digest
                    .finalize()
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect(),
            };
            #[cfg(test)]
            test_checkpoint(self, CopyPhase::Verify, source_path, destination_path)?;
            ensure_unchanged(&before, &source.metadata().map_err(io)?)?;
            // Re-read the source too: a same-length edit during the first pass
            // must not certify a mixed snapshot as a successful copy.
            source.rewind().map_err(io)?;
            if fingerprint(&mut source, Some(self))? != receipt {
                return Err(LibraryFileError::VerificationFailed);
            }
            ensure_unchanged(&before, &source.metadata().map_err(io)?)?;
            ensure_path_identity(source_path, file_identity(&source)?)?;
            Ok(receipt)
        })();
        // Close the writer before verifying the canonical destination, and before
        // removing a failed partial (Windows cannot remove every open handle).
        drop(destination);
        let result = result.and_then(|receipt| {
            ensure_path_identity(destination_path, identity)?;
            let mut verified = open_regular(destination_path)?;
            if fingerprint(&mut verified, Some(self))? != receipt {
                return Err(LibraryFileError::VerificationFailed);
            }
            ensure_unchanged(&before, &source.metadata().map_err(io)?)?;
            ensure_path_identity(source_path, file_identity(&source)?)?;
            self.check_cancelled()?;
            Ok(receipt)
        });
        match result {
            Ok(receipt) => Ok(receipt),
            Err(error) => match remove_created_partial(destination_path, identity) {
                Ok(()) => Err(error),
                Err(cleanup) => Err(LibraryFileError::Io(format!(
                    "{error}; cleanup failed for {}: {cleanup}",
                    destination_path.display()
                ))),
            },
        }
    }
}

fn open_regular(path: &Path) -> FileResult<File> {
    // Reject symlinks and special files before open, so a supplied pipe cannot
    // block waiting for a writer and cleanup never follows a link.
    if !fs::symlink_metadata(path).map_err(io)?.is_file() {
        return Err(LibraryFileError::Io(format!(
            "not a regular file: {}",
            path.display()
        )));
    }
    let mut file = File::open(path).map_err(io)?;
    if !file.metadata().map_err(io)?.is_file() {
        return Err(LibraryFileError::Io(format!(
            "not a regular file: {}",
            path.display()
        )));
    }
    file.rewind().map_err(io)?;
    Ok(file)
}

fn read_chunk(file: &mut File, buffer: &mut [u8]) -> FileResult<usize> {
    loop {
        match file.read(buffer) {
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            result => return result.map_err(io),
        }
    }
}

fn ensure_unchanged(before: &Metadata, after: &Metadata) -> FileResult<()> {
    if before.len() != after.len()
        || before.modified().map_err(io)? != after.modified().map_err(io)?
    {
        Err(LibraryFileError::VerificationFailed)
    } else {
        Ok(())
    }
}

fn fingerprint(file: &mut File, job: Option<&LibraryCopyJob>) -> FileResult<LibraryCopyResult> {
    let before = file.metadata().map_err(io)?;
    let mut buffer = vec![0; BUFFER_BYTES];
    let mut digest = Sha256::new();
    let mut bytes = 0i64;
    loop {
        if let Some(job) = job {
            job.check_cancelled()?;
        }
        let count = read_chunk(file, &mut buffer)?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
        bytes = bytes
            .checked_add(count as i64)
            .ok_or(LibraryFileError::VerificationFailed)?;
    }
    ensure_unchanged(&before, &file.metadata().map_err(io)?)?;
    if u64::try_from(bytes).ok() != Some(before.len()) {
        return Err(LibraryFileError::VerificationFailed);
    }
    Ok(LibraryCopyResult {
        bytes_copied: bytes,
        sha256: digest
            .finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect(),
    })
}

/// Fingerprints a known regular file with bounded reads.
pub fn library_file_fingerprint(path: String) -> Result<LibraryCopyResult, LibraryFileError> {
    fingerprint(&mut open_regular(Path::new(&path))?, None)
}

/// Compares regular files byte for byte using bounded buffers.
pub fn library_files_equal(
    first_path: String,
    second_path: String,
) -> Result<bool, LibraryFileError> {
    let mut first = open_regular(Path::new(&first_path))?;
    let mut second = open_regular(Path::new(&second_path))?;
    let first_before = first.metadata().map_err(io)?;
    let second_before = second.metadata().map_err(io)?;
    if first_before.len() != second_before.len() {
        return Ok(false);
    }
    let mut a = vec![0; BUFFER_BYTES];
    let mut b = vec![0; BUFFER_BYTES];
    // read_exact handles unequal short-read boundaries from the two files.
    let mut remaining = first_before.len();
    while remaining > 0 {
        let count = remaining.min(BUFFER_BYTES as u64) as usize;
        first.read_exact(&mut a[..count]).map_err(io)?;
        second.read_exact(&mut b[..count]).map_err(io)?;
        if a[..count] != b[..count] {
            return Ok(false);
        }
        remaining -= count as u64;
    }
    ensure_unchanged(&first_before, &first.metadata().map_err(io)?)?;
    ensure_unchanged(&second_before, &second.metadata().map_err(io)?)?;
    Ok(true)
}

/// Preserves a verified old copy before the OS atomic rename. Cross-filesystem
/// rename fails without truncating the destination. Backup disposal belongs to
/// the caller, including when replacement fails after the backup succeeds.
pub fn library_replace_file(
    staged_path: String,
    destination_path: String,
    backup_path: String,
) -> Result<(), LibraryFileError> {
    if !cfg!(any(unix, windows)) {
        return Err(LibraryFileError::Io(
            "atomic replacement is unsupported on this platform".into(),
        ));
    }
    let staged_path = Path::new(&staged_path);
    let destination_path = Path::new(&destination_path);
    let staged = open_regular(staged_path)?;
    let destination = open_regular(destination_path)?;
    let staged_identity = file_identity(&staged)?;
    let destination_identity = file_identity(&destination)?;
    if staged_identity == destination_identity {
        return Err(LibraryFileError::Io(
            "staged and destination files are aliases".into(),
        ));
    }
    drop(staged);
    drop(destination);
    let backup = LibraryCopyJob::new().copy_paths(destination_path, Path::new(&backup_path))?;
    ensure_path_identity(staged_path, staged_identity)?;
    ensure_path_identity(destination_path, destination_identity)?;
    if fingerprint(&mut open_regular(destination_path)?, None)? != backup {
        return Err(LibraryFileError::VerificationFailed);
    }
    // Both supported std implementations use a replacing rename without a
    // cross-volume copy fallback (rename / MoveFileExW REPLACE_EXISTING).
    fs::rename(staged_path, destination_path).map_err(io)
}

fn ensure_path_identity(path: &Path, identity: (u64, u64)) -> FileResult<()> {
    if file_identity(&open_regular(path)?)? != identity {
        Err(LibraryFileError::VerificationFailed)
    } else {
        Ok(())
    }
}

fn remove_created_partial(path: &Path, identity: (u64, u64)) -> FileResult<()> {
    ensure_path_identity(path, identity)?;
    fs::remove_file(path).map_err(io)
}

#[cfg(unix)]
fn file_identity(file: &File) -> FileResult<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    let metadata = file.metadata().map_err(io)?;
    Ok((metadata.dev(), metadata.ino()))
}

#[cfg(windows)]
fn file_identity(file: &File) -> FileResult<(u64, u64)> {
    use std::ffi::c_void;
    use std::os::windows::io::AsRawHandle;
    // std's volume_serial_number/file_index remain unstable. This is the same
    // Win32 identity query on the already-open handle, without a dependency.
    #[repr(C)]
    #[derive(Default)]
    struct FileInformation {
        attributes: u32,
        creation_time: [u32; 2],
        access_time: [u32; 2],
        write_time: [u32; 2],
        volume_serial: u32,
        size_high: u32,
        size_low: u32,
        links: u32,
        index_high: u32,
        index_low: u32,
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetFileInformationByHandle(
            handle: *mut c_void,
            information: *mut FileInformation,
        ) -> i32;
    }
    let mut information = FileInformation::default();
    // SAFETY: the handle stays open and the output has the SDK's C layout.
    if unsafe { GetFileInformationByHandle(file.as_raw_handle(), &mut information) } == 0 {
        return Err(io(std::io::Error::last_os_error()));
    }
    Ok((
        u64::from(information.volume_serial),
        (u64::from(information.index_high) << 32) | u64::from(information.index_low),
    ))
}

#[cfg(not(any(unix, windows)))]
fn file_identity(_file: &File) -> FileResult<(u64, u64)> {
    Err(LibraryFileError::Io(
        "file identity is unsupported on this platform".into(),
    ))
}

#[cfg(test)]
#[path = "library_files_tests.rs"]
mod tests;
#[cfg(test)]
use tests::{CopyPhase, test_checkpoint};
