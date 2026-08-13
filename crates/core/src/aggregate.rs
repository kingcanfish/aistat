use crate::model::Status;

/// Aggregates a set of statuses into the single "worst" status according to the
/// configured priority ordering (first = most severe). Returns `Unknown` for an
/// empty input.
pub fn aggregate(statuses: impl IntoIterator<Item = Status>, priority: &[Status]) -> Status {
    statuses.into_iter().fold(Status::Unknown, |acc, s| {
        if s.severity(priority) < acc.severity(priority) {
            s
        } else {
            acc
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Status::*;

    #[test]
    fn aggregate_picks_most_severe() {
        let p = Status::DEFAULT_PRIORITY.to_vec();
        assert_eq!(aggregate([Operational, Degraded], &p), Degraded);
        assert_eq!(aggregate([Operational, FullOutage, Degraded], &p), FullOutage);
        assert_eq!(aggregate([Operational, Operational], &p), Operational);
    }

    #[test]
    fn aggregate_empty_is_unknown() {
        let p = Status::DEFAULT_PRIORITY.to_vec();
        assert_eq!(aggregate([], &p), Unknown);
    }

    #[test]
    fn aggregate_maintenance_beats_degraded() {
        let p = Status::DEFAULT_PRIORITY.to_vec();
        assert_eq!(aggregate([Degraded, Maintenance], &p), Maintenance);
    }

    #[test]
    fn unknown_ranks_last() {
        let p = Status::DEFAULT_PRIORITY.to_vec();
        assert_eq!(aggregate([Operational, Unknown], &p), Operational);
    }
}
