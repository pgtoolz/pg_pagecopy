mod postgres;
mod steps;
mod world;

use cucumber::{writer::Stats as _, World as _};
use world::AttachWorld;

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
    let writer = AttachWorld::cucumber()
        .max_concurrent_scenarios(1)
        .fail_fast()
        .filter_run(features, move |_, _, scenario| {
            pair.as_ref().is_none_or(|(source, target)| {
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
    use super::matches_pair;

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
}
