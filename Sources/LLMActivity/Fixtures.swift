import Foundation

enum Fixtures {
    static let claude = #"""
    {
     "five_hour": {
      "utilization": 48.0,
      "resets_at": "2026-08-31T15:49:59.843069+00:00",
      "limit_dollars": null,
      "used_dollars": null,
      "remaining_dollars": null,
      "locked_reason": null
     },
     "seven_day": {
      "utilization": 7.0,
      "resets_at": "2026-09-07T07:59:59.843090+00:00",
      "limit_dollars": null,
      "used_dollars": null,
      "remaining_dollars": null,
      "locked_reason": null
     },
     "limits": [
      {
       "kind": "session",
       "group": "session",
       "percent": 48,
       "severity": "normal",
       "resets_at": "2026-08-31T15:49:59.843069+00:00",
       "scope": null,
       "is_active": true
      },
      {
       "kind": "weekly_all",
       "group": "weekly",
       "percent": 7,
       "severity": "normal",
       "resets_at": "2026-09-07T07:59:59.843090+00:00",
       "scope": null,
       "is_active": false
      },
      {
       "kind": "weekly_scoped",
       "group": "weekly",
       "percent": 7,
       "severity": "normal",
       "resets_at": "2026-09-07T07:59:59.843276+00:00",
       "scope": {
        "model": {
         "id": null,
         "display_name": "Fable"
        },
        "surface": null
       },
       "is_active": false
      }
     ]
    }
    """#
    static let codex = #"""
    {
     "user_id": "user-XXXX",
     "account_id": "00000000-0000-0000-0000-000000000000",
     "email": "user@example.com",
     "plan_type": "team",
     "rate_limit": {
      "allowed": true,
      "limit_reached": false,
      "primary_window": {
       "used_percent": 62,
       "limit_window_seconds": 18000,
       "reset_after_seconds": 18000,
       "reset_at": 1788199704
      },
      "secondary_window": {
       "used_percent": 38,
       "limit_window_seconds": 604800,
       "reset_after_seconds": 604800,
       "reset_at": 1788786504
      }
     },
     "code_review_rate_limit": null,
     "additional_rate_limits": null,
     "credits": {
      "has_credits": true,
      "unlimited": false,
      "overage_limit_reached": false,
      "balance": null,
      "approx_local_messages": null,
      "approx_cloud_messages": null
     },
     "spend_control": {
      "reached": true,
      "individual_limit": {
       "source": "workspace_spend_controls",
       "limit": "0",
       "used": "0.0",
       "remaining": "0.0",
       "used_percent": 100,
       "remaining_percent": 0,
       "reset_after_seconds": 39097,
       "reset_at": 1788220801
      }
     },
     "rate_limit_reached_type": null,
     "promo": null,
     "rate_limit_reset_credits": {
      "available_count": 0,
      "applicable_available_count": 0
     }
    }
    """#
    static let cursor = #"""
    {
     "billingCycleStart": "2026-08-22T08:37:25.000Z",
     "billingCycleEnd": "2026-09-22T08:37:25.000Z",
     "membershipType": "pro_plus",
     "individualUsage": {
      "plan": {
       "enabled": true,
       "used": 7000,
       "limit": 7000,
       "remaining": 0,
       "breakdown": {
        "included": 7000,
        "bonus": 19232,
        "total": 26232
       },
       "autoPercentUsed": 15.326666666666666,
       "apiPercentUsed": 71.27272727272728,
       "totalPercentUsed": 20.024427480916028
      },
      "onDemand": {
       "enabled": true,
       "used": 0,
       "limit": 5000,
       "remaining": 5000
      }
     }
    }
    """#
}

/// `--parsecheck`: the one runnable check. Drives the pure parsers with the
/// captured fixtures and asserts labels, percents (rounded) and reset dates.
func runParseCheck() -> Int32 {
    var pass = true
    func check(_ name: String, _ got: [UsageLimit], _ want: [(String, Int, String?)]) {
        let gotRows = got.map { ($0.label, Int($0.percent.rounded()), $0.resetsAt.map { ISO8601DateFormatter().string(from: $0) }) }
        let ok = gotRows.count == want.count && zip(gotRows, want).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 }
        pass = pass && ok
        print("  \(name.padding(toLength: 8, withPad: " ", startingAt: 0)) \(ok ? "PASS" : "FAIL")")
        if !ok { print("    got:  \(gotRows)"); print("    want: \(want)") }
    }
    print("=== Parser self-test ===")
    do {
        check("claude", try Provider.parseClaude(Data(Fixtures.claude.utf8)), [
            ("Weekly", 7, "2026-09-07T07:59:59Z"),
            ("Fable weekly", 7, "2026-09-07T07:59:59Z"),
            ("5h session", 48, "2026-08-31T15:49:59Z"),
        ])
        check("codex", try Provider.parseCodex(Data(Fixtures.codex.utf8)), [
            ("5h session", 62, "2026-08-31T18:08:24Z"),
            ("Weekly", 38, "2026-09-07T13:08:24Z"),
        ])
        check("cursor", try Provider.parseCursor(Data(Fixtures.cursor.utf8)), [
            ("API models", 71, "2026-09-22T08:37:25Z"),
            ("Auto", 15, "2026-09-22T08:37:25Z"),
        ])
        // Garbage must throw, not crash or return empty.
        do { _ = try Provider.parseClaude(Data("{}".utf8)); print("  empty    FAIL (no throw)"); pass = false }
        catch { print("  empty    PASS") }
    } catch {
        print("  threw: \(error)"); pass = false
    }
    print(pass ? "ALL PASS" : "FAIL")
    return pass ? 0 : 1
}
