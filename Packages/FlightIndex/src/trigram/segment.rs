//! One immutable segment file: the trigram postings of a contiguous run of blob ordinals.
//!
//! ```text
//! header   8  magic "FDTRI\0\0\x01"
//!          4  first ordinal          4  blob count
//!          4  trigram count          4  reserved (0)
//! blobs    20 x blob count           binary SHA-1 of ordinal first+i
//! dict     16 x trigram count        u32 trigram, u32 offset, u32 byte length, u32 count | ROARING
//!                                    (sorted by trigram; offset relative to the postings start)
//! postings                           per trigram: delta varints of its ordinals, or a serialized
//!                                    Roaring bitmap when that is smaller (the high bit of count)
//! ```
//!
//! All integers are little-endian. Postings are absolute ordinals, so segments are concatenated by
//! union. A segment is written to a temporary name and renamed into place, so a reader sees a
//! whole file or none; it is then mapped read-only and never changed.

use super::plan::Trigram;
use roaring::RoaringBitmap;
use std::collections::BTreeMap;
use std::io::{BufWriter, Write};
use std::path::Path;

const MAGIC: &[u8; 8] = b"FDTRI\0\0\x01";
const HEADER: usize = 24;
const DICT_ENTRY: usize = 16;
const ROARING: u32 = 1 << 31;

pub type BlobKey = [u8; 20];

/// A read-only memory map of a whole file.
struct Map {
    ptr: *const u8,
    len: usize,
}

// The mapping is read-only and lives until `Drop`; sharing it is sharing `&[u8]`.
unsafe impl Send for Map {}
unsafe impl Sync for Map {}

impl Map {
    fn open(path: &Path) -> std::io::Result<Map> {
        use std::os::fd::AsRawFd;
        let f = std::fs::File::open(path)?;
        let len = f.metadata()?.len() as usize;
        if len == 0 {
            return Ok(Map { ptr: std::ptr::NonNull::dangling().as_ptr(), len: 0 });
        }
        // SAFETY: a fresh read-only private mapping of a file this process never writes after the
        // rename that published it; the pointer is checked against MAP_FAILED.
        let ptr = unsafe { libc::mmap(std::ptr::null_mut(), len, libc::PROT_READ, libc::MAP_PRIVATE, f.as_raw_fd(), 0) };
        if ptr == libc::MAP_FAILED {
            return Err(std::io::Error::last_os_error());
        }
        Ok(Map { ptr: ptr as *const u8, len })
    }

    fn bytes(&self) -> &[u8] {
        // SAFETY: `ptr` maps `len` readable bytes until drop.
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }
}

impl Drop for Map {
    fn drop(&mut self) {
        if self.len > 0 {
            // SAFETY: unmapping exactly what `open` mapped.
            unsafe { libc::munmap(self.ptr as *mut libc::c_void, self.len) };
        }
    }
}

pub struct Segment {
    map: Map,
    pub first: u32,
    pub blobs: u32,
    trigrams: u32,
    dict_at: usize,
    postings_at: usize,
}

fn u32_at(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(b[at..at + 4].try_into().unwrap())
}

fn bad(path: &Path, why: &str) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidData, format!("{}: {why}", path.display()))
}

impl Segment {
    pub fn open(path: &Path) -> std::io::Result<Segment> {
        let map = Map::open(path)?;
        let b = map.bytes();
        if b.len() < HEADER || &b[..8] != MAGIC {
            return Err(bad(path, "not a trigram segment"));
        }
        let (first, blobs, trigrams) = (u32_at(b, 8), u32_at(b, 12), u32_at(b, 16));
        let dict_at = HEADER + blobs as usize * 20;
        let postings_at = dict_at + trigrams as usize * DICT_ENTRY;
        if postings_at > b.len() {
            return Err(bad(path, "truncated"));
        }
        // Every posting must lie inside the file, so a lookup never has to check again.
        let total = b.len() - postings_at;
        for i in 0..trigrams as usize {
            let e = dict_at + i * DICT_ENTRY;
            let (off, len) = (u32_at(b, e + 4) as usize, u32_at(b, e + 8) as usize);
            if off + len > total {
                return Err(bad(path, "posting out of bounds"));
            }
        }
        Ok(Segment { map, first, blobs, trigrams, dict_at, postings_at })
    }

    pub fn end(&self) -> u32 {
        self.first + self.blobs
    }

