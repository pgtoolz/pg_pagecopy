mod postgres;
mod steps;
mod world;

use cucumber::{writer::Stats as _, World as _};
use world::AttachWorld;

fn parse_tags(input: &str) -> Vec<String> {
    input
        .split([',', ' '])
        .map(str::trim)
        .filter(|tag| !tag.is_empty())
        .map(|tag| tag.trim_start_matches('@').to_owned())
        .collect()
}

/// A scenario runs when it matches both the optional `PG_PAGECOPY_TAGS`
/// selection and the optional version pair. `@cross` scenarios only make
/// sense with two different majors, so a pair-less (same-major) full run
/// skips them instead of executing and self-skipping at runtime.
fn matches_tags(
    feature_tags: &[String],
    scenario_tags: &[String],
    requested: &[String],
    pair_active: bool,
) -> bool {
    let has = |tag: &str| {
        feature_tags
            .iter()
            .chain(scenario_tags)
            .any(|candidate| candidate == tag)
    };
    if !pair_active && has("cross") {
        return false;
    }
    requested.is_empty() || requested.iter().any(|tag| has(tag))
}

fn matches_pair(first_step: &str, source: &str, target: &str) -> bool {
    let anchor = source == "13" && target == "18";
    let Some(pair) = first_step
        .strip_prefix("a fresh PostgreSQL ")
        .and_then(|step| step.split_once(" pair "))
        .map(|pair| pair.0)
    else {
        return anchor;
    };
    let Some((actual_source, actual_target)) = pair.split_once(" to ") else {
        return anchor;
    };
    (actual_source == source && actual_target == target)
        || (actual_source == target && actual_target == source)
        || (anchor && actual_source == "18" && actual_target == "18")
}

#[tokio::main]
async fn main() {
    let features = std::env::var("PG_PAGECOPY_FEATURES").unwrap_or_else(|_| "features".to_string());
    let pair = std::env::var("PG_PAGECOPY_SOURCE_MAJOR")
        .ok()
        .zip(std::env::var("PG_PAGECOPY_TARGET_MAJOR").ok());
    let tags = parse_tags(&std::env::var("PG_PAGECOPY_TAGS").unwrap_or_default());
    let writer = AttachWorld::cucumber()
        .max_concurrent_scenarios(1)
        .fail_fast()
        .fail_on_skipped()
        .filter_run(features, move |feature, _, scenario| {
            matches_tags(&feature.tags, &scenario.tags, &tags, pair.is_some())
                && pair.as_ref().is_none_or(|(source, target)| {
                    let first_step = scenario
                        .steps
                        .first()
                        .map_or("", |step| step.value.as_str());
                    matches_pair(first_step, source, target)
                })
        })
        .await;
    let scenarios = writer.scenarios_stats();
    let passed = scenarios.passed;
    let skipped = scenarios.skipped;
    let failed = scenarios.failed;
    println!("BDD summary: {passed} passed, {skipped} skipped, {failed} failed");
    if passed + skipped + failed == 0 {
        eprintln!("no BDD scenarios matched; check PG_PAGECOPY_FEATURES");
        std::process::exit(1);
    }
    if writer.execution_has_failed() {
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::{matches_pair, matches_tags, parse_tags};

    fn fresh(source: &str, target: &str) -> String {
        format!("a fresh PostgreSQL {source} to {target} pair with checksums \"enabled\"")
    }

    #[test]
    fn pair_filter_uses_the_expanded_example_step() {
        assert!(matches_pair(&fresh("13", "18"), "13", "18"));
        assert!(matches_pair(&fresh("18", "13"), "13", "18"));
        assert!(!matches_pair(&fresh("16", "17"), "13", "18"));
        assert!(matches_pair(&fresh("16", "17"), "16", "17"));
        assert!(!matches_pair(
            "a fresh PostgreSQL 16 to 17 pair with source checksums \"disabled\" and target checksums \"enabled\"",
            "13",
            "18"
        ));
        assert!(matches_pair(&fresh("14", "13"), "13", "14"));
        assert!(matches_pair(&fresh("18", "18"), "13", "18"));
        assert!(!matches_pair(&fresh("18", "18"), "14", "15"));
        assert!(matches_pair("a future scenario without a pair", "13", "18"));
    }

    #[test]
    fn tag_selection_includes_only_requested_tags() {
        let feature = vec!["hash".to_owned()];
        let scenario = vec!["cross".to_owned()];
        assert!(matches_tags(&feature, &scenario, &[], true));
        assert!(matches_tags(&feature, &scenario, &["hash".to_owned()], true));
        assert!(matches_tags(
            &feature,
            &scenario,
            &["cross".to_owned()],
            true
        ));
        assert!(!matches_tags(
            &feature,
            &scenario,
            &["brin".to_owned()],
            true
        ));
    }

    #[test]
    fn cross_scenarios_need_an_active_pair() {
        let feature = vec!["hash".to_owned()];
        assert!(!matches_tags(
            &feature,
            &["cross".to_owned()],
            &[],
            false
        ));
        assert!(!matches_tags(
            &feature,
            &["cross".to_owned()],
            &["hash".to_owned()],
            false
        ));
        assert!(matches_tags(
            &feature,
            &["cross".to_owned()],
            &["cross".to_owned()],
            true
        ));
        assert!(matches_tags(
            &feature,
            &[],
            &["hash".to_owned()],
            false
        ));
    }

    #[test]
    fn tag_parsing_strips_markers_and_separators() {
        assert_eq!(
            parse_tags("@hash, brin @cross"),
            vec!["hash".to_owned(), "brin".to_owned(), "cross".to_owned()]
        );
        assert_eq!(parse_tags(" , "), Vec::<String>::new());
    }
}
