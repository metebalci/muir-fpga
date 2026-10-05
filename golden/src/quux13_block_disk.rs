// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
//! **QUUX revision 13's block-disk** (contract G2 §4.2, appendix A1.10 and
//! A1.11) as muir's `block_disk::BlockDisk::write` answers a script of
//! register reads and writes at given instants, over a pack and a main
//! memory of 40-bit words whose first contents are a rule both sides know.
//! Each line:
//!
//! ```text
//! geometry BLOCKS MEMWORDS    the pack's blocks and main memory's words
//! pack LBA                    block LBA holds `pack_word(LBA, w)`
//! raw LBA W0 ... W255         block LBA holds these 256 words
//! mem ADDR WORD               main memory's word ADDR, 40 bits
//! w REG VALUE NS              a write of register REG at NS
//! r REG VALUE NS              a read of register REG at NS, and its word
//! i LEVEL NS                  the done interrupt at NS
//! view PAGE LBA               at the end, main memory's page PAGE read 4
//!                             bytes a word, byte i in word i/4 at 8(i mod
//!                             4), is the pack's blocks LBA to LBA + 3 as
//!                             bytes, and every word of it has tag 005
//! page PAGE HASH              at the end, main memory's 1024-word page
//! block LBA HASH              at the end, block LBA of the pack
//! ```
//!
//! A page is 1,024 words, and an entry of the command list names one by
//! `<27:10>`, `<0>` More.  Command `<12>` chooses the transfer: 0 the packed
//! transfer, 5 blocks a page, the page's 5,120 bytes as main memory holds
//! them (G1 §4.1); 1 the 4-byte transfer, 4 blocks a page, `<31:0>` of each
//! word, a read writing tag `005` and a write dropping the tag.
//!
//!     quux13_block_disk               the transfers, on a pack three blocks
//!                                     short of block-disk's 2^28
//!     quux13_block_disk --whole-space the transfers that reach block 2^28,
//!                                     on a pack of all 2^28 blocks
//!
//! **THE READS ARE TAKEN WHERE THE FABRIC CAN ANSWER THEM.**  muir moves the
//! words at START and knows the disk address, the last memory address and
//! the errors then; the fabric walks the command list over the blocks' time
//! (`rtl/machine/quux_block_disk.sv` says why), so a register is read here
//! once the walk has had `WALK_NS` a page, and the status's not-active bit
//! and the interrupt on either side of muir's instant.  Every page of main
//! memory and every block the script names is compared at the end, whole.
//! Every value is hexadecimal and every instant in nanoseconds.
//!
//! **THE GPT FIXTURE** (muir-sim's `data/quux-disk.img`, the disk muir's
//! own test reads, `the_gpt_reads_through_a_4_byte_transfer`): its first
//! four blocks are put in the pack and read by a 4-byte transfer, and this
//! generator asserts, as muir's test does, that the page read 4 bytes a word
//! is the file's bytes, `EFI PART` at 512, every word tag `005`, before it
//! writes the `view` line the testbench holds the fabric to.

use muir::block_disk::{self, BlockDisk};
use muir::disk_image::{Disk, MAX_BLOCKS};
use muir::disk_unit::BLOCK_WORDS;
use muir::machine::Word;

const MUIR_DATA: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../muir-sim/data");

/// A page of revision 13: 1,024 words.
const PAGE: u32 = 1024;

/// The pack's first contents: a word that is a function of the block and the
/// word, so no wrong block and no wrong offset reads right.
fn pack_word(lba: u32, w: u32) -> u32 {
    (lba << 12) ^ (w << 1) ^ 0x5a00_0001 ^ lba.rotate_left(23)
}

/// Main memory's first contents: 40 bits, every byte of it a function of
/// the address, the tag included, so that a word from the wrong place or a
/// byte in the wrong place of its word reads wrong.
fn mem_word(a: u32) -> Word {
    let x = (u64::from(a) + 1).wrapping_mul(0x9e37_79b9_7f4a_7c15);
    (x >> 17 ^ 0x5a_c3a5_3c0f) & ((1 << 40) - 1)
}

