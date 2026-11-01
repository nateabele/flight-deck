use flightindex::chunk::{decode, encode, Decoded};
use flightindex::facts::*;
use flightindex::names::NameId;

fn sym(local_id: u32, name: &str, kind: SymbolKind, start: u32, end: u32, parent: Option<u32>) -> Symbol {
    Symbol {
        local_id,
        name: name.into(),
        kind,
        start_line: start,
        start_col: 4,
        end_line: end,
        end_col: 1,
        signature: local_id.is_multiple_of(2).then(|| format!("{name} : Int -> Ünïcode")),
        parent,
        exported: local_id.is_multiple_of(3),
    }
}

fn sample() -> Decoded {
    let symbols = vec![
        sym(0, "T", SymbolKind::Enum, 1, 3, None),
        sym(1, "C", SymbolKind::Constructor, 2, 2, Some(0)),
        sym(2, "variable", SymbolKind::Variable, 9, 40, None),
        // Out of source order and ending before it starts: nothing in the type forbids either.
        sym(3, "", SymbolKind::Extension, 5, 4, Some(2)),
    ];
    let imports = vec![
        Import {
            specifier: "B".into(),
            alias: Some("X".into()),
            names: vec![ImportName { name: "f".into(), alias: Some("g".into()), subs: false }, ImportName::plain("T")],
            line: 2,
            kind: ImportKind::Import,
        },
        Import { specifier: "crate::store".into(), alias: None, names: vec![], line: 1, kind: ImportKind::ModDecl },
        Import {
            specifier: "./x".into(),
            alias: None,
            names: vec![ImportName { name: "T".into(), alias: None, subs: true }],
            line: 7,
            kind: ImportKind::Reexport,
        },
    ];
    let refs = vec![
        RefSite::new(NameId(7), Some(NameId(3)), 5, Some(1), RefKind::Call),
        RefSite::new(NameId(7), None, 5, None, RefKind::Type),
        RefSite::new(NameId(u32::MAX - 1), Some(NameId(0)), u32::MAX, Some(u32::MAX - 1), RefKind::Use),
        RefSite::new(NameId(0), None, 1, Some(0), RefKind::Call),
    ];
    let hierarchy = vec![
        TypeRelation { symbol: 0, target: "Base".into(), kind: HierarchyKind::Implements },
        TypeRelation { symbol: 2, target: "Other".into(), kind: HierarchyKind::Extends },
    ];
    Decoded { symbols, imports, refs, hierarchy }
}

fn round_trip(d: &Decoded) -> Decoded {
    decode(&encode(&d.symbols, &d.imports, &d.refs, &d.hierarchy)).unwrap()
}

#[test]
fn every_field_survives_a_round_trip() {
    let d = sample();
    assert_eq!(round_trip(&d), d);
}

#[test]
fn an_empty_blob_round_trips_in_a_few_bytes() {
    let d = Decoded::default();
    let bytes = encode(&[], &[], &[], &[]);
    assert!(bytes.len() <= 10, "{} bytes for nothing", bytes.len());
    assert_eq!(decode(&bytes).unwrap(), d);
}

#[test]
fn every_symbol_kind_round_trips() {
    let kinds = [
        "function", "method", "struct", "enum", "trait", "interface", "class", "type_alias", "const", "module", "field",
        "constructor", "impl", "port", "macro", "extension", "variable",
    ];
    let symbols: Vec<Symbol> =
        kinds.iter().enumerate().map(|(i, k)| sym(i as u32, k, SymbolKind::parse(k).unwrap(), i as u32, i as u32, None)).collect();
    let d = Decoded { symbols, ..Default::default() };
    assert_eq!(round_trip(&d), d);
}

/// A realistic reference column: a few hot names, lines rising in source order, kinds in runs.
/// This is what the columnar layout exists for, so hold it to a size: under 4 bytes a reference
/// (the row table paid ~23.5).
#[test]
fn a_large_reference_column_packs_to_a_few_bytes_a_reference() {
    let refs: Vec<RefSite> = (0..2000u32)
        .map(|i| {
            let name = NameId([3, 17, 17, 900, 3, 41][(i % 6) as usize] + (i % 50));
            let qual = (i % 4 == 0).then_some(NameId(12));
            RefSite::new(name, qual, 10 + i / 3, Some(i / 40), if i % 10 < 7 { RefKind::Call } else { RefKind::Use })
        })
        .collect();
    let d = Decoded { refs, ..Default::default() };
    let bytes = encode(&[], &[], &d.refs, &[]);
    assert!(bytes.len() < 4 * 2000, "{} bytes for 2000 references", bytes.len());
    assert_eq!(decode(&bytes).unwrap(), d);
}

#[test]
fn long_string_sections_are_compressed_and_still_round_trip() {
    let symbols: Vec<Symbol> = (0..200u32)
        .map(|i| {
            let mut s = sym(i, &format!("handleMessage{i}"), SymbolKind::Function, i * 3, i * 3 + 2, None);
            s.signature = Some(format!("handleMessage{i} : Msg -> Model -> ( Model, Cmd Msg )"));
            s
        })
        .collect();
    let raw: usize = symbols.iter().map(|s| s.name.len() + s.signature.as_ref().unwrap().len()).sum();
    let d = Decoded { symbols, ..Default::default() };
    let bytes = encode(&d.symbols, &[], &[], &[]);
    assert!(bytes.len() < raw / 3, "{} bytes for {raw} bytes of strings", bytes.len());
    assert_eq!(decode(&bytes).unwrap(), d);
}

/// The bytes come from a file: a truncated or flipped chunk is an error, never a panic or a
/// runaway allocation.
#[test]
fn a_damaged_chunk_is_an_error_not_a_panic() {
    let d = sample();
    let bytes = encode(&d.symbols, &d.imports, &d.refs, &d.hierarchy);
    for cut in 0..bytes.len() {
        let _ = decode(&bytes[..cut]); // must return, Ok or Err
        assert!(decode(&bytes[..cut]).is_err() || cut == bytes.len(), "truncated at {cut} decoded");
    }
    for i in 0..bytes.len() {
        for flip in [0x01u8, 0x80, 0xff] {
            let mut b = bytes.clone();
            b[i] ^= flip;
            let _ = decode(&b);
        }
    }
    assert!(decode(&[9]).is_err(), "unknown format");
    // A header claiming a huge width-0 column must be refused, not allocated.
    assert!(decode(&[1, 0, 0xff, 0xff, 0xff, 0xff, 0x0f, 0, 0, 0, 0]).is_err());
}
