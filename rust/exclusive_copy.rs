//! Some removable/network volumes lack rename-without-replacement. On those
//! volumes claim each destination with exclusive create, copy to its open
//! descriptor, and roll back only names and inodes created by this operation.
use super::*;
use std::os::unix::fs::OpenOptionsExt;

pub(super) fn volume_supports(parent: &Path, flag: u32) -> Option<bool> {
    let path = c_path(parent).ok()?;
    let mut attributes = libc::attrlist {
        bitmapcount: libc::ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: 0,
        volattr: libc::ATTR_VOL_INFO | libc::ATTR_VOL_CAPABILITIES,
        dirattr: 0,
        fileattr: 0,
        forkattr: 0,
    };
    // length followed by capabilities[4], then valid[4], all native u32.
    let mut data = [0u32; 9];
    let result = unsafe {
        libc::getattrlist(
            path.as_ptr(),
            (&mut attributes as *mut libc::attrlist).cast(),
            data.as_mut_ptr().cast(),
            size_of_val(&data),
            0,
        )
    };
    let index = libc::VOL_CAPABILITIES_INTERFACES;
    if result != 0 || data[0] < size_of_val(&data) as u32 || data[5 + index] & flag == 0 {
        None
    } else {
        Some(data[1 + index] & flag != 0)
    }
}

#[derive(Default)]
pub(super) struct Claims {
    items: Vec<(PathBuf, u64, u64)>,
}

impl Claims {
    pub(super) fn new_item(&mut self, path: &Path, meta: fs::Metadata) {
        self.items.push((path.to_owned(), meta.dev(), meta.ino()));
    }

    // Use O_EXCL when obtaining the final file. All subsequent data and
    // metadata writes use this descriptor, even if another process renames it.
    pub(super) fn copy_file(&mut self, source: &Path, target: &Path, mode: u32) -> io::Result<()> {
        if mode & libc::S_IFMT as u32 == libc::S_IFLNK as u32 {
            std::os::unix::fs::symlink(fs::read_link(source)?, target)?;
            self.new_item(target, fs::symlink_metadata(target)?);
            return copy_item(source, target, true);
        }
        let reader = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(source)?;
        let writer = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(target)?;
        self.new_item(target, writer.metadata()?);
        let flags =
            libc::COPYFILE_DATA | libc::COPYFILE_STAT | libc::COPYFILE_ACL | libc::COPYFILE_XATTR;
        let result = if unsafe {
            libc::fcopyfile(
                reader.as_raw_fd(),
                writer.as_raw_fd(),
                std::ptr::null_mut(),
                flags,
            )
        } != 0
        {
            Err(io::Error::last_os_error())
        } else {
            writer.sync_all()
        };
        // exFAT assigns a different synthetic inode after the first data cluster
        // is allocated. Refresh from the same open descriptor, never from a name.
        let final_meta = writer.metadata()?;
        if let Some(claim) = self.items.last_mut() {
            claim.1 = final_meta.dev();
            claim.2 = final_meta.ino();
        }
        result
    }

    fn current(path: &Path, device: u64, inode: u64) -> io::Result<Option<fs::Metadata>> {
        match fs::symlink_metadata(path) {
            Ok(meta) if meta.dev() == device && meta.ino() == inode => Ok(Some(meta)),
            Ok(_) => Ok(None),
            Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(err) => Err(err),
        }
    }

    fn cleanup(&self) -> io::Result<()> {
        for (path, device, inode) in &self.items {
            if let Some(meta) = Self::current(path, *device, *inode)? {
                relax_owned(path, &meta);
            }
        }
        // rmdir intentionally fails for a directory receiving an unrelated item.
        // Never recursively delete a destination another application can see.
        let mut incomplete = None;
        for (path, device, inode) in self.items.iter().rev() {
            let removal = Self::current(path, *device, *inode).and_then(|item| match item {
                Some(meta) if meta.is_dir() => fs::remove_dir(path),
                Some(_) => fs::remove_file(path),
                None => Ok(()),
            });
            if let Err(err) = removal {
                incomplete.get_or_insert(err);
            }
        }
        incomplete.map_or(Ok(()), Err)
    }

    fn still_owned(&self) -> io::Result<()> {
        for (path, device, inode) in &self.items {
            if Self::current(path, *device, *inode)?.is_none() {
                return Err(io::Error::other(format!(
                    "{} was replaced during the transfer.",
                    path.display()
                )));
            }
        }
        Ok(())
    }
}

pub(super) fn copy(
    source: &Path,
    destination: &Path,
    manifest: &[(PathBuf, Stamp)],
) -> io::Result<()> {
    let mut claims = Claims::default();
    let result = copy_tree(source, destination, manifest, Some(&mut claims))
        .and_then(|_| claims.still_owned())
        .and_then(|_| check_unchanged(manifest));
    match result {
        Ok(()) => Ok(()),
        Err(err) if claims.items.is_empty() => Err(err),
        Err(err) => {
            let cause = if err.raw_os_error() == Some(libc::EINVAL) {
                format!("{err}. Choose an APFS destination to preserve the item's macOS metadata.")
            } else {
                err.to_string()
            };
            match claims.cleanup() {
                Ok(()) => Err(io::Error::other(format!(
                    "Could not copy {}: {cause}",
                    source.display()
                ))),
                Err(cleanup) => Err(io::Error::other(format!(
                    "Could not copy {}: {cause}. A partial copy remains at {}: {cleanup}",
                    source.display(),
                    destination.display()
                ))),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rollback_keeps_replacements_and_unrelated_children() {
        let root = std::env::temp_dir().join(format!("finger-claim-test-{}", std::process::id()));
        fs::create_dir(&root).unwrap();
        let created = root.join("new folder");
        fs::create_dir(&created).unwrap();
        let ours = created.join("ours");
        fs::write(&ours, "partial").unwrap();
        let replacement = created.join("replacement");
        fs::write(&replacement, "partial").unwrap();
        // Keep the old inode alive to guarantee the replaced file is distinct.
        let held = fs::File::open(&replacement).unwrap();
        let mut claims = Claims::default();
        for path in [&created, &ours, &replacement] {
            claims.new_item(path, fs::symlink_metadata(path).unwrap());
        }
        fs::remove_file(&replacement).unwrap();
        fs::write(&replacement, "another writer").unwrap();
        let other = created.join("unrelated");
        fs::write(&other, "independent").unwrap();
        let result = claims.cleanup();
        let remains = (
            fs::read_to_string(&replacement).unwrap(),
            fs::read_to_string(&other).unwrap(),
        );
        let ours_removed = !ours.exists();
        drop(held);
        fs::remove_dir_all(&root).unwrap();
        assert!(result.is_err() && ours_removed);
        assert_eq!(
            remains,
            ("another writer".to_owned(), "independent".to_owned())
        );
    }
}
