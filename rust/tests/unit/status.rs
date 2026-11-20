use super::*;

#[test]
fn parses_df_blocks_as_kib() {
    let parsed = parse_df_output("Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/root 1000 400 500 40% /mnt/my drive\n").unwrap();
    assert_eq!(parsed.total_bytes, 1_024_000);
    assert_eq!(parsed.used_bytes, 409_600);
    assert_eq!(parsed.available_bytes, 512_000);
    assert_eq!(parsed.mounted_at, "/mnt/my drive");
}

#[test]
fn rejects_malformed_df_and_dates() {
    assert!(parse_df_output(
        "Filesystem blocks used available capacity mounted\n/dev/root x 1 1 50% /\n"
    )
    .is_err());
    assert!(parse_timestamp("2023-02-29T00:00:00Z").is_none());
    assert!(parse_timestamp("2025-01-01T00:00:00+00:00").is_none());
}

#[test]
fn never_promotes_partial_publication() {
    let partial = ledger_report(
        ObservationState::Partial,
        None,
        None,
        None,
        Some("partial".to_owned()),
        None,
        None,
    );
    assert_eq!(partial.state, ObservationState::Partial);
    assert!(!partial.authoritative);
}
