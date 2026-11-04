use std::fmt;
use std::io::{self, Read, Write};

use super::indexes::wire::{decode_index, encode_index};
use super::indexes::IndexTransfer;

pub const MAGIC: [u8; 4] = *b"PGPC";
pub const HEADER_LEN: usize = 10;
pub const PAGE_HEADER_LEN: usize = 12;
const SCHEMA_MAGIC: [u8; 4] = *b"PGPS";
const SCHEMA_HEADER_LEN: usize = 6;
const MAX_STRING: usize = 1024 * 1024;
const MAX_RELATIONS: usize = 1024;
const MAX_ATTRIBUTES: usize = 1600;

#[derive(Debug)]
pub struct WireError(pub String);

impl fmt::Display for WireError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<io::Error> for WireError {
    fn from(error: io::Error) -> Self {
        Self(error.to_string())
    }
}

impl From<WireError> for String {
    fn from(error: WireError) -> Self {
        error.0
    }
}

pub type Result<T> = std::result::Result<T, WireError>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum RelationKind {
    Main = 0,
    Toast = 1,
    Index = 2,
}

impl RelationKind {
    fn decode(value: u8) -> Result<Self> {
        match value {
            0 => Ok(Self::Main),
            1 => Ok(Self::Toast),
            2 => Ok(Self::Index),
            _ => Err(WireError(format!("unknown relation kind {value}"))),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Relation {
    pub oid: u32,
    pub name: String,
    pub kind: RelationKind,
    pub fork: u8,
    pub blocks: u32,
    pub toast_index_oid: u32,
}

#[allow(clippy::struct_excessive_bools)] // These are independent PostgreSQL catalog flags.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Attribute {
    pub name: String,
    pub type_name: String,
    pub collation_name: Option<String>,
    pub collation_version: String,
    pub collation_actual_version: String,
    pub typmod: i32,
    pub len: i16,
    pub align: u8,
    pub by_val: bool,
    pub storage: u8,
    pub has_missing: bool,
    pub generated: u8,
    pub not_null: bool,
    pub dropped: bool,
}

pub fn validate_attributes(attributes: &[Attribute]) -> std::result::Result<(), String> {
    const SAFE_TYPES: &[&str] = &[
        "bool",
        "bytea",
        "char",
        "name",
        "int8",
        "int2",
        "int4",
        "text",
        "json",
        "xml",
        "point",
        "path",
        "polygon",
        "line",
        "circle",
        "box",
        "float4",
        "float8",
        "bpchar",
        "varchar",
        "date",
        "time",
        "timestamp",
        "timestamptz",
        "interval",
        "numeric",
        "uuid",
        "jsonb",
        "money",
        "inet",
        "cidr",
        "macaddr",
        "macaddr8",
        "bit",
        "varbit",
        "pg_lsn",
        "tsvector",
        "tsquery",
        "jsonpath",
    ];
    for attribute in attributes.iter().filter(|attribute| !attribute.dropped) {
        if attribute.has_missing {
            return Err(format!(
                "column {} uses fast defaults/missing values, which are not supported",
                attribute.name
            ));
        }
        if attribute.generated == b'v' {
            return Err(format!(
                "column {} is a virtual generated column, which is not supported",
                attribute.name
            ));
        }
        if attribute.generated != 0 && attribute.generated != b's' {
            return Err(format!(
                "column {} has an unknown generated kind",
                attribute.name
            ));
        }
        let base = attribute
            .type_name
            .strip_prefix("pg_catalog._")
            .or_else(|| attribute.type_name.strip_prefix("pg_catalog."))
            .map(|base| base.trim_matches('"'));
        if !base.is_some_and(|base| SAFE_TYPES.contains(&base)) {
            return Err(format!(
                "column {} has unsafe type {}; only built-in types without catalog OIDs in their values are supported",
                attribute.name, attribute.type_name
            ));
        }
    }
    Ok(())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SchemaColumn {
    pub name: String,
    pub type_name: String,
    pub collation_name: Option<String>,
    pub default_expr: Option<String>,
    pub not_null: bool,
    pub identity: String,
    pub generated_expr: Option<String>,
    pub storage: u8,
    pub dropped: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SchemaIndex {
    /// Source index name, reused verbatim when auto-creating the target index.
    pub name: String,
    /// The part after `USING`, deliberately independent of source table/index names.
    pub definition: String,
    pub unique: bool,
}

/// State of a sequence owned by a source column, read under the source lock.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SequenceState {
    pub column: String,
    pub last_value: i64,
    pub is_called: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TableSchema {
    pub columns: Vec<SchemaColumn>,
    pub constraints: Vec<String>,
    pub indexes: Vec<SchemaIndex>,
    pub sequences: Vec<SequenceState>,
}

/// Freeze horizons copied from the source `pg_class` rows. A cross-cluster
/// transfer freezes every tuple, so the target can keep its default
/// horizons; a local (same-cluster) transfer keeps original xids and must
/// inherit these, or vacuum could assume xids it must still freeze.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FreezeHorizons {
    pub relfrozenxid: u32,
    pub relminmxid: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Manifest {
    pub source_table: String,
    pub target_table: String,
    pub source_checksums: bool,
    pub target_checksums: bool,
    pub relations: Vec<Relation>,
    pub attributes: Vec<Attribute>,
    pub indexes: Vec<IndexTransfer>,
    pub source_horizons: FreezeHorizons,
    pub toast_horizons: Option<FreezeHorizons>,
}

impl Manifest {
    pub fn encode(&self) -> Result<Vec<u8>> {
        let mut out = Vec::new();
        put_string(&mut out, &self.source_table)?;
        put_string(&mut out, &self.target_table)?;
        out.push(u8::from(self.source_checksums));
        out.push(u8::from(self.target_checksums));
        put_u32(&mut out, self.source_horizons.relfrozenxid)?;
        put_u32(&mut out, self.source_horizons.relminmxid)?;
        let toast_horizons = self.toast_horizons.unwrap_or_default();
        put_u32(&mut out, toast_horizons.relfrozenxid)?;
        put_u32(&mut out, toast_horizons.relminmxid)?;
        put_len(&mut out, self.relations.len(), MAX_RELATIONS, "relations")?;
        for relation in &self.relations {
            put_u32(&mut out, relation.oid)?;
            put_string(&mut out, &relation.name)?;
            out.push(relation.kind as u8);
            out.push(relation.fork);
            put_u32(&mut out, relation.blocks)?;
            put_u32(&mut out, relation.toast_index_oid)?;
        }
        put_len(
            &mut out,
            self.attributes.len(),
            MAX_ATTRIBUTES,
            "attributes",
        )?;
        for attribute in &self.attributes {
            put_string(&mut out, &attribute.name)?;
            put_string(&mut out, &attribute.type_name)?;
            put_optional_string(&mut out, attribute.collation_name.as_deref())?;
            put_string(&mut out, &attribute.collation_version)?;
            put_string(&mut out, &attribute.collation_actual_version)?;
            out.extend_from_slice(&attribute.typmod.to_be_bytes());
            out.extend_from_slice(&attribute.len.to_be_bytes());
            out.push(attribute.align);
            out.push(u8::from(attribute.by_val));
            out.push(attribute.storage);
            out.push(u8::from(attribute.has_missing));
            out.push(attribute.generated);
            out.push(u8::from(attribute.not_null));
            out.push(u8::from(attribute.dropped));
        }
        put_len(&mut out, self.indexes.len(), MAX_RELATIONS, "indexes")?;
        for index in &self.indexes {
            encode_index(&mut out, index)?;
        }
        Ok(out)
    }

    pub fn decode(input: &[u8]) -> Result<Self> {
        let mut decoder = Decoder::new(input);
        let source_table = decoder.string()?;
        let target_table = decoder.string()?;
        let source_checksums = decoder.boolean()?;
        let target_checksums = decoder.boolean()?;
        let source_horizons = FreezeHorizons {
            relfrozenxid: decoder.u32()?,
            relminmxid: decoder.u32()?,
        };
        let toast_raw = FreezeHorizons {
            relfrozenxid: decoder.u32()?,
            relminmxid: decoder.u32()?,
        };
        let toast_horizons = (toast_raw != FreezeHorizons::default()).then_some(toast_raw);
        let relation_count = decoder.len(MAX_RELATIONS, "relations")?;
        let mut relations = Vec::with_capacity(relation_count);
        for _ in 0..relation_count {
            relations.push(Relation {
                oid: decoder.u32()?,
                name: decoder.string()?,
                kind: RelationKind::decode(decoder.u8()?)?,
                fork: decoder.u8()?,
                blocks: decoder.u32()?,
                toast_index_oid: decoder.u32()?,
            });
        }
        let attribute_count = decoder.len(MAX_ATTRIBUTES, "attributes")?;
        let mut attributes = Vec::with_capacity(attribute_count);
        for _ in 0..attribute_count {
            attributes.push(Attribute {
                name: decoder.string()?,
                type_name: decoder.string()?,
                collation_name: decoder.optional_string()?,
                collation_version: decoder.string()?,
                collation_actual_version: decoder.string()?,
                typmod: decoder.i32()?,
                len: decoder.i16()?,
                align: decoder.u8()?,
                by_val: decoder.boolean()?,
                storage: decoder.u8()?,
                has_missing: decoder.boolean()?,
                generated: decoder.u8()?,
                not_null: decoder.boolean()?,
                dropped: decoder.boolean()?,
            });
        }
        let index_count = decoder.len(MAX_RELATIONS, "indexes")?;
        let mut indexes = Vec::with_capacity(index_count);
        for _ in 0..index_count {
            indexes.push(decode_index(&mut decoder)?);
        }
        if decoder.offset != input.len() {
            return Err(WireError("trailing bytes in manifest".into()));
        }
        Ok(Self {
            source_table,
            target_table,
            source_checksums,
            target_checksums,
            relations,
            attributes,
            indexes,
            source_horizons,
            toast_horizons,
        })
    }
}

pub fn encode_schema(schema: &TableSchema) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    out.extend_from_slice(&SCHEMA_MAGIC);
    out.extend_from_slice(&0u16.to_be_bytes());
    put_len(
        &mut out,
        schema.columns.len(),
        MAX_ATTRIBUTES,
        "schema columns",
    )?;
    for column in &schema.columns {
        put_string(&mut out, &column.name)?;
        put_string(&mut out, &column.type_name)?;
        put_optional_string(&mut out, column.collation_name.as_deref())?;
        put_optional_string(&mut out, column.default_expr.as_deref())?;
        out.push(u8::from(column.not_null));
        put_string(&mut out, &column.identity)?;
        put_optional_string(&mut out, column.generated_expr.as_deref())?;
        out.push(column.storage);
        out.push(u8::from(column.dropped));
    }
    put_len(
        &mut out,
        schema.constraints.len(),
        MAX_RELATIONS,
        "constraints",
    )?;
    for constraint in &schema.constraints {
        put_string(&mut out, constraint)?;
    }
    put_len(
        &mut out,
        schema.indexes.len(),
        MAX_RELATIONS,
        "schema indexes",
    )?;
    for index in &schema.indexes {
        put_string(&mut out, &index.definition)?;
        out.push(u8::from(index.unique));
        put_string(&mut out, &index.name)?;
    }
    put_len(
        &mut out,
        schema.sequences.len(),
        MAX_ATTRIBUTES,
        "schema sequences",
    )?;
    for sequence in &schema.sequences {
        put_string(&mut out, &sequence.column)?;
        out.extend_from_slice(&sequence.last_value.to_be_bytes());
        out.push(u8::from(sequence.is_called));
    }
    Ok(out)
}

pub fn decode_schema(input: &[u8]) -> Result<TableSchema> {
    if input.len() < SCHEMA_HEADER_LEN || input[..4] != SCHEMA_MAGIC {
        return Err(WireError("bad pg_pagecopy schema magic".into()));
    }
    if input[4] != 0 || input[5] != 0 {
        return Err(WireError("unsupported pg_pagecopy schema header".into()));
    }
    let mut decoder = Decoder::new(&input[SCHEMA_HEADER_LEN..]);
    let column_count = decoder.len(MAX_ATTRIBUTES, "schema columns")?;
    let mut columns = Vec::with_capacity(column_count);
    for _ in 0..column_count {
        columns.push(SchemaColumn {
            name: decoder.string()?,
            type_name: decoder.string()?,
            collation_name: decoder.optional_string()?,
            default_expr: decoder.optional_string()?,
            not_null: decoder.boolean()?,
            identity: decoder.string()?,
            generated_expr: decoder.optional_string()?,
            storage: decoder.u8()?,
            dropped: decoder.boolean()?,
        });
    }
    let constraint_count = decoder.len(MAX_RELATIONS, "constraints")?;
    let mut constraints = Vec::with_capacity(constraint_count);
    for _ in 0..constraint_count {
        constraints.push(decoder.string()?);
    }
    let index_count = decoder.len(MAX_RELATIONS, "schema indexes")?;
    let mut indexes = Vec::with_capacity(index_count);
    for _ in 0..index_count {
        indexes.push(SchemaIndex {
            definition: decoder.string()?,
            unique: decoder.boolean()?,
            name: decoder.string()?,
        });
    }
    let sequence_count = decoder.len(MAX_ATTRIBUTES, "schema sequences")?;
    let mut sequences = Vec::with_capacity(sequence_count);
    for _ in 0..sequence_count {
        sequences.push(SequenceState {
            column: decoder.string()?,
            last_value: decoder.i64()?,
            is_called: decoder.boolean()?,
        });
    }
    if decoder.offset != decoder.input.len() {
        return Err(WireError("trailing bytes in schema descriptor".into()));
    }
    Ok(TableSchema {
        columns,
        constraints,
        indexes,
        sequences,
    })
}

#[cfg(test)]
pub struct StreamWriter<W> {
    inner: W,
}

#[cfg(test)]
impl<W: Write> StreamWriter<W> {
    pub fn new(mut inner: W, manifest: &Manifest) -> Result<Self> {
        inner.write_all(&encode_header(manifest)?)?;
        Ok(Self { inner })
    }

    pub fn page(&mut self, relation: u16, fork: u8, block: u32, page: &[u8]) -> Result<()> {
        self.inner
            .write_all(&encode_page(relation, fork, block, page)?)?;
        Ok(())
    }

    pub fn done(mut self) -> Result<W> {
        self.inner.write_all(&[0, 0, 0, 0])?;
        self.inner.flush()?;
        Ok(self.inner)
    }
}

pub fn encode_header(manifest: &Manifest) -> Result<Vec<u8>> {
    let manifest = manifest.encode()?;
    let mut output = Vec::with_capacity(HEADER_LEN + manifest.len());
    output.extend_from_slice(&MAGIC);
    // Version 2: freeze horizons joined the manifest after target_checksums.
    output.extend_from_slice(&2u16.to_be_bytes());
    put_u32(
        &mut output,
        u32::try_from(manifest.len()).map_err(|_| WireError("manifest too large".into()))?,
    )?;
    output.extend_from_slice(&manifest);
    Ok(output)
}

pub fn encode_page(relation: u16, fork: u8, block: u32, page: &[u8]) -> Result<Vec<u8>> {
    if page.len() != 8192 {
        return Err(WireError(format!("invalid page size {}", page.len())));
    }
    let mut output = Vec::with_capacity(PAGE_HEADER_LEN + page.len());
    put_u16(&mut output, relation)?;
    output.extend_from_slice(&[fork, 0]);
    put_u32(&mut output, block)?;
    put_u32(
        &mut output,
        u32::try_from(page.len()).expect("page length fits u32"),
    )?;
    output.extend_from_slice(page);
    Ok(output)
}

pub struct StreamReader<R> {
    #[allow(dead_code)] // Production consumes only the header; tests also read pages.
    inner: R,
    pub manifest: Manifest,
}

impl<R: Read> StreamReader<R> {
    pub fn new(mut inner: R) -> Result<Self> {
        let mut header = [0u8; HEADER_LEN];
        inner.read_exact(&mut header)?;
        if header[..4] != MAGIC {
            return Err(WireError("bad pg_pagecopy magic".into()));
        }
        if header[4..6] != 2u16.to_be_bytes() {
            return Err(WireError("unsupported pg_pagecopy stream version".into()));
        }
        let length = usize::try_from(u32::from_be_bytes(header[6..10].try_into().unwrap()))
            .expect("u32 length fits usize");
        if length == 0 || length > MAX_STRING * 16 {
            return Err(WireError(format!("invalid manifest length {length}")));
        }
        let mut manifest = vec![0; length];
        inner.read_exact(&mut manifest)?;
        let manifest = Manifest::decode(&manifest)?;
        Ok(Self { inner, manifest })
    }

    #[cfg(test)]
    pub fn next(&mut self) -> Result<Option<PagePacket>> {
        let mut first = [0u8; 4];
        match self.inner.read_exact(&mut first) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => {
                return Err(WireError("truncated pg_pagecopy stream".into()));
            }
            Err(error) => return Err(error.into()),
        }
        let mut header = [0u8; PAGE_HEADER_LEN];
        header[..4].copy_from_slice(&first);
        if first == [0, 0, 0, 0] {
            let mut fifth = [0u8; 1];
            match self.inner.read_exact(&mut fifth) {
                Ok(()) => header[4] = fifth[0],
                Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => {
                    return Ok(None);
                }
                Err(error) => return Err(error.into()),
            }
            self.inner.read_exact(&mut header[5..])?;
        } else {
            self.inner.read_exact(&mut header[4..])?;
        }
        if header[3] != 0 {
            return Err(WireError("unsupported page packet flags".into()));
        }
        let length = usize::try_from(u32::from_be_bytes(header[8..12].try_into().unwrap()))
            .expect("u32 length fits usize");
        if length != 8192 {
            return Err(WireError(format!("invalid page payload length {length}")));
        }
        let mut bytes = vec![0; length];
        self.inner.read_exact(&mut bytes)?;
        Ok(Some(PagePacket {
            relation: u16::from_be_bytes([header[0], header[1]]),
            fork: header[2],
            block: u32::from_be_bytes(header[4..8].try_into().unwrap()),
            bytes,
        }))
    }
}

pub fn decode_pages(input: &[u8]) -> Result<Option<PagePackets<'_>>> {
    if input == [0, 0, 0, 0] {
        return Ok(None);
    }
    if input.is_empty() || !input.len().is_multiple_of(PAGE_HEADER_LEN + 8192) {
        return Err(WireError(format!(
            "invalid page chunk length {}",
            input.len()
        )));
    }
    Ok(Some(PagePackets { input }))
}

pub struct PagePackets<'a> {
    input: &'a [u8],
}