    pub fn blob(&self, i: u32) -> BlobKey {
        let at = HEADER + i as usize * 20;
        self.map.bytes()[at..at + 20].try_into().unwrap()
    }

    pub fn bytes(&self) -> usize {
        self.map.len
    }

    pub fn trigram_count(&self) -> u32 {
        self.trigrams
    }

    fn entry(&self, i: usize) -> (Trigram, usize, usize, u32) {
        let b = self.map.bytes();
        let e = self.dict_at + i * DICT_ENTRY;
        (u32_at(b, e), u32_at(b, e + 4) as usize, u32_at(b, e + 8) as usize, u32_at(b, e + 12))
    }

    /// The ordinals holding trigram `t`, or `None` when no blob of this segment does.
    pub fn postings(&self, t: Trigram) -> Option<RoaringBitmap> {
        let (mut lo, mut hi) = (0usize, self.trigrams as usize);
        while lo < hi {
            let mid = (lo + hi) / 2;
            match self.entry(mid).0.cmp(&t) {
                std::cmp::Ordering::Less => lo = mid + 1,
                std::cmp::Ordering::Greater => hi = mid,
                std::cmp::Ordering::Equal => return Some(self.decode(mid)),
            }
        }
        None
    }

    fn decode(&self, i: usize) -> RoaringBitmap {
        let (_, off, len, count) = self.entry(i);
        let data = &self.map.bytes()[self.postings_at + off..self.postings_at + off + len];
        if count & ROARING != 0 {
            return RoaringBitmap::deserialize_from(data).unwrap_or_default();
        }
        let mut out = RoaringBitmap::new();
        let mut prev = 0u32;
        let mut pos = 0usize;
        for _ in 0..count {
            let Some((d, n)) = read_varint(&data[pos..]) else { break };
            pos += n;
            prev = prev.wrapping_add(d);
            let _ = out.try_push(prev);
        }
        out
    }

    /// Every `(trigram, postings)` in trigram order: what a merge reads.
    pub fn iter(&self) -> impl Iterator<Item = (Trigram, RoaringBitmap)> + '_ {
        (0..self.trigrams as usize).map(|i| (self.entry(i).0, self.decode(i)))
    }
}

fn read_varint(b: &[u8]) -> Option<(u32, usize)> {
    let mut v = 0u32;
    for (i, &byte) in b.iter().enumerate().take(5) {
        v |= ((byte & 0x7f) as u32) << (7 * i);
        if byte & 0x80 == 0 {
            return Some((v, i + 1));
        }
    }
    None
}