/// FNV-1a over words of `bytes` bytes each, least significant first.
fn hash(words: &[Word], bytes: usize) -> u32 {
    let mut h = 0x811c_9dc5u32;
    for &w in words {
        for k in 0..bytes {
            h ^= ((w >> (8 * k)) & 0xff) as u32;
            h = h.wrapping_mul(0x0100_0193);
        }
    }
    h
}

fn hash32(words: &[u32]) -> u32 {
    let w: Vec<Word> = words.iter().map(|&x| Word::from(x)).collect();
    hash(&w, 4)
}

/// What the fabric's walk is given for a page before its registers are
/// read: the pack side's latency for five blocks and 1,024 memory cycles,
/// with room, and well inside muir's 400 us or 500 us of the page's blocks.
const WALK_NS: u64 = 150_000;

const READ: u32 = 0;
const WRITE: u32 = 0o11;
const DONE: u32 = 1 << 11;
/// Command `<12>`: the 4-byte transfer (A1.11).
const FOUR: u32 = 1 << 12;

/// A 40-bit word from its tag and field.
const fn w(tag: u64, field: u64) -> Word {
    tag << 32 | (field & 0xffff_ffff)
}

struct Script {
    d: BlockDisk,
    main: Vec<Word>,
    now: u64,
    blocks: Vec<u32>,
}

impl Script {
    fn at(&mut self, ns: u64) {
        assert!(ns >= self.now && ns % 10 == 0);
        self.now = ns;
        self.d.advance(ns);
    }
    fn w(&mut self, reg: u32, v: u32, ns: u64) {
        self.at(ns);
        self.d.write(reg, v, &mut self.main);
        println!("w {reg:x} {v:x} {ns:x}");
    }
    fn r(&mut self, reg: u32, ns: u64) -> u32 {
        self.at(ns);
        let v = self.d.read(reg);
        println!("r {reg:x} {v:x} {ns:x}");
        v
    }
    fn i(&mut self, ns: u64) -> bool {
        self.at(ns);
        let v = self.d.interrupt();
        println!("i {} {ns:x}", v as u8);
        v
    }
    fn mem(&mut self, a: u32, v: Word) {
        self.main[a as usize] = v;
        println!("mem {a:x} {v:x}");
    }
    /// A transfer: the list at `clp`, from block `da`, of `cmd`; then the
    /// registers read once the walk has had its time, and not-active and
    /// the interrupt on either side of muir's instant.  `pages` is what the
    /// walk is given time for, `moved` the blocks muir charges.  The status
    /// read once the walk is done.
    fn transfer(&mut self, clp: u32, da: u32, cmd: u32, pages: u64, moved: u64) -> u32 {
        let t = self.now + 1_000;
        self.w(block_disk::CLP, clp, t);
        self.w(block_disk::DA, da, t + 1_000);
        self.w(block_disk::COMMAND, cmd, t + 2_000);
        let start = t + 3_000;
        self.w(block_disk::START, 0, start);
        let seen = start + WALK_NS * pages.max(1);
        let s = self.r(block_disk::STATUS, seen);
        self.r(block_disk::CLP, seen + 20);
        self.r(block_disk::DA, seen + 40);
        let done = start + moved * block_disk::BLOCK_NS;
        if done > seen + 60 {
            self.r(block_disk::STATUS, done - 20);
            self.i(done - 10);
        }
        self.r(block_disk::STATUS, done.max(seen + 60));
        self.i(done.max(seen + 60) + 10);
        s
    }
    fn preload(&mut self, lba: u32) {
        let b: [u32; BLOCK_WORDS] = std::array::from_fn(|w| pack_word(lba, w as u32));
        assert!(self.d.disk_mut().unwrap().write_block(lba, &b));
        println!("pack {lba:x}");
        self.blocks.push(lba);
    }
    fn raw(&mut self, lba: u32, b: &[u32; BLOCK_WORDS]) {
        assert!(self.d.disk_mut().unwrap().write_block(lba, b));
        let words: Vec<String> = b.iter().map(|x| format!("{x:x}")).collect();
        println!("raw {lba:x} {}", words.join(" "));
        self.blocks.push(lba);
    }
    fn page_words(&self, page: u32) -> &[Word] {
        &self.main[page as usize..(page + PAGE) as usize]
    }
}