impl Iterator for PagePackets<'_> {
    type Item = Result<PagePacket>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.input.is_empty() {
            return None;
        }
        let (packet, rest) = self.input.split_at(PAGE_HEADER_LEN + 8192);
        self.input = rest;
        Some(decode_page(packet))
    }
}

fn decode_page(input: &[u8]) -> Result<PagePacket> {
    if input.len() != PAGE_HEADER_LEN + 8192 {
        return Err(WireError(format!(
            "invalid page row length {}",
            input.len()
        )));
    }
    if input[3] != 0 {
        return Err(WireError("unsupported page packet flags".into()));
    }
    let length = usize::try_from(u32::from_be_bytes(input[8..12].try_into().unwrap()))
        .expect("u32 length fits usize");
    if length != 8192 {
        return Err(WireError(format!("invalid page payload length {length}")));
    }
    Ok(PagePacket {
        relation: u16::from_be_bytes([input[0], input[1]]),
        fork: input[2],
        block: u32::from_be_bytes(input[4..8].try_into().unwrap()),
        bytes: input[PAGE_HEADER_LEN..].to_vec(),
    })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PagePacket {
    pub relation: u16,
    pub fork: u8,
    pub block: u32,
    pub bytes: Vec<u8>,
}

fn put_u16(output: &mut impl Write, value: u16) -> Result<()> {
    output.write_all(&value.to_be_bytes())?;
    Ok(())
}

pub(super) fn put_u32(output: &mut impl Write, value: u32) -> Result<()> {
    output.write_all(&value.to_be_bytes())?;
    Ok(())
}

fn put_len(output: &mut Vec<u8>, len: usize, max: usize, what: &str) -> Result<()> {
    if len > max {
        return Err(WireError(format!("too many {what}: {len}")));
    }
    put_u32(
        output,
        u32::try_from(len).map_err(|_| WireError(format!("too many {what}: {len}")))?,
    )?;
    Ok(())
}

pub(super) fn put_string(output: &mut Vec<u8>, value: &str) -> Result<()> {
    if value.len() > MAX_STRING {
        return Err(WireError("string exceeds wire limit".into()));
    }
    put_u32(
        output,
        u32::try_from(value.len()).map_err(|_| WireError("string exceeds wire limit".into()))?,
    )?;
    output.extend_from_slice(value.as_bytes());
    Ok(())
}

fn put_optional_string(output: &mut Vec<u8>, value: Option<&str>) -> Result<()> {
    output.push(u8::from(value.is_some()));
    if let Some(value) = value {
        put_string(output, value)?;
    }
    Ok(())
}

/// Shared manifest reader; `indexes::wire` decodes its index entries with it.
pub(super) struct Decoder<'a> {
    input: &'a [u8],
    offset: usize,
}

