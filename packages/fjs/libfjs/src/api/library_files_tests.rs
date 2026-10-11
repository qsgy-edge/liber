use super::*;
use std::cell::RefCell;
use std::path::PathBuf;
use std::sync::atomic::AtomicUsize;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum CopyPhase {
    Chunk,
    Verify,
}
type Hook = Box<dyn FnMut(&LibraryCopyJob, CopyPhase, &Path, &Path) -> FileResult<()>>;
thread_local! { static HOOK: RefCell<Option<Hook>> = RefCell::new(None); }

pub(super) fn test_checkpoint(
    job: &LibraryCopyJob,
    phase: CopyPhase,
    source: &Path,
    destination: &Path,
) -> FileResult<()> {
    HOOK.with_borrow_mut(|hook| match hook {
        Some(hook) => hook(job, phase, source, destination),
        None => Ok(()),
    })
}

struct Scratch(PathBuf);
impl Scratch {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "liber-library-files-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
    fn string(&self, name: &str) -> String {
        self.path(name).to_str().unwrap().to_owned()
    }
    fn write(&self, name: &str, bytes: &[u8]) {
        fs::write(self.path(name), bytes).unwrap();
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        HOOK.with_borrow_mut(|hook| *hook = None);
        fs::remove_dir_all(&self.0).unwrap();
    }
}