const ERROR: u32 = 1 << 13;
const PAST_END: u32 = 1 << 17;
const NXM: u32 = 1 << 20;

/// The script on a pack of `blocks` blocks: everything but the transfers
/// that reach block 2^28 (`whole_space`).
fn transfers(s: &mut Script, blocks: u32) {
    for lba in (0..8).chain([blocks - 3, blocks - 2, blocks - 1]).chain(1000..1040) {
        s.preload(lba);
    }
    s.r(block_disk::STATUS, 1_000);
    s.i(1_010);

    // **The packed transfer** (muir's `the_packed_transfer_moves_a_page_as_5_blocks`):
    // pages 4000 and 20000000, the second above 22 bits, written to blocks
    // 3-12 from a list above 22 bits, the first entry with `<9:1>` set and
    // More, the second with a tag; then read back into two other pages.
    let (p1, p2, list) = (0o4000u32, 0o20000000u32, 0o20002000u32);
    s.mem(list, Word::from(p1 | 0o776 | 1));
    s.mem(list + 1, w(0o377, p2.into()));
    let st = s.transfer(list, 3, WRITE | DONE, 2, 10);
    assert_eq!(st & ERROR, 0, "the packed write: status {st:o}");
    let (a, b) = (s.page_words(p1).to_vec(), s.page_words(p2).to_vec());
    let (q1, q2) = (0o10000u32, 0o12000u32);
    s.mem(0o100, Word::from(q1 | 1));
    s.mem(0o101, Word::from(q2));
    let st = s.transfer(0o100, 3, READ | DONE, 2, 10);
    assert_eq!(st & ERROR, 0);
    assert_eq!(s.page_words(q1), &a[..], "page 1 read back");
    assert_eq!(s.page_words(q2), &b[..], "page 2 read back");

    // **The 4-byte transfer** (muir's `the_4_byte_transfer_moves_a_page_as_4_blocks`):
    // page 4000 to blocks 100-103, the tags dropped, and back into page
    // 14000 with tag 005.
    s.mem(0o102, Word::from(p1));
    let st = s.transfer(0o102, 100, WRITE | FOUR, 1, 4);
    assert_eq!(st & ERROR, 0);
    s.mem(0o103, Word::from(0o14000u32));
    let st = s.transfer(0o103, 100, READ | FOUR | DONE, 1, 4);
    assert_eq!(st & ERROR, 0);
    for k in 0..PAGE as usize {
        assert_eq!(s.main[0o14000 + k], w(0o005, a[k]), "4-byte read back, word {k}");
    }
    // And the same four blocks by the packed transfer, which takes five:
    // the page's bytes are not its words, and the fifth block is 104's.
    s.mem(0o104, Word::from(0o16000u32));
    let st = s.transfer(0o104, 100, READ, 1, 5);
    assert_eq!(st & ERROR, 0);
    for lba in 100..105 {
        s.blocks.push(lba);
    }

    // **The GPT fixture through a 4-byte transfer and an 8-bit view**
    // (muir's `the_gpt_reads_through_a_4_byte_transfer`): its first four
    // blocks at 200-203, read into page 20000.
    let mut fixture = Disk::open(format!("{MUIR_DATA}/quux-disk.img")).expect("the GPT fixture");
    let mut file = Vec::new();
    for k in 0..4 {
        let blk = fixture.read_block(k).expect("the fixture's block");
        file.extend(blk.iter().flat_map(|x| x.to_le_bytes()));
        s.raw(200 + k, &blk);
    }
    s.mem(0o105, Word::from(0o20000u32));
    let st = s.transfer(0o105, 200, READ | FOUR, 1, 4);
    assert_eq!(st & ERROR, 0);
    let view: Vec<u8> = (0..4096).map(|i| (s.main[0o20000 + i / 4] >> (8 * (i % 4))) as u8).collect();
    assert_eq!(&view[512..520], b"EFI PART", "the header's signature");
    assert_eq!(view, file, "the 8-bit view is the file's bytes");
    assert!(s.page_words(0o20000).iter().all(|&x| x >> 32 == 0o005), "every word 005");
    println!("view {:x} {:x}", 0o20000, 200);

    // **A page outside main memory is NXM** (muir's
    // `a_page_outside_main_memory_is_nxm`): past main memory's end, and in
    // the frame buffer window; and a command list word past main memory.
    let end = s.main.len() as u32;
    for page in [end, 0o1760000000] {
        s.mem(0o106, Word::from(page));
        let st = s.transfer(0o106, 0, READ, 1, 0);
        assert_eq!(st & (NXM | ERROR), NXM | ERROR, "page {page:o}: status {st:o}");
    }
    let st = s.transfer(end + 5, 0, READ, 1, 0);
    assert_eq!(st & (NXM | ERROR), NXM | ERROR);
    // And NXM on a list's second entry, after its first page moved.
    s.mem(0o107, Word::from(0o22000u32 | 1));
    s.mem(0o110, Word::from(0o1760002000u32));
    let st = s.transfer(0o107, 300, READ | FOUR, 1, 4);
    assert_eq!(st & (NXM | ERROR), NXM | ERROR);

    // **The command list pointer takes 28 bits** (A1.10): written with
    // `<31:28>` set, which it drops, and a disk address with them set too.
    s.mem(0o20003000, Word::from(0o20010000u32));
    let st = s.transfer(0xf000_0000 | 0o20003000, 0xf000_0000 | 5, READ | FOUR, 1, 4);
    assert_eq!(st & ERROR, 0);
    // The disk address read back before a transfer: 28 bits of what was
    // written.
    let t = s.now + 1_000;
    s.w(block_disk::DA, 0xf000_0000 | 0o1234567, t);
    assert_eq!(s.r(block_disk::DA, t + 1_000), 0o1234567);
    // Its low sixteen bits count, and wrap (muir's "only bits <15:0> of the
    // CLP can count"): the list's second entry at the bottom of its 64K.
    s.mem(0o20377777, Word::from(0o24000u32 | 1));
    s.mem(0o20200000, Word::from(0o26000u32));
    let st = s.transfer(0o20377777, 6, READ, 2, 10);
    assert_eq!(st & ERROR, 0);

    // A command it does not do, then a clear by writing the command.
    let t = s.now + 1_000;
    s.w(block_disk::COMMAND, 0o03 | FOUR, t);
    s.w(block_disk::START, 0, t + 1_000);
    s.r(block_disk::STATUS, t + 2_000);
    s.w(block_disk::COMMAND, READ | FOUR, t + 3_000);
    s.r(block_disk::STATUS, t + 4_000);

    // **Past the end of the pack** (A1.11): a read whose page runs past it
    // leaves the page as it was, the disk address at the first block past
    // the end and the blocks read before it charged; a write writes the
    // blocks before it.
    s.mem(0o111, Word::from(0o30000u32));
    let st = s.transfer(0o111, blocks - 2, READ, 1, 2);
    assert_eq!(st & (PAST_END | ERROR), PAST_END | ERROR);
    s.mem(0o112, Word::from(0o32000u32 | 1));
    s.mem(0o113, Word::from(0o34000u32));
    let st = s.transfer(0o112, blocks - 8, WRITE | DONE, 2, 8);
    assert_eq!(st & (PAST_END | ERROR), PAST_END | ERROR);
    s.mem(0o114, Word::from(0o36000u32));
    let st = s.transfer(0o114, blocks - 1, WRITE | FOUR, 1, 1);
    assert_eq!(st & (PAST_END | ERROR), PAST_END | ERROR);
    // A read past the end from its first block.
    let st = s.transfer(0o114, blocks, READ | FOUR | DONE, 1, 0);
    assert_eq!(st & (PAST_END | ERROR), PAST_END | ERROR);
    for lba in blocks - 8..blocks {
        if !s.blocks.contains(&lba) {
            s.blocks.push(lba);
        }
    }

    // **Eight pages in one list**, 40 blocks: more than the store holds,
    // so blocks are written back and taken away as the walk goes, between
    // a page's blocks too.
    for k in 0..8u32 {
        let more = u32::from(k < 7);
        s.mem(0o1000 + k, Word::from((0o40000 + PAGE * k) | more));
    }
    let st = s.transfer(0o1000, 1000, READ | DONE, 8, 40);
    assert_eq!(st & ERROR, 0);
    let st = s.transfer(0o1000, 20000, WRITE | DONE, 8, 40);
    assert_eq!(st & ERROR, 0);
    for k in 20000..20040u32 {
        s.blocks.push(k);
    }
    let st = s.transfer(0o1000, 1000, READ | FOUR, 8, 32);
    assert_eq!(st & ERROR, 0);
    s.w(block_disk::COMMAND, 0, s.now + 1_000);
}