impl<'a> Decoder<'a> {
    pub(super) fn new(input: &'a [u8]) -> Self {
        Self { input, offset: 0 }
    }
}

impl Decoder<'_> {
    fn take(&mut self, length: usize) -> Result<&[u8]> {
        let end = self
            .offset
            .checked_add(length)
            .ok_or_else(|| WireError("length overflow".into()))?;
        let bytes = self
            .input
            .get(self.offset..end)
            .ok_or_else(|| WireError("truncated manifest".into()))?;
        self.offset = end;
        Ok(bytes)
    }

    pub(super) fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }

    pub(super) fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_be_bytes(self.take(4)?.try_into().unwrap()))
    }

    fn i32(&mut self) -> Result<i32> {
        Ok(i32::from_be_bytes(self.take(4)?.try_into().unwrap()))
    }

    fn i64(&mut self) -> Result<i64> {
        Ok(i64::from_be_bytes(self.take(8)?.try_into().unwrap()))
    }

    fn i16(&mut self) -> Result<i16> {
        Ok(i16::from_be_bytes(self.take(2)?.try_into().unwrap()))
    }

    pub(super) fn boolean(&mut self) -> Result<bool> {
        match self.u8()? {
            0 => Ok(false),
            1 => Ok(true),
            value => Err(WireError(format!("invalid boolean {value}"))),
        }
    }

    fn len(&mut self, max: usize, what: &str) -> Result<usize> {
        let len = usize::try_from(self.u32()?).expect("u32 length fits usize");
        if len > max {
            Err(WireError(format!("too many {what}: {len}")))
        } else {
            Ok(len)
        }
    }

    pub(super) fn string(&mut self) -> Result<String> {
        let length = usize::try_from(self.u32()?).expect("u32 length fits usize");
        if length > MAX_STRING {
            return Err(WireError("string exceeds wire limit".into()));
        }
        String::from_utf8(self.take(length)?.to_vec())
            .map_err(|_| WireError("manifest string is not UTF-8".into()))
    }

    fn optional_string(&mut self) -> Result<Option<String>> {
        if self.boolean()? {
            Ok(Some(self.string()?))
        } else {
            Ok(None)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pg_pagecopy::indexes::BtreeMetadata;

    fn attribute() -> Attribute {
        Attribute {
            name: "id".into(),
            type_name: "pg_catalog.int4".into(),
            collation_name: None,
            collation_version: String::new(),
            collation_actual_version: String::new(),
            typmod: -1,
            len: 4,
            align: b'i',
            by_val: true,
            storage: b'p',
            has_missing: false,
            generated: 0,
            not_null: true,
            dropped: false,
        }
    }

    fn manifest() -> Manifest {
        Manifest {
            source_table: "public.events".into(),
            target_table: "public.events_copy".into(),
            source_checksums: true,
            target_checksums: true,
            source_horizons: FreezeHorizons {
                relfrozenxid: 3,
                relminmxid: 1,
            },
            toast_horizons: None,
            relations: vec![Relation {
                oid: 42,
                name: "events".into(),
                kind: RelationKind::Main,
                fork: 0,
                blocks: 1,
                toast_index_oid: 0,
            }],
            attributes: vec![attribute()],
            indexes: vec![
                IndexTransfer::Btree(BtreeMetadata {
                    definition: "btree (id)".into(),
                    shape: "1|1|1|int4_ops".into(),
                    btree_version: 4,
                    all_equal_image: true,
                    expected_all_equal_image: true,
                }),
                IndexTransfer::Invalid {
                    definition: "hash (payload)".into(),
                    unique: false,
                },
            ],
        }
    }

    #[test]
    fn rejects_missing_values_virtual_columns_and_oid_bearing_types() {
        let missing = Attribute {
            has_missing: true,
            ..attribute()
        };
        assert!(validate_attributes(&[missing])
            .unwrap_err()
            .contains("missing values"));
        let virtual_column = Attribute {
            generated: b'v',
            ..attribute()
        };
        assert!(validate_attributes(&[virtual_column])
            .unwrap_err()
            .contains("virtual generated"));
        for type_name in [
            "public.mood",
            "pg_catalog._mood",
            "pg_catalog.regclass",
            "pg_catalog.oid",
            "pg_catalog.pg_class",
        ] {
            let unsafe_type = Attribute {
                type_name: type_name.into(),
                ..attribute()
            };
            assert!(validate_attributes(&[unsafe_type])
                .unwrap_err()
                .contains("unsafe type"));
        }
        let safe_array = Attribute {
            type_name: "pg_catalog._int4".into(),
            ..attribute()
        };
        assert!(validate_attributes(&[safe_array]).is_ok());
        let quoted_safe_type = Attribute {
            type_name: "pg_catalog.\"numeric\"".into(),
            ..attribute()
        };
        assert!(validate_attributes(&[quoted_safe_type]).is_ok());
    }

    #[test]
    fn schema_round_trip_preserves_target_independent_definitions() {
        let value = TableSchema {
            columns: vec![SchemaColumn {
                name: "payload".into(),
                type_name: "text".into(),
                collation_name: Some("pg_catalog.\"C\"".into()),
                default_expr: Some("'default'::text".into()),
                not_null: true,
                identity: String::new(),
                generated_expr: None,
                storage: b'e',
                dropped: false,
            }],
            constraints: vec!["CHECK (length(payload) > 0)".into()],
            indexes: vec![SchemaIndex {
                name: "events_index".into(),
                definition: "btree (payload)".into(),
                unique: true,
            }],
            sequences: vec![SequenceState {
                column: "id".into(),
                last_value: 42,
                is_called: true,
            }],
        };
        let encoded = encode_schema(&value).unwrap();
        assert_eq!(decode_schema(&encoded).unwrap(), value);
        assert!(!encoded
            .windows(b"source_table".len())
            .any(|w| w == b"source_table"));
    }

    #[test]
    fn manifest_round_trip() {
        let value = manifest();
        assert_eq!(Manifest::decode(&value.encode().unwrap()).unwrap(), value);
    }

    #[test]
    fn manifest_bytes_keep_their_complete_wire_layout() {
        // Golden bytes of the whole manifest body. The round trip above
        // cannot catch a symmetric encode/decode change; these bytes are the
        // on-wire contract between pg_pagecopy versions (header in
        // `headers_use_versioned_layout`, index tags 0/1 in `indexes::wire`).
        let mut expected: Vec<u8> = Vec::new();
        expected.extend_from_slice(b"\x00\x00\x00\x0dpublic.events");
        expected.extend_from_slice(b"\x00\x00\x00\x12public.events_copy");
        expected.extend_from_slice(&[1, 1]); // source/target checksum flags
        expected.extend_from_slice(&3u32.to_be_bytes()); // relfrozenxid
        expected.extend_from_slice(&1u32.to_be_bytes()); // relminmxid
        expected.extend_from_slice(&[0; 8]); // absent TOAST horizons
        expected.extend_from_slice(&1u32.to_be_bytes()); // relation count
        expected.extend_from_slice(b"\x00\x00\x00\x2a\x00\x00\x00\x06events");
        expected.extend_from_slice(&[0, 0]); // kind Main, fork
        expected.extend_from_slice(&1u32.to_be_bytes()); // blocks
        expected.extend_from_slice(&0u32.to_be_bytes()); // toast_index_oid
        expected.extend_from_slice(&1u32.to_be_bytes()); // attribute count
        expected.extend_from_slice(b"\x00\x00\x00\x02id");
        expected.extend_from_slice(b"\x00\x00\x00\x0fpg_catalog.int4");
        expected.extend_from_slice(&[0]); // no collation
        expected.extend_from_slice(&[0; 8]); // both collation versions empty
        expected.extend_from_slice(&(-1i32).to_be_bytes()); // typmod
        expected.extend_from_slice(&4i16.to_be_bytes()); // len
        expected.extend_from_slice(&[b'i', 1, b'p', 0, 0, 1, 0]);
        // align, by_val, storage, has_missing, generated, not_null, dropped
        expected.extend_from_slice(&2u32.to_be_bytes()); // index count
        expected.extend_from_slice(b"\x00\x00\x00\x00\x0abtree (id)"); // tag 0 + length
        expected.extend_from_slice(b"\x00\x00\x00\x0e1|1|1|int4_ops");
        expected.extend_from_slice(&4u32.to_be_bytes()); // btree version
        expected.extend_from_slice(&[1, 1]); // dedup layout flags
        expected.extend_from_slice(b"\x01\x00\x00\x00\x0ehash (payload)"); // tag 1
        expected.extend_from_slice(&[0]); // not unique
        assert_eq!(manifest().encode().unwrap(), expected);
    }

    #[test]
    fn rejects_truncated_trailing_and_unknown_kind_manifests() {
        let bytes = manifest().encode().unwrap();
        assert!(Manifest::decode(&bytes[..bytes.len() - 1]).is_err());
        let mut trailing = bytes.clone();
        trailing.push(0);
        assert!(Manifest::decode(&trailing).is_err());
        // The kind byte follows the relation name, the last "events".
        let kind = bytes.windows(6).rposition(|w| w == b"events").unwrap() + 6;
        let mut unknown_kind = bytes.clone();
        unknown_kind[kind] = 3;
        assert!(Manifest::decode(&unknown_kind).is_err());
    }

    #[test]
    fn page_stream_round_trip() {
        let value = manifest();
        let mut bytes = Vec::new();
        let mut writer = StreamWriter::new(&mut bytes, &value).unwrap();
        writer.page(0, 0, 7, &[5; 8192]).unwrap();
        writer.done().unwrap();
        let mut reader = StreamReader::new(bytes.as_slice()).unwrap();
        let packet = reader.next().unwrap().unwrap();
        assert_eq!(packet.block, 7);
        assert_eq!(packet.bytes, vec![5; 8192]);
        assert!(reader.next().unwrap().is_none());
    }

    #[test]
    fn decodes_multiple_pages_from_one_chunk() {
        let first = encode_page(0, 0, 7, &[5; 8192]).unwrap();
        let second = encode_page(1, 1, 0, &[9; 8192]).unwrap();
        let chunk = [first.clone(), second.clone()].concat();
        let packets: Vec<_> = decode_pages(&chunk)
            .unwrap()
            .unwrap()
            .collect::<Result<_>>()
            .unwrap();
        assert_eq!(packets.len(), 2);
        assert_eq!(packets[0].block, 7);
        assert_eq!(packets[0].bytes, vec![5; 8192]);
        assert_eq!(packets[1].relation, 1);
        assert_eq!(packets[1].fork, 1);
        assert_eq!(packets[1].bytes, vec![9; 8192]);
        assert!(decode_pages(&[0, 0, 0, 0]).unwrap().is_none());
        assert!(decode_pages(&chunk[..chunk.len() - 1]).is_err());
        assert!(decode_pages(&[]).is_err());
    }

    #[test]
    fn headers_use_versioned_layout() {
        let header = encode_header(&manifest()).unwrap();
        assert_eq!(HEADER_LEN, 10);
        assert_eq!(&header[..6], b"PGPC\0\x02");
        let manifest_length =
            usize::try_from(u32::from_be_bytes(header[6..10].try_into().unwrap())).unwrap();
        assert_eq!(manifest_length, header.len() - HEADER_LEN);

        let schema = encode_schema(&TableSchema {
            columns: Vec::new(),
            constraints: Vec::new(),
            indexes: Vec::new(),
            sequences: Vec::new(),
        })
        .unwrap();
        assert_eq!(SCHEMA_HEADER_LEN, 6);
        assert_eq!(&schema[..6], b"PGPS\0\0");
    }

    #[test]
    fn rejects_bad_flags_and_truncated_headers() {
        let mut header = encode_header(&manifest()).unwrap();
        header[4] = 1;
        assert!(StreamReader::new(header.as_slice()).is_err());
        header[4] = 0;
        header[5] = 0;
        assert!(StreamReader::new(header.as_slice()).is_err());
        assert!(StreamReader::new(&header[..HEADER_LEN - 1]).is_err());

        let mut schema = encode_schema(&TableSchema {
            columns: Vec::new(),
            constraints: Vec::new(),
            indexes: Vec::new(),
            sequences: Vec::new(),
        })
        .unwrap();
        schema[4] = 1;
        assert!(decode_schema(&schema).is_err());
        assert!(decode_schema(&schema[..SCHEMA_HEADER_LEN - 1]).is_err());
    }

    #[test]
    fn rejects_bad_magic() {
        let mut bytes = vec![0; HEADER_LEN];
        bytes[..4].copy_from_slice(b"NOPE");
        assert!(StreamReader::new(bytes.as_slice()).is_err());
    }
}
