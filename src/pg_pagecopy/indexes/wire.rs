//! Index entries of the transfer manifest.
//!
//! Wire tags: `0` = btree (physical transfer), `1` = invalid
//! (definition only). Existing manifests must decode identically; the tags
//! are part of the format and never renumbered.

use super::super::wire::{put_string, put_u32, Decoder, Result, WireError};
use super::btree::BtreeMetadata;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum IndexTransfer {
    Btree(BtreeMetadata),
    /// Keep the index definition, but do not transfer or enable its contents.
    Invalid {
        definition: String,
        unique: bool,
    },
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

    #[test]
    fn index_entries_round_trip_through_the_manifest_decoder() {
        let entries = [
            IndexTransfer::Btree(btree()),
            IndexTransfer::Invalid {
                definition: "hash (payload)".into(),
                unique: false,
            },
        ];
        for entry in entries {
            let mut out = Vec::new();
            encode_index(&mut out, &entry).unwrap();
            assert_eq!(decode_index(&mut Decoder::new(&out)).unwrap(), entry);
        }
    }

    #[test]
    fn wire_tags_stay_zero_for_btree_and_one_for_invalid() {
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
        assert!(
            decode_index(&mut Decoder::new(&[2])).is_err(),
            "unknown index transfer kind 2"
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
    }
}