/// The transfers that reach block 2^28, on a pack of all 2^28 blocks: a
/// block number past the disk address's 28 bits is past the end, and never
/// block 0.
fn whole_space(s: &mut Script) {
    let top = MAX_BLOCKS as u32;
    for lba in [0, 1, 2, 3, top - 5, top - 4, top - 3, top - 2, top - 1] {
        s.preload(lba);
    }
    s.r(block_disk::STATUS, 1_000);
    // A 4-byte read from 2^28 - 2: two blocks, then 2^28.
    s.mem(0o100, Word::from(0o4000u32));
    let st = s.transfer(0o100, top - 2, READ | FOUR, 1, 2);
    assert_eq!(st & (PAST_END | ERROR), PAST_END | ERROR);
    // A packed write from 2^28 - 1, the most the register holds: one block.
    s.mem(0o101, Word::from(0o6000u32));
    let st = s.transfer(0o101, top - 1, WRITE, 1, 1);
    assert_eq!(st & (PAST_END | ERROR), PAST_END | ERROR);
    // A packed read of the last five blocks, and on past them with More.
    s.mem(0o102, Word::from(0o10000u32 | 1));
    s.mem(0o103, Word::from(0o12000u32));
    let st = s.transfer(0o102, top - 5, READ | DONE, 2, 5);
    assert_eq!(st & (PAST_END | ERROR), PAST_END | ERROR);
}

