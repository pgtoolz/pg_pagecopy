//! Index entries of the transfer manifest.
//!
//! Wire tags: `0` = btree (physical transfer), `1` = invalid
//! (definition only), `2` = brin (physical transfer), `3` = hash
//! (physical transfer). Existing manifests must decode identically; the
//! tags are part of the format and never renumbered.

use super::super::wire::{put_string, put_u32, Decoder, Result, WireError};
use super::brin::BrinMetadata;
use super::btree::BtreeMetadata;
use super::hash::HashMetadata;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum IndexTransfer {
    Btree(BtreeMetadata),
    /// Keep the index definition, but do not transfer or enable its contents.
    Invalid {
        definition: String,
        unique: bool,
    },
    Brin(BrinMetadata),
    Hash(HashMetadata),
}

/// Append one manifest index entry, including its wire tag.
pub fn encode_index(out: &mut Vec<u8>, index: &IndexTransfer) -> Result<()> {
    match index {
        IndexTransfer::Btree(metadata) => {
            out.push(0);
            put_string(out, &metadata.definition)?;
            put_string(out, &metadata.shape)?;
            put_u32(out, metadata.btree_version)?;
            out.push(u8::from(metadata.all_equal_image));
            out.push(u8::from(metadata.expected_all_equal_image));
        }
        IndexTransfer::Invalid { definition, unique } => {
            out.push(1);
            put_string(out, definition)?;
            out.push(u8::from(*unique));
        }
        IndexTransfer::Brin(metadata) => {
            out.push(2);
            put_string(out, &metadata.definition)?;
            put_string(out, &metadata.shape)?;
            put_u32(out, metadata.brin_version)?;
            put_u32(out, metadata.pages_per_range)?;
            put_u32(out, metadata.last_revmap_page)?;
        }
        IndexTransfer::Hash(metadata) => {
            out.push(3);
            put_string(out, &metadata.definition)?;
            put_string(out, &metadata.shape)?;
            put_u32(out, metadata.hash_version)?;
            put_u32(out, metadata.hash_proc)?;
        }
    }
    Ok(())
}