#[test]
fn exclusive_copy_verifies_known_digest_and_preserves_source() {
    let dir = Scratch::new();
    dir.write("source", b"abc");
    let job = LibraryCopyJob::new();
    let receipt = job
        .copy(dir.string("source"), dir.string("target"))
        .unwrap();
    assert_eq!(receipt.bytes_copied, 3);
    assert_eq!(
        receipt.sha256,
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
    assert_eq!(job.copied_bytes(), 3);
    assert_eq!(
        library_file_fingerprint(dir.string("target")).unwrap(),
        receipt
    );
    assert!(library_files_equal(dir.string("source"), dir.string("target")).unwrap());
    assert_eq!(fs::read(dir.path("source")).unwrap(), b"abc");
}

#[test]
fn existing_destination_and_source_aliases_are_untouched() {
    let dir = Scratch::new();
    dir.write("source", b"source");
    dir.write("target", b"previous");
    fs::hard_link(dir.path("source"), dir.path("alias")).unwrap();
    for target in ["target", "source", "alias"] {
        assert_eq!(
            LibraryCopyJob::new().copy(dir.string("source"), dir.string(target)),
            Err(LibraryFileError::AlreadyExists)
        );
    }
    assert_eq!(fs::read(dir.path("source")).unwrap(), b"source");
    assert_eq!(fs::read(dir.path("target")).unwrap(), b"previous");
}

#[test]
fn empty_and_multichunk_comparison_and_copy() {
    let dir = Scratch::new();
    for bytes in [
        vec![],
        (0..BUFFER_BYTES * 3 + 17)
            .map(|i| (i % 251) as u8)
            .collect(),
    ] {
        dir.write("source", &bytes);
        let receipt = LibraryCopyJob::new()
            .copy(dir.string("source"), dir.string("target"))
            .unwrap();
        assert_eq!(receipt.bytes_copied, bytes.len() as i64);
        assert_eq!(fs::read(dir.path("target")).unwrap(), bytes);
        assert!(library_files_equal(dir.string("source"), dir.string("target")).unwrap());
        fs::remove_file(dir.path("target")).unwrap();
    }
    let mut changed = fs::read(dir.path("source")).unwrap();
    *changed.last_mut().unwrap() ^= 1;
    dir.write("different", &changed);
    assert!(!library_files_equal(dir.string("source"), dir.string("different")).unwrap());
    dir.write("different", b"short");
    assert!(!library_files_equal(dir.string("source"), dir.string("different")).unwrap());
}

#[test]
fn cancellation_before_creation_and_between_chunks_cleans_only_partial() {
    let dir = Scratch::new();
    dir.write("source", &vec![42; BUFFER_BYTES * 4]);
    let before = LibraryCopyJob::new();
    before.cancel();
    assert_eq!(
        before.copy(dir.string("source"), dir.string("target")),
        Err(LibraryFileError::Cancelled)
    );
    assert!(!dir.path("target").exists());
    HOOK.with_borrow_mut(|hook| {
        *hook = Some(Box::new(|job, phase, _, _| {
            if phase == CopyPhase::Chunk {
                job.cancel();
            }
            Ok(())
        }))
    });
    let job = LibraryCopyJob::new();
    assert_eq!(
        job.copy(dir.string("source"), dir.string("target")),
        Err(LibraryFileError::Cancelled)
    );
    assert_eq!(job.copied_bytes(), BUFFER_BYTES as i64);
    assert!(!dir.path("target").exists());
    assert_eq!(
        fs::read(dir.path("source")).unwrap(),
        vec![42; BUFFER_BYTES * 4]
    );
}

#[test]
fn destination_corruption_and_source_changes_fail_verification() {
    let dir = Scratch::new();
    for corrupt_source in [false, true] {
        dir.write("source", b"old bytes");
        HOOK.with_borrow_mut(|hook| {
            *hook = Some(Box::new(move |_, phase, source, destination| {
                if phase == CopyPhase::Verify {
                    let changed = if corrupt_source { source } else { destination };
                    let modified = fs::metadata(changed).unwrap().modified().unwrap();
                    fs::write(changed, b"new bytes").unwrap();
                    // Keep length and timestamp unchanged: only a byte re-read
                    // can detect this corruption, not a metadata comparison.
                    OpenOptions::new()
                        .write(true)
                        .open(changed)
                        .unwrap()
                        .set_times(fs::FileTimes::new().set_modified(modified))
                        .unwrap();
                }
                Ok(())
            }))
        });
        assert_eq!(
            LibraryCopyJob::new().copy(dir.string("source"), dir.string("target")),
            Err(LibraryFileError::VerificationFailed)
        );
        assert!(!dir.path("target").exists());
        assert_eq!(
            fs::read(dir.path("source")).unwrap(),
            if corrupt_source {
                b"new bytes"
            } else {
                b"old bytes"
            }
        );
    }
}

#[test]
fn injected_disk_failure_removes_partial_and_reports_cause() {
    let dir = Scratch::new();
    dir.write("source", &vec![7; BUFFER_BYTES * 2]);
    HOOK.with_borrow_mut(|hook| {
        *hook = Some(Box::new(|_, phase, _, _| {
            if phase == CopyPhase::Chunk {
                return Err(io(std::io::Error::from(std::io::ErrorKind::StorageFull)));
            }
            Ok(())
        }))
    });
    assert!(matches!(
        LibraryCopyJob::new().copy(dir.string("source"), dir.string("target")),
        Err(LibraryFileError::Io(_))
    ));
    assert!(!dir.path("target").exists());
    assert_eq!(
        fs::read(dir.path("source")).unwrap(),
        vec![7; BUFFER_BYTES * 2]
    );
}

#[test]
fn failed_cleanup_is_explicit_and_never_deletes_a_substituted_file() {
    let dir = Scratch::new();
    dir.write("source", b"original");
    HOOK.with_borrow_mut(|hook| {
        *hook = Some(Box::new(|job, phase, _, destination| {
            if phase == CopyPhase::Verify {
                fs::rename(destination, destination.with_extension("partial")).unwrap();
                fs::write(destination, b"unrelated").unwrap();
                job.cancel();
            }
            Ok(())
        }))
    });
    let error = LibraryCopyJob::new()
        .copy(dir.string("source"), dir.string("target"))
        .unwrap_err();
    assert!(
        matches!(error, LibraryFileError::Io(ref message) if message.contains("cancelled") && message.contains("cleanup failed")),
        "{error:?}"
    );
    assert_eq!(fs::read(dir.path("target")).unwrap(), b"unrelated");
    assert_eq!(fs::read(dir.path("target.partial")).unwrap(), b"original");
    assert_eq!(fs::read(dir.path("source")).unwrap(), b"original");
}

#[test]
fn ordinary_io_failure_and_nonfiles_do_not_create_destinations() {
    let dir = Scratch::new();
    dir.write("source", b"abc");
    for source in [dir.string("missing"), dir.0.to_str().unwrap().to_owned()] {
        assert!(matches!(
            LibraryCopyJob::new().copy(source, dir.string("target")),
            Err(LibraryFileError::Io(_))
        ));
        assert!(!dir.path("target").exists());
    }
    assert!(matches!(
        LibraryCopyJob::new().copy(dir.string("source"), dir.string("missing/target")),
        Err(LibraryFileError::Io(_))
    ));
    assert!(library_file_fingerprint(dir.0.to_str().unwrap().to_owned()).is_err());
    assert_eq!(fs::read(dir.path("source")).unwrap(), b"abc");
}

#[test]
fn replacement_retains_verified_old_backup_and_consumes_staging() {
    let dir = Scratch::new();
    dir.write("old", b"previous book");
    dir.write("staged", b"updated book");
    library_replace_file(
        dir.string("staged"),
        dir.string("old"),
        dir.string("backup"),
    )
    .unwrap();
    assert_eq!(fs::read(dir.path("old")).unwrap(), b"updated book");
    assert_eq!(fs::read(dir.path("backup")).unwrap(), b"previous book");
    assert!(!dir.path("staged").exists());
}

#[test]
fn replacement_collision_and_hardlink_alias_preserve_all_inputs() {
    let dir = Scratch::new();
    dir.write("old", b"previous");
    dir.write("staged", b"updated");
    dir.write("backup", b"unrelated");
    assert_eq!(
        library_replace_file(
            dir.string("staged"),
            dir.string("old"),
            dir.string("backup")
        ),
        Err(LibraryFileError::AlreadyExists)
    );
    fs::hard_link(dir.path("old"), dir.path("alias")).unwrap();
    assert!(
        library_replace_file(
            dir.string("alias"),
            dir.string("old"),
            dir.string("fresh-backup")
        )
        .is_err()
    );
    assert!(!dir.path("fresh-backup").exists());
    assert_eq!(fs::read(dir.path("old")).unwrap(), b"previous");
    assert_eq!(fs::read(dir.path("staged")).unwrap(), b"updated");
    assert_eq!(fs::read(dir.path("backup")).unwrap(), b"unrelated");
}

#[test]
fn failed_replacement_preserves_old_bytes_and_backup() {
    let dir = Scratch::new();
    dir.write("old", b"previous");
    dir.write("staged", b"updated");
    let staged = dir.path("staged");
    HOOK.with_borrow_mut(|hook| {
        *hook = Some(Box::new(move |_, phase, _, _| {
            if phase == CopyPhase::Verify {
                fs::remove_file(&staged).unwrap();
            }
            Ok(())
        }))
    });
    assert!(
        library_replace_file(
            dir.string("staged"),
            dir.string("old"),
            dir.string("backup")
        )
        .is_err()
    );
    assert_eq!(fs::read(dir.path("old")).unwrap(), b"previous");
    assert_eq!(fs::read(dir.path("backup")).unwrap(), b"previous");
}

#[cfg(windows)]
#[test]
fn replacement_os_failure_keeps_staging_destination_and_verified_backup() {
    use std::os::windows::fs::OpenOptionsExt;
    let dir = Scratch::new();
    dir.write("old", b"previous");
    dir.write("staged", b"updated");
    // Permit reads/writes but deny delete-sharing: copying the backup succeeds,
    // while the actual Windows replacing rename must fail.
    let held = OpenOptions::new()
        .read(true)
        .share_mode(1 | 2)
        .open(dir.path("old"))
        .unwrap();
    let result = library_replace_file(
        dir.string("staged"),
        dir.string("old"),
        dir.string("backup"),
    );
    drop(held);
    assert!(matches!(result, Err(LibraryFileError::Io(_))), "{result:?}");
    assert_eq!(fs::read(dir.path("old")).unwrap(), b"previous");
    assert_eq!(fs::read(dir.path("staged")).unwrap(), b"updated");
    assert_eq!(fs::read(dir.path("backup")).unwrap(), b"previous");
}

#[test]
fn cancellation_during_verification_removes_owned_partial() {
    let dir = Scratch::new();
    dir.write("source", b"original");
    HOOK.with_borrow_mut(|hook| {
        *hook = Some(Box::new(|job, phase, _, _| {
            if phase == CopyPhase::Verify {
                job.cancel();
            }
            Ok(())
        }))
    });
    assert_eq!(
        LibraryCopyJob::new().copy(dir.string("source"), dir.string("target")),
        Err(LibraryFileError::Cancelled)
    );
    assert!(!dir.path("target").exists());
    assert_eq!(fs::read(dir.path("source")).unwrap(), b"original");
}