fn main() {
    let whole = match std::env::args().nth(1).as_deref() {
        None => false,
        Some("--whole-space") => true,
        Some(a) => {
            eprintln!("quux13_block_disk: unknown argument `{a}`; usage: quux13_block_disk [--whole-space]");
            std::process::exit(2);
        }
    };
    let blocks = if whole { MAX_BLOCKS as u32 } else { MAX_BLOCKS as u32 - 3 };
    let mem_words: u32 = 0o20400000;
    println!("# generated by golden/src/quux13_block_disk.rs from muir's block_disk::BlockDisk::write");
    println!("geometry {blocks:x} {mem_words:x}");
    let mut d = BlockDisk::new(block_disk::BLOCK_NS);
    d.attach(Disk::blank(blocks));
    let main: Vec<Word> = (0..mem_words).map(mem_word).collect();
    let mut s = Script { d, main, now: 0, blocks: Vec::new() };
    if whole {
        whole_space(&mut s);
    } else {
        transfers(&mut s, blocks);
    }

    // The end: every page, and every block named.
    for p in 0..(mem_words / PAGE) {
        println!("page {p:x} {:x}", hash(s.page_words(p * PAGE), 5));
    }
    let now = s.now;
    let named = s.blocks.clone();
    let u = s.d.disk_mut().unwrap();
    for lba in named {
        let b = u.read_block(lba).unwrap();
        println!("block {lba:x} {:x}", hash32(&b));
    }
    eprintln!("quux13_block_disk: the script ends at {now} ns");
}
