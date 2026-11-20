import Foundation
@testable import HeedCore
import Testing

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Prague")!
    return calendar
}()

/// 13:00 in Prague.
private let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 13))!
private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
private let five = ClockTime(hour: 17, minute: 0)

private func agent(_ state: AgentState = .idle, turn: Double?, session: String? = "s-1") -> AgentTab {
    AgentTab(
        state: ObservedState(state), claudeSessionID: session, lastTurnAt: turn.map(ago),
        keepWarm: KeepWarm(since: ago(1))
    )
}

private func next(_ agent: AgentTab, at time: Date = now, until: ClockTime = five) -> KeepWarm.Decision {
    KeepWarm.next(agent, now: time, until: until, calendar: calendar)
}

struct KeepWarmTests {
    @Test func pingsFiftyFiveMinutesAfterTheCacheTime() {
        #expect(next(agent(turn: 20)) == .wait(until: ago(20).addingTimeInterval(55 * 60)))
        #expect(next(agent(turn: 55)) == .ping)
        #expect(next(agent(turn: 57.9)) == .ping)
    }

    @Test func neverOnceTheCacheMayBeGone() {
        // Turned on late, or the Mac slept through the window: off, never a ping on an expired cache.
        #expect(next(agent(turn: 58)) == .stop(.expired))
        #expect(next(agent(turn: 120)) == .stop(.expired))
    }

    @Test func aPingCountsAsTheCacheTime() {
        var warmed = agent(turn: 115)
        warmed.cacheWarmedAt = ago(56)
        #expect(next(warmed) == .ping)
        warmed.cacheWarmedAt = ago(1)
        #expect(next(warmed) == .wait(until: ago(1).addingTimeInterval(55 * 60)))
    }

    @Test func notWhileTheAgentWorksOrWaitsOnYou() {
        for state in [AgentState.working, .asking, .blocked, .limited] {
            #expect(next(agent(state, turn: 56)) == .waitForTurn)
        }
        for state in [AgentState.idle, .done, .exited] {
            #expect(next(agent(state, turn: 56)) == .ping)
        }
    }

    @Test func offWithoutASessionOrACache() {
        #expect(next(agent(turn: 10, session: nil)) == .stop(.noSession))
        #expect(next(agent(turn: nil)) == .stop(.noCache))
    }

    @Test func theCutOff() {
        let late = calendar.date(bySettingHour: 16, minute: 40, second: 0, of: now)!
        let cutoff = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: now)!
        var recent = agent(turn: nil)
        recent.lastTurnAt = late.addingTimeInterval(-10 * 60)
        // Due after the cut-off: wait for the cut-off, then off.
        #expect(next(recent, at: late) == .wait(until: cutoff))
        #expect(next(recent, at: cutoff) == .stop(.pastCutoff(five)))
        #expect(next(agent(turn: 56), at: now, until: ClockTime(hour: 12, minute: 30)) == .stop(.pastCutoff(
            ClockTime(hour: 12, minute: 30)
        )))
    }

    @Test func aHitReadsMostOfItsContextFromTheCache() {
        #expect(KeepWarm.isHit(read: 77394, written: 3238))
        #expect(!KeepWarm.isHit(read: 0, written: 52000))
        #expect(!KeepWarm.isHit(read: 1000, written: 1000))
        #expect(!KeepWarm.isHit(read: 0, written: 0))
    }

    @Test func theCutOffAsConfigWritesIt() {
        #expect(ClockTime(parsing: "17:00") == ClockTime(hour: 17, minute: 0))
        #expect(ClockTime(parsing: " 9:30 ") == ClockTime(hour: 9, minute: 30))
        for odd in ["17", "25:00", "17:60", "5pm", "17:0", ""] {
            #expect(ClockTime(parsing: odd) == nil)
        }
        #expect(ClockTime(hour: 9, minute: 5).text == "9:05")
        let config = """
        [keepwarm]
        until = "18:30"
        """
        #expect(ConfigLoader.decode(config).config?.work.keepWarmUntil == ClockTime(hour: 18, minute: 30))
        let wrong = ConfigLoader.decode("[keepwarm]\nuntil = \"later\"")
        #expect(wrong.problems.map(\.path) == ["keepwarm.until"])
        #expect(WorkSettings.default.keepWarmUntil == five)
    }

    @Test func theCommandAndItsMenuItem() {
        #expect(CommandAliases.resolve("keepwarm off") == CommandInvocation(name: "cache.keepWarm", arguments: ["off"]))
        let task = WorkTask(id: "t", title: "t")
        let item = { (warm: ContextMenus.KeepWarmItem) -> MenuItem? in
            ContextMenus.task(task, keepWarm: warm).lazy.compactMap { entry -> MenuItem? in
                if case let .item(item) = entry, item.title == "Keep cache warm" { item } else { nil }
            }.first
        }
        #expect(item(.init(on: true, cacheLive: true))?.checked == true)
        #expect(item(.init(on: false, cacheLive: true))?.enabled == true)
        // Nothing to keep: greyed. On, it can always be turned off.
        #expect(item(.init(on: false, cacheLive: false))?.enabled == false)
        #expect(item(.init(on: true, cacheLive: false))?.enabled == true)
        #expect(item(.init(on: false, cacheLive: true))?.typed == ":keepwarm")
        // Without an agent there is no item: the title, then Status.
        #expect(ContextMenus.task(task).count == 2)
    }
}

struct ClaudePingTests {
    @Test func theSessionsOwnModelFromItsLastReply() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","message":{"model":"claude-sonnet-5-5","content":[]}}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-5-5","content":[]}}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>","content":[]}}"#,
            #"{"type":"summary","summary":"x"}"#,
            "not json",
        ]
        #expect(ClaudePing.model(inSession: Data(lines.joined(separator: "\n").utf8)) == "claude-opus-5-5")
        #expect(ClaudePing.model(inSession: Data(lines[0].utf8)) == nil)
    }

    @Test func theReplyAsAResult() throws {
        let json = """
        {"type":"result","subtype":"success","is_error":false,"duration_ms":3300,"result":"pong",
         "total_cost_usd":0.0412,"usage":{"input_tokens":3,"cache_creation_input_tokens":3238,
         "cache_read_input_tokens":77394,"output_tokens":5}}
        """
        let result = try ClaudePing.result(fromJSON: Data(json.utf8))
        #expect(result == ClaudePing.Result(read: 77394, written: 3238, cost: 0.0412, seconds: 3.3))
        #expect(throws: ClaudePing.Failure.self) {
            try ClaudePing.result(fromJSON: Data(#"{"is_error":true,"result":"No conversation found"}"#.utf8))
        }
        #expect(throws: ClaudePing.Failure.self) { try ClaudePing.result(fromJSON: Data("pong".utf8)) }
    }

    @Test func runsHeadlessOnTheSessionsModelWithoutTouchingItsFile() {
        #expect(ClaudePing.arguments(sessionID: "s-1", model: "claude-opus-5-5") == [
            "-p", "--resume", "s-1", "--no-session-persistence", "--model", "claude-opus-5-5", "--output-format",
            "json", #"Reply with just "pong""#,
        ])
    }
}
