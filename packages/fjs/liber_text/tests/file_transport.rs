//! Path/owned-file/borrowed-descriptor parity without changing decoding rules.
use liber_text::*;
use std::fs::{self, File};
use std::io::{Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

static TEST_FILES: std::sync::Mutex<()> = std::sync::Mutex::new(());
struct Scratch(
    PathBuf,
    #[allow(dead_code)] std::sync::MutexGuard<'static, ()>,
);
impl Scratch {
    fn new(name: &str) -> Self {
        let guard = TEST_FILES.lock().unwrap();
        let path = std::env::temp_dir().join(format!(
            "liber-text-transport-{}-{name}",
            std::process::id()
        ));
        fs::create_dir(&path).unwrap();
        Self(path, guard)
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

fn positioned_file(path: &Path) -> File {
    let mut file = File::open(path).unwrap();
    file.seek(SeekFrom::End(0)).unwrap();
    file
}

fn encodings() -> Vec<(&'static str, Vec<u8>)> {
    let text = include_str!("data/chaptered_book.txt").repeat(30);
    let (gbk, _, errors) = encoding_rs::GBK.encode(&text);
    assert!(!errors);
    let mut le = vec![0xff, 0xfe];
    let mut be = vec![0xfe, 0xff];
    for unit in text.encode_utf16() {
        le.extend(unit.to_le_bytes());
        be.extend(unit.to_be_bytes());
    }
    let mut utf8_bom = vec![0xef, 0xbb, 0xbf];
    utf8_bom.extend_from_slice(text.as_bytes());
    vec![
        ("utf8", text.as_bytes().to_vec()),
        ("utf8-bom", utf8_bom),
        ("gbk", gbk.into_owned()),
        ("utf16le", le),
        ("utf16be", be),
    ]
}

#[test]
fn owned_files_rewind_and_preserve_path_index_and_deep_windows_for_all_encodings() {
    let scratch = Scratch::new("owned");
    for (name, bytes) in encodings() {
        let path = scratch.0.join(name);
        fs::write(&path, bytes).unwrap();
        assert_eq!(
            detect_open_file(positioned_file(&path)).unwrap(),
            detect_encoding(&path).unwrap()
        );
        let index = index_file(&path, &IndexOptions::default()).unwrap();
        assert_eq!(
            index_open_file(positioned_file(&path), &IndexOptions::default()).unwrap(),
            index
        );
        for offset in [
            index.code_unit_length - 64,
            0,
            80001,
            7,
            index.code_unit_length - 1,
        ] {
            let anchor = index
                .anchors
                .iter()
                .rev()
                .find(|a| a.code_unit_offset <= offset)
                .copied();
            assert_eq!(
                read_window_file(
                    positioned_file(&path),
                    &index.encoding,
                    anchor,
                    offset,
                    113,
                    1 << 20
                )
                .unwrap(),
                read_window(&path, &index.encoding, anchor, offset, 113, 1 << 20).unwrap()
            );
        }
    }
}

#[test]
fn owned_file_sparse_seek_uses_the_supplied_anchor() {
    let scratch = Scratch::new("sparse");
    let path = scratch.0.join("sparse");
    let mut file = File::create(&path).unwrap();
    let deep = 8 * 1024 * 1024;
    file.seek(SeekFrom::Start(deep)).unwrap();
    file.write_all("深处正文\n".as_bytes()).unwrap();
    drop(file);
    let anchor = Anchor {
        byte_offset: deep,
        code_unit_offset: deep,
        line_index: 1,
    };
    let window =
        read_window_file(positioned_file(&path), "UTF-8", Some(anchor), deep, 4, 32).unwrap();
    assert_eq!(window.text, "深处正文");
    assert_eq!(window.byte_offset, deep);
}

#[cfg(not(unix))]
#[test]
fn descriptors_are_explicitly_unsupported_off_unix() {
    for error in [
        detect_encoding_fd(-1).unwrap_err(),
        index_fd(0, &IndexOptions::default()).unwrap_err(),
        read_window_fd(0, "UTF-8", None, 0, 1, 1).unwrap_err(),
    ] {
        assert!(matches!(error, TextError::Io(ref message) if message.contains("unsupported")));
    }
}

#[cfg(unix)]
mod unix {
    use super::*;
    use std::io::Read;
    use std::os::fd::{AsRawFd, FromRawFd};

    #[test]
    fn borrowed_fd_matches_paths_across_encodings_and_repeated_deep_seeks() {
        let scratch = Scratch::new("fd-parity");
        for (name, bytes) in encodings() {
            let path = scratch.0.join(name);
            fs::write(&path, &bytes).unwrap();
            let mut original = positioned_file(&path);
            let fd = original.as_raw_fd();
            let probe = duplicate_descriptor(fd).unwrap();
            let available_fd = probe.as_raw_fd();
            drop(probe);
            let index = index_file(&path, &IndexOptions::default()).unwrap();
            for _ in 0..8 {
                assert_eq!(
                    detect_encoding_fd(fd).unwrap(),
                    detect_encoding(&path).unwrap()
                );
                assert_eq!(index_fd(fd, &IndexOptions::default()).unwrap(), index);
                assert_eq!(
                    read_window_fd(fd, &index.encoding, None, 0, 113, 1 << 20).unwrap(),
                    read_window(&path, &index.encoding, None, 0, 113, 1 << 20).unwrap(),
                );
                for offset in [index.code_unit_length - 17, 0, 80001, 7] {
                    let anchor = index
                        .anchors
                        .iter()
                        .rev()
                        .find(|a| a.code_unit_offset <= offset)
                        .copied();
                    assert_eq!(
                        read_window_fd(fd, &index.encoding, anchor, offset, 113, 1 << 20).unwrap(),
                        read_window(&path, &index.encoding, anchor, offset, 113, 1 << 20).unwrap()
                    );
                }
                original.rewind().unwrap();
                let mut first = [0; 4];
                original.read_exact(&mut first).unwrap();
                assert_eq!(&first, &bytes[..4]);
                // All file-transport tests serialize scratch IO. A leaked
                // duplicate would occupy this lowest available descriptor.
                let probe = duplicate_descriptor(fd).unwrap();
                assert_eq!(
                    probe.as_raw_fd(),
                    available_fd,
                    "descriptor leaked by an entrypoint"
                );
            }
        }
    }

    #[test]
    fn descriptor_and_path_zero_windows_keep_ascii_and_multibyte_prefixes() {
        let scratch = Scratch::new("fd-zero");
        for text in [
            "ABCDE正文
下一行
",
            "第一章正文
下一行
",
        ] {
            let path = scratch.0.join("book");
            fs::write(&path, text).unwrap();
            let file = File::open(&path).unwrap();
            let expected = read_window(&path, "UTF-8", None, 0, 5, 1024).unwrap();
            assert_eq!(expected.text, text.chars().take(5).collect::<String>());
            assert_eq!(
                read_window_fd(file.as_raw_fd(), "UTF-8", None, 0, 5, 1024).unwrap(),
                expected
            );
        }
    }

    #[test]
    fn duplicate_lifetime_is_independent_and_owned_duplicate_closes() {
        let scratch = Scratch::new("fd-lifetime");
        let path = scratch.0.join("book");
        fs::write(&path, b"chapter\nbody\n").unwrap();
        let original = File::open(&path).unwrap();
        let duplicate = duplicate_descriptor(original.as_raw_fd()).unwrap();
        assert_ne!(duplicate.as_raw_fd(), original.as_raw_fd());
        drop(original);
        assert_eq!(
            read_window_file(duplicate, "UTF-8", None, 0, 7, 32)
                .unwrap()
                .text,
            "chapter"
        );

        // This test runs alone as an exact gate when checking descriptor counts;
        // OS duplication of a closed duplicate must fail before it is reused.
        let original = File::open(&path).unwrap();
        for _ in 0..100 {
            let duplicate = duplicate_descriptor(original.as_raw_fd()).unwrap();
            let raw = duplicate.as_raw_fd();
            drop(duplicate);
            unsafe extern "C" {
                fn fcntl(fd: i32, cmd: i32, ...) -> i32;
            }
            assert_eq!(unsafe { fcntl(raw, 1) }, -1); // F_GETFD
        }
        assert!(original.metadata().is_ok());
    }

    #[test]
    fn negative_closed_and_pipe_descriptors_are_rejected_without_reading() {
        let scratch = Scratch::new("fd-rejection");
        let path = scratch.0.join("book");
        fs::write(&path, b"body").unwrap();
        let file = File::open(&path).unwrap();
        let closed = file.as_raw_fd();
        drop(file);
        assert!(matches!(detect_encoding_fd(-1), Err(TextError::Io(_))));
        assert!(matches!(detect_encoding_fd(closed), Err(TextError::Io(_))));
        unsafe extern "C" {
            fn pipe(fds: *mut i32) -> i32;
        }
        let mut fds = [-1; 2];
        assert_eq!(unsafe { pipe(fds.as_mut_ptr()) }, 0);
        let read = unsafe { File::from_raw_fd(fds[0]) };
        let mut write = unsafe { File::from_raw_fd(fds[1]) };
        // The empty pipe's writer stays open: attempting to read would hang.
        assert!(matches!(
            detect_encoding_fd(read.as_raw_fd()),
            Err(TextError::Io(_))
        ));
        assert!(matches!(
            index_fd(read.as_raw_fd(), &IndexOptions::default()),
            Err(TextError::Io(_))
        ));
        assert!(matches!(
            read_window_fd(read.as_raw_fd(), "UTF-8", None, 0, 1, 32),
            Err(TextError::Io(_))
        ));
        write.write_all(b"x").unwrap();
        let mut read = read;
        let mut byte = [0];
        read.read_exact(&mut byte).unwrap();
        assert_eq!(byte, [b'x']);
    }

    #[test]
    fn descriptor_reads_sparse_deep_anchor_without_scanning_prefix() {
        let scratch = Scratch::new("fd-sparse");
        let path = scratch.0.join("book");
        let deep = 8 * 1024 * 1024;
        let mut file = File::create(&path).unwrap();
        file.seek(SeekFrom::Start(deep)).unwrap();
        file.write_all(b"deep book\n").unwrap();
        drop(file);
        let file = File::open(&path).unwrap();
        let anchor = Anchor {
            byte_offset: deep,
            code_unit_offset: deep,
            line_index: 1,
        };
        for _ in 0..100 {
            assert_eq!(
                read_window_fd(file.as_raw_fd(), "UTF-8", Some(anchor), deep, 9, 32)
                    .unwrap()
                    .text,
                "deep book"
            );
        }
        assert!(file.metadata().is_ok());
    }
}