/// Read one manifest index entry written by [`encode_index`]; unknown wire
/// tags fail closed.
pub fn decode_index(decoder: &mut Decoder<'_>) -> Result<IndexTransfer> {
    Ok(match decoder.u8()? {
        0 => IndexTransfer::Btree(BtreeMetadata {
            definition: decoder.string()?,
            shape: decoder.string()?,
            btree_version: decoder.u32()?,
            all_equal_image: decoder.boolean()?,
            expected_all_equal_image: decoder.boolean()?,
        }),
        1 => IndexTransfer::Invalid {
            definition: decoder.string()?,
            unique: decoder.boolean()?,
        },
        2 => IndexTransfer::Brin(BrinMetadata {
            definition: decoder.string()?,
            shape: decoder.string()?,
            brin_version: decoder.u32()?,
            pages_per_range: decoder.u32()?,
            last_revmap_page: decoder.u32()?,
        }),
        3 => IndexTransfer::Hash(HashMetadata {
            definition: decoder.string()?,
            shape: decoder.string()?,
            hash_version: decoder.u32()?,
            hash_proc: decoder.u32()?,
        }),
        kind => return Err(WireError(format!("unknown index transfer kind {kind}"))),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn btree() -> BtreeMetadata {
        BtreeMetadata {
            definition: "btree (id)".into(),
            shape: "1|1|t|f|1|0|pg_catalog.int4_ops".into(),
            btree_version: 4,
            all_equal_image: true,
            expected_all_equal_image: true,
        }
    }

    fn brin() -> BrinMetadata {
        BrinMetadata {
            definition: "brin (id) WITH (pages_per_range=4)".into(),
            shape: "1|1|f|f|1|0|pg_catalog.int4_minmax_ops|".into(),
            brin_version: 1,
            pages_per_range: 4,
            last_revmap_page: 1,
        }
    }

    fn hash() -> HashMetadata {
        HashMetadata {
            definition: "hash (id)".into(),
            shape: "1|1|f|f|1|0|pg_catalog.int4_ops|".into(),
            hash_version: 4,
            hash_proc: 451,
        }
    }

    #[test]
    fn index_entries_round_trip_through_the_manifest_decoder() {
        let entries = [
            IndexTransfer::Btree(btree()),
            IndexTransfer::Invalid {
                definition: "hash (payload)".into(),
                unique: false,
            },
            IndexTransfer::Brin(brin()),
            IndexTransfer::Hash(hash()),
        ];
        for entry in entries {
            let mut out = Vec::new();
            encode_index(&mut out, &entry).unwrap();
            assert_eq!(decode_index(&mut Decoder::new(&out)).unwrap(), entry);
        }
    }

    #[test]
    fn wire_tags_stay_zero_one_two_three_for_btree_invalid_brin_and_hash() {
        // Existing manifests carry these tag bytes; renumbering would strand them.
        let mut out = Vec::new();
        encode_index(&mut out, &IndexTransfer::Btree(btree())).unwrap();
        assert_eq!(out[0], 0);
        let mut out = Vec::new();
        encode_index(
            &mut out,
            &IndexTransfer::Invalid {
                definition: "gin (payload)".into(),
                unique: true,
            },
        )
        .unwrap();
        assert_eq!(out[0], 1);
        let mut out = Vec::new();
        encode_index(&mut out, &IndexTransfer::Brin(brin())).unwrap();
        assert_eq!(out[0], 2);
        let mut out = Vec::new();
        encode_index(&mut out, &IndexTransfer::Hash(hash())).unwrap();
        assert_eq!(out[0], 3);
        assert!(
            decode_index(&mut Decoder::new(&[4])).is_err(),
            "unknown index transfer kind 4"
        );
    }

    #[test]
    fn index_entry_bytes_keep_their_exact_layout() {
        let mut out = Vec::new();
        encode_index(&mut out, &IndexTransfer::Btree(btree())).unwrap();
        let definition = b"btree (id)";
        let shape = b"1|1|t|f|1|0|pg_catalog.int4_ops";
        let mut expected = vec![0u8];
        expected.extend_from_slice(&(u32::try_from(definition.len()).unwrap()).to_be_bytes());
        expected.extend_from_slice(definition);
        expected.extend_from_slice(&(u32::try_from(shape.len()).unwrap()).to_be_bytes());
        expected.extend_from_slice(shape);
        expected.extend_from_slice(&4u32.to_be_bytes());
        expected.extend_from_slice(&[1, 1]);
        assert_eq!(out, expected);

        let mut out = Vec::new();
        encode_index(
            &mut out,
            &IndexTransfer::Invalid {
                definition: "hash (payload)".into(),
                unique: false,
            },
        )
        .unwrap();
        let definition = b"hash (payload)";
        let mut expected = vec![1u8];
        expected.extend_from_slice(&(u32::try_from(definition.len()).unwrap()).to_be_bytes());
        expected.extend_from_slice(definition);
        expected.extend_from_slice(&[0]);
        assert_eq!(out, expected);

        let mut out = Vec::new();
        encode_index(&mut out, &IndexTransfer::Brin(brin())).unwrap();
        let definition = b"brin (id) WITH (pages_per_range=4)";
        let shape = b"1|1|f|f|1|0|pg_catalog.int4_minmax_ops|";
        let mut expected = vec![2u8];
        expected.extend_from_slice(&(u32::try_from(definition.len()).unwrap()).to_be_bytes());
        expected.extend_from_slice(definition);
        expected.extend_from_slice(&(u32::try_from(shape.len()).unwrap()).to_be_bytes());
        expected.extend_from_slice(shape);
        expected.extend_from_slice(&1u32.to_be_bytes());
        expected.extend_from_slice(&4u32.to_be_bytes());
        expected.extend_from_slice(&1u32.to_be_bytes());
        assert_eq!(out, expected);

        let mut out = Vec::new();
        encode_index(&mut out, &IndexTransfer::Hash(hash())).unwrap();
        let definition = b"hash (id)";
        let shape = b"1|1|f|f|1|0|pg_catalog.int4_ops|";
        let mut expected = vec![3u8];
        expected.extend_from_slice(&(u32::try_from(definition.len()).unwrap()).to_be_bytes());
        expected.extend_from_slice(definition);
        expected.extend_from_slice(&(u32::try_from(shape.len()).unwrap()).to_be_bytes());
        expected.extend_from_slice(shape);
        expected.extend_from_slice(&4u32.to_be_bytes());
        expected.extend_from_slice(&451u32.to_be_bytes());
        assert_eq!(out, expected);
    }
}
