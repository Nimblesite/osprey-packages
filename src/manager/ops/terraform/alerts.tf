# Implements [PACKAGE-HOSTED-CONTROL] and [PLAN-ROLLOUT-EDGE] Launch Triage #7:
# day-one operational gate alerts on Cloud Run (5xx < 1% over 15 min, p95 latency < 1 s).
resource "google_monitoring_alert_policy" "api_5xx_rate" {
  display_name = "${local.name}: API 5xx rate >= 1% (15m)"
  combiner     = "OR"
  depends_on   = [google_project_service.required]

  conditions {
    display_name = "Cloud Run 5xx ratio >= 1% over 15 minutes"
    condition_threshold {
      filter             = "resource.type = \"cloud_run_revision\" AND resource.labels.service_name = \"${google_cloud_run_v2_service.api.name}\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.labels.response_code_class = \"5xx\""
      denominator_filter = "resource.type = \"cloud_run_revision\" AND resource.labels.service_name = \"${google_cloud_run_v2_service.api.name}\" AND metric.type = \"run.googleapis.com/request_count\""
      comparison         = "COMPARISON_GT"
      threshold_value    = 0.01
      duration           = "900s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
      }

      denominator_aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }
}

resource "google_monitoring_alert_policy" "api_latency_p95" {
  display_name = "${local.name}: API latency p95 > 1s (15m)"
  combiner     = "OR"
  depends_on   = [google_project_service.required]

  conditions {
    display_name = "Cloud Run request latency p95 > 1000 ms over 15 minutes"
    condition_threshold {
      filter          = "resource.type = \"cloud_run_revision\" AND resource.labels.service_name = \"${google_cloud_run_v2_service.api.name}\" AND metric.type = \"run.googleapis.com/request_latencies\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1000
      duration        = "900s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_PERCENTILE_95"
        cross_series_reducer = "REDUCE_MAX"
      }
    }
  }
}