fn write_varint(out: &mut Vec<u8>, mut v: u32) {
    while v >= 0x80 {
        out.push((v as u8) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

/// The smaller encoding of one posting list, and its count field.
fn encode(bits: &RoaringBitmap, scratch: &mut Vec<u8>) -> u32 {
    scratch.clear();
    let mut prev = 0u32;
    for (i, o) in bits.iter().enumerate() {
        write_varint(scratch, if i == 0 { o } else { o - prev });
        prev = o;
    }
    let count = bits.len() as u32;
    if bits.serialized_size() < scratch.len() {
        scratch.clear();
        bits.serialize_into(&mut *scratch).expect("writing to a Vec");
        return count | ROARING;
    }
    count
}

/// Write a segment of `blobs` (ordinals `first..`) whose postings come, in ascending trigram
/// order, from `postings`; to `path` through a temporary file and a rename.
pub fn write(path: &Path, first: u32, blobs: &[BlobKey], postings: impl Iterator<Item = (Trigram, RoaringBitmap)>) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    // Postings first, to a scratch file, since the dictionary that precedes them needs their sizes.
    let data_tmp = path.with_extension("data.tmp");
    let mut dict: Vec<u8> = Vec::new();
    let mut trigrams = 0u32;
    {
        let mut data = BufWriter::new(std::fs::File::create(&data_tmp)?);
        let mut off = 0u64;
        let mut scratch = Vec::new();
        let mut last: Option<Trigram> = None;
        for (t, bits) in postings {
            if bits.is_empty() {
                continue;
            }
            debug_assert!(last.is_none_or(|l| l < t), "trigrams out of order");
            last = Some(t);
            let count = encode(&bits, &mut scratch);
            data.write_all(&scratch)?;
            if off + scratch.len() as u64 > u32::MAX as u64 {
                return Err(std::io::Error::other("segment postings exceed 4 GB"));
            }
            for v in [t, off as u32, scratch.len() as u32, count] {
                dict.extend_from_slice(&v.to_le_bytes());
            }
            off += scratch.len() as u64;
            trigrams += 1;
        }
        data.flush()?;
    }
    let result = (|| {
        let mut out = BufWriter::new(std::fs::File::create(&tmp)?);
        out.write_all(MAGIC)?;
        for v in [first, blobs.len() as u32, trigrams, 0] {
            out.write_all(&v.to_le_bytes())?;
        }
        for b in blobs {
            out.write_all(b)?;
        }
        out.write_all(&dict)?;
        std::io::copy(&mut std::fs::File::open(&data_tmp)?, &mut out)?;
        out.flush()?;
        out.get_ref().sync_all()?;
        std::fs::rename(&tmp, path)
    })();
    let _ = std::fs::remove_file(&data_tmp);
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

/// The distinct trigrams of `content`, ASCII-folded, sorted. Windows holding a newline are left
/// out: the body search matches one line at a time, so no match contains one, and a query
/// trigram that does can be answered "nowhere".
pub fn trigrams_of(content: &[u8]) -> Vec<Trigram> {
    let mut out: Vec<Trigram> = content
        .windows(3)
        .filter(|w| !w.contains(&b'\n'))
        .map(|w| super::plan::trigram(w[0], w[1], w[2]))
        .collect();
    out.sort_unstable();
    out.dedup();
    out
}

/// Invert the trigram sets of consecutive ordinals `first..` into sorted postings.
pub fn invert(first: u32, sets: &[Vec<Trigram>]) -> BTreeMap<Trigram, RoaringBitmap> {
    let mut lists: std::collections::HashMap<Trigram, Vec<u32>> = std::collections::HashMap::new();
    for (i, set) in sets.iter().enumerate() {
        for &t in set {
            lists.entry(t).or_default().push(first + i as u32);
        }
    }
    lists.into_iter().map(|(t, ords)| (t, RoaringBitmap::from_sorted_iter(ords).expect("ordinals ascend"))).collect()
}

/// The union, trigram by trigram, of several segments' postings, streamed in trigram order with
/// one posting list per segment in memory at a time.
pub fn merged<'a>(segments: &'a [&'a Segment]) -> impl Iterator<Item = (Trigram, RoaringBitmap)> + 'a {
    type Postings<'a> = std::iter::Peekable<Box<dyn Iterator<Item = (Trigram, RoaringBitmap)> + 'a>>;
    let mut iters: Vec<Postings<'a>> = segments.iter().map(|s| (Box::new(s.iter()) as Box<dyn Iterator<Item = _>>).peekable()).collect();
    std::iter::from_fn(move || {
        let t = iters.iter_mut().filter_map(|i| i.peek().map(|(t, _)| *t)).min()?;
        let mut bits = RoaringBitmap::new();
        for i in iters.iter_mut() {
            if i.peek().is_some_and(|(u, _)| *u == t) {
                bits |= i.next().unwrap().1;
            }
        }
        Some((t, bits))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_segment_round_trips_both_encodings() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.seg");
        let mut long = RoaringBitmap::new();
        long.insert_range(5..60_000);
        let short: RoaringBitmap = [7u32, 9, 300, 70_000].into_iter().collect();
        let blobs = vec![[1u8; 20], [2u8; 20]];
        write(&path, 5, &blobs, vec![(10, short.clone()), (20, long.clone())].into_iter()).unwrap();
        let s = Segment::open(&path).unwrap();
        assert_eq!((s.first, s.blobs, s.end()), (5, 2, 7));
        assert_eq!(s.blob(1), [2u8; 20]);
        assert_eq!(s.postings(10), Some(short));
        assert_eq!(s.postings(20), Some(long));
        assert_eq!(s.postings(15), None);
    }

    #[test]
    fn a_truncated_segment_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.seg");
        write(&path, 0, &[[0u8; 20]], vec![(1, [0u32].into_iter().collect())].into_iter()).unwrap();
        let bytes = std::fs::read(&path).unwrap();
        std::fs::write(&path, &bytes[..bytes.len() - 1]).unwrap();
        assert!(Segment::open(&path).is_err());
    }

    #[test]
    fn trigrams_skip_newlines_and_fold_case() {
        let t = trigrams_of(b"AbC\nabc");
        assert_eq!(t, vec![super::super::plan::trigram(b'a', b'b', b'c')]);
    }
}
