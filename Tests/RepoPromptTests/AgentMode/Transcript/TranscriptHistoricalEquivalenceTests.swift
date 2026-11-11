import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class TranscriptHistoricalEquivalenceTests: XCTestCase {
    func testHistoricalOutputsMatchA260C6703() throws {
        func item(_ n: Int, _ k: AgentChatItemKind, _ text: String, _ tool: String? = nil, _ inv: UUID? = nil) -> AgentChatItem {
            AgentChatItem(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n + 1))!, timestamp: Date(timeIntervalSince1970: Double(n)), kind: k, text: text, toolName: tool, toolInvocationID: inv, toolArgsJSON: tool == nil ? nil : "{}", toolResultJSON: k == .toolResult ? "{}" : nil, sequenceIndex: n)
        }
        var items = [item(0, .user, "question"), item(1, .assistant, "late"), item(2, .assistant, "answer")]
        for n in 0 ..< 10 {
            let id = UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", n + 1))!
            items.append(item(3 + n * 2, .toolCall, "", "Bash", id))
            items.append(item(4 + n * 2, .toolResult, "", "Bash", id))
        }
        let t = AgentTranscriptIO.importLegacyItems(items)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let outputs = try [String(decoding: e.encode(AgentTranscriptIO.buildHandoffTranscriptItems(from: t, upToRowID: XCTUnwrap(items.last?.id))), as: UTF8.self), AgentTranscriptIO.buildSpartanLogXML(from: t), AgentTranscriptIO.buildForkTranscriptXML(from: t)]
        let combined = outputs.joined(separator: "\n---OUTPUT---\n")
        let regex = try NSRegularExpression(pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
        let ns = combined as NSString
        let matches = regex.matches(in: combined, range: NSRange(location: 0, length: ns.length))
        var map: [String: String] = [:]
        for m in matches {
            let id = ns.substring(with: m.range)
            if map[id] == nil {
                map[id] = "UUID_\(map.count)"
            }
        }
        // Fixed fixture identities must not be silently re-keyed by normalization.
        XCTAssertEqual(map[items[0].id.uuidString], "UUID_0")
        XCTAssertEqual(map[items[1].id.uuidString], "UUID_1")
        for n in 2 ..< 10 {
            let invocation = UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", n + 1))!
            XCTAssertEqual(map[invocation.uuidString], "UUID_\(4 + (n - 2) * 2)")
        }
        var normalized = combined
        for m in matches.reversed() {
            let id = ns.substring(with: m.range)
            try normalized.replaceSubrange(XCTUnwrap(Range(m.range, in: normalized)), with: XCTUnwrap(map[id]))
        }
        let presentation = AgentTranscriptProjectionBuilder.buildWithCaches(from: t, turnCaches: [:], replyPresentation: true).projection
        XCTAssertTrue(presentation.workingBlocks.contains { $0.kind == .standaloneAssistant && $0.activityIDs.contains(items[2].id) })
        XCTAssertTrue(presentation.workingBlocks.contains { $0.kind == .groupedHistory })
        let baseline = "W3siYXR0YWNobWVudHMiOltdLCJpZCI6IlVVSURfMCIsImlzTG9jYWxDb250cm9sUGxhbmVFY2hvIjpmYWxzZSwiaXNTdHJlYW1pbmciOmZhbHNlLCJraW5kIjoidXNlciIsInNlcXVlbmNlSW5kZXgiOjAsInRhZ2dlZEZpbGVBdHRhY2htZW50cyI6W10sInRleHQiOiJxdWVzdGlvbiIsInRpbWVzdGFtcCI6LTk3ODMwNzIwMH0seyJhdHRhY2htZW50cyI6W10sImlkIjoiVVVJRF8xIiwiaXNMb2NhbENvbnRyb2xQbGFuZUVjaG8iOmZhbHNlLCJpc1N0cmVhbWluZyI6ZmFsc2UsImtpbmQiOiJhc3Npc3RhbnQiLCJzZXF1ZW5jZUluZGV4IjoxLCJ0YWdnZWRGaWxlQXR0YWNobWVudHMiOltdLCJ0ZXh0IjoibGF0ZSIsInRpbWVzdGFtcCI6LTk3ODMwNzE5OX0seyJhdHRhY2htZW50cyI6W10sImlkIjoiVVVJRF8yIiwiaXNMb2NhbENvbnRyb2xQbGFuZUVjaG8iOmZhbHNlLCJpc1N0cmVhbWluZyI6ZmFsc2UsImtpbmQiOiJzeXN0ZW0iLCJzZXF1ZW5jZUluZGV4IjoyLCJ0YWdnZWRGaWxlQXR0YWNobWVudHMiOltdLCJ0ZXh0IjoiUmFuIGNvbW1hbmRzIOKAoiBhbnN3ZXIg4oCiIGJhc2ggw5cyIiwidGltZXN0YW1wIjotOTc4MzA3MTk4fSx7ImF0dGFjaG1lbnRzIjpbXSwiaWQiOiJVVUlEXzMiLCJpc0xvY2FsQ29udHJvbFBsYW5lRWNobyI6ZmFsc2UsImlzU3RyZWFtaW5nIjpmYWxzZSwia2luZCI6InRvb2xSZXN1bHQiLCJzZXF1ZW5jZUluZGV4IjozLCJ0YWdnZWRGaWxlQXR0YWNobWVudHMiOltdLCJ0ZXh0Ijoie1wic3RhdHVzXCI6XCJ1bmtub3duXCIsXCJzdW1tYXJ5X29ubHlcIjp0cnVlLFwidHlwZVwiOlwiY29tbWFuZEV4ZWN1dGlvblwifSIsInRpbWVzdGFtcCI6LTk3ODMwNzE5MiwidG9vbEFyZ3NKU09OIjoie30iLCJ0b29sSW52b2NhdGlvbklEIjoiVVVJRF80IiwidG9vbE5hbWUiOiJiYXNoIiwidG9vbFJlc3VsdEpTT04iOiJ7XCJzdGF0dXNcIjpcInVua25vd25cIixcInN1bW1hcnlfb25seVwiOnRydWUsXCJ0eXBlXCI6XCJjb21tYW5kRXhlY3V0aW9uXCJ9In0seyJhdHRhY2htZW50cyI6W10sImlkIjoiVVVJRF81IiwiaXNMb2NhbENvbnRyb2xQbGFuZUVjaG8iOmZhbHNlLCJpc1N0cmVhbWluZyI6ZmFsc2UsImtpbmQiOiJ0b29sUmVzdWx0Iiwic2VxdWVuY2VJbmRleCI6NCwidGFnZ2VkRmlsZUF0dGFjaG1lbnRzIjpbXSwidGV4dCI6IntcInN0YXR1c1wiOlwidW5rbm93blwiLFwic3VtbWFyeV9vbmx5XCI6dHJ1ZSxcInR5cGVcIjpcImNvbW1hbmRFeGVjdXRpb25cIn0iLCJ0aW1lc3RhbXAiOi05NzgzMDcxOTAsInRvb2xBcmdzSlNPTiI6Int9IiwidG9vbEludm9jYXRpb25JRCI6IlVVSURfNiIsInRvb2xOYW1lIjoiYmFzaCIsInRvb2xSZXN1bHRKU09OIjoie1wic3RhdHVzXCI6XCJ1bmtub3duXCIsXCJzdW1tYXJ5X29ubHlcIjp0cnVlLFwidHlwZVwiOlwiY29tbWFuZEV4ZWN1dGlvblwifSJ9LHsiYXR0YWNobWVudHMiOltdLCJpZCI6IlVVSURfNyIsImlzTG9jYWxDb250cm9sUGxhbmVFY2hvIjpmYWxzZSwiaXNTdHJlYW1pbmciOmZhbHNlLCJraW5kIjoidG9vbFJlc3VsdCIsInNlcXVlbmNlSW5kZXgiOjUsInRhZ2dlZEZpbGVBdHRhY2htZW50cyI6W10sInRleHQiOiJ7XCJzdGF0dXNcIjpcInVua25vd25cIixcInN1bW1hcnlfb25seVwiOnRydWUsXCJ0eXBlXCI6XCJjb21tYW5kRXhlY3V0aW9uXCJ9IiwidGltZXN0YW1wIjotOTc4MzA3MTg4LCJ0b29sQXJnc0pTT04iOiJ7fSIsInRvb2xJbnZvY2F0aW9uSUQiOiJVVUlEXzgiLCJ0b29sTmFtZSI6ImJhc2giLCJ0b29sUmVzdWx0SlNPTiI6IntcInN0YXR1c1wiOlwidW5rbm93blwiLFwic3VtbWFyeV9vbmx5XCI6dHJ1ZSxcInR5cGVcIjpcImNvbW1hbmRFeGVjdXRpb25cIn0ifSx7ImF0dGFjaG1lbnRzIjpbXSwiaWQiOiJVVUlEXzkiLCJpc0xvY2FsQ29udHJvbFBsYW5lRWNobyI6ZmFsc2UsImlzU3RyZWFtaW5nIjpmYWxzZSwia2luZCI6InRvb2xSZXN1bHQiLCJzZXF1ZW5jZUluZGV4Ijo2LCJ0YWdnZWRGaWxlQXR0YWNobWVudHMiOltdLCJ0ZXh0Ijoie1wic3RhdHVzXCI6XCJ1bmtub3duXCIsXCJzdW1tYXJ5X29ubHlcIjp0cnVlLFwidHlwZVwiOlwiY29tbWFuZEV4ZWN1dGlvblwifSIsInRpbWVzdGFtcCI6LTk3ODMwNzE4NiwidG9vbEFyZ3NKU09OIjoie30iLCJ0b29sSW52b2NhdGlvbklEIjoiVVVJRF8xMCIsInRvb2xOYW1lIjoiYmFzaCIsInRvb2xSZXN1bHRKU09OIjoie1wic3RhdHVzXCI6XCJ1bmtub3duXCIsXCJzdW1tYXJ5X29ubHlcIjp0cnVlLFwidHlwZVwiOlwiY29tbWFuZEV4ZWN1dGlvblwifSJ9LHsiYXR0YWNobWVudHMiOltdLCJpZCI6IlVVSURfMTEiLCJpc0xvY2FsQ29udHJvbFBsYW5lRWNobyI6ZmFsc2UsImlzU3RyZWFtaW5nIjpmYWxzZSwia2luZCI6InRvb2xSZXN1bHQiLCJzZXF1ZW5jZUluZGV4Ijo3LCJ0YWdnZWRGaWxlQXR0YWNobWVudHMiOltdLCJ0ZXh0Ijoie1wic3RhdHVzXCI6XCJ1bmtub3duXCIsXCJzdW1tYXJ5X29ubHlcIjp0cnVlLFwidHlwZVwiOlwiY29tbWFuZEV4ZWN1dGlvblwifSIsInRpbWVzdGFtcCI6LTk3ODMwNzE4NCwidG9vbEFyZ3NKU09OIjoie30iLCJ0b29sSW52b2NhdGlvbklEIjoiVVVJRF8xMiIsInRvb2xOYW1lIjoiYmFzaCIsInRvb2xSZXN1bHRKU09OIjoie1wic3RhdHVzXCI6XCJ1bmtub3duXCIsXCJzdW1tYXJ5X29ubHlcIjp0cnVlLFwidHlwZVwiOlwiY29tbWFuZEV4ZWN1dGlvblwifSJ9LHsiYXR0YWNobWVudHMiOltdLCJpZCI6IlVVSURfMTMiLCJpc0xvY2FsQ29udHJvbFBsYW5lRWNobyI6ZmFsc2UsImlzU3RyZWFtaW5nIjpmYWxzZSwia2luZCI6InRvb2xSZXN1bHQiLCJzZXF1ZW5jZUluZGV4Ijo4LCJ0YWdnZWRGaWxlQXR0YWNobWVudHMiOltdLCJ0ZXh0Ijoie1wic3RhdHVzXCI6XCJ1bmtub3duXCIsXCJzdW1tYXJ5X29ubHlcIjp0cnVlLFwidHlwZVwiOlwiY29tbWFuZEV4ZWN1dGlvblwifSIsInRpbWVzdGFtcCI6LTk3ODMwNzE4MiwidG9vbEFyZ3NKU09OIjoie30iLCJ0b29sSW52b2NhdGlvbklEIjoiVVVJRF8xNCIsInRvb2xOYW1lIjoiYmFzaCIsInRvb2xSZXN1bHRKU09OIjoie1wic3RhdHVzXCI6XCJ1bmtub3duXCIsXCJzdW1tYXJ5X29ubHlcIjp0cnVlLFwidHlwZVwiOlwiY29tbWFuZEV4ZWN1dGlvblwifSJ9LHsiYXR0YWNobWVudHMiOltdLCJpZCI6IlVVSURfMTUiLCJpc0xvY2FsQ29udHJvbFBsYW5lRWNobyI6ZmFsc2UsImlzU3RyZWFtaW5nIjpmYWxzZSwia2luZCI6InRvb2xSZXN1bHQiLCJzZXF1ZW5jZUluZGV4Ijo5LCJ0YWdnZWRGaWxlQXR0YWNobWVudHMiOltdLCJ0ZXh0Ijoie1wic3RhdHVzXCI6XCJ1bmtub3duXCIsXCJzdW1tYXJ5X29ubHlcIjp0cnVlLFwidHlwZVwiOlwiY29tbWFuZEV4ZWN1dGlvblwifSIsInRpbWVzdGFtcCI6LTk3ODMwNzE4MCwidG9vbEFyZ3NKU09OIjoie30iLCJ0b29sSW52b2NhdGlvbklEIjoiVVVJRF8xNiIsInRvb2xOYW1lIjoiYmFzaCIsInRvb2xSZXN1bHRKU09OIjoie1wic3RhdHVzXCI6XCJ1bmtub3duXCIsXCJzdW1tYXJ5X29ubHlcIjp0cnVlLFwidHlwZVwiOlwiY29tbWFuZEV4ZWN1dGlvblwifSJ9LHsiYXR0YWNobWVudHMiOltdLCJpZCI6IlVVSURfMTciLCJpc0xvY2FsQ29udHJvbFBsYW5lRWNobyI6ZmFsc2UsImlzU3RyZWFtaW5nIjpmYWxzZSwia2luZCI6InRvb2xSZXN1bHQiLCJzZXF1ZW5jZUluZGV4IjoxMCwidGFnZ2VkRmlsZUF0dGFjaG1lbnRzIjpbXSwidGV4dCI6IntcInN0YXR1c1wiOlwidW5rbm93blwiLFwic3VtbWFyeV9vbmx5XCI6dHJ1ZSxcInR5cGVcIjpcImNvbW1hbmRFeGVjdXRpb25cIn0iLCJ0aW1lc3RhbXAiOi05NzgzMDcxNzgsInRvb2xBcmdzSlNPTiI6Int9IiwidG9vbEludm9jYXRpb25JRCI6IlVVSURfMTgiLCJ0b29sTmFtZSI6ImJhc2giLCJ0b29sUmVzdWx0SlNPTiI6IntcInN0YXR1c1wiOlwidW5rbm93blwiLFwic3VtbWFyeV9vbmx5XCI6dHJ1ZSxcInR5cGVcIjpcImNvbW1hbmRFeGVjdXRpb25cIn0ifV0KLS0tT1VUUFVULS0tCjx0cmFuc2NyaXB0Pgo8dXNlcj5xdWVzdGlvbjwvdXNlcj4KPGFzc2lzdGFudD5sYXRlPC9hc3Npc3RhbnQ+CjxzeXN0ZW0+UmFuIGNvbW1hbmRzIOKAoiBhbnN3ZXIg4oCiIGJhc2ggw5cyPC9zeXN0ZW0+Cjx0b29sX2NhbGwgbmFtZT0iYmFzaCI+e308L3Rvb2xfY2FsbD4KPHRvb2xfY2FsbCBuYW1lPSJiYXNoIj57fTwvdG9vbF9jYWxsPgo8dG9vbF9jYWxsIG5hbWU9ImJhc2giPnt9PC90b29sX2NhbGw+Cjx0b29sX2NhbGwgbmFtZT0iYmFzaCI+e308L3Rvb2xfY2FsbD4KPHRvb2xfY2FsbCBuYW1lPSJiYXNoIj57fTwvdG9vbF9jYWxsPgo8dG9vbF9jYWxsIG5hbWU9ImJhc2giPnt9PC90b29sX2NhbGw+Cjx0b29sX2NhbGwgbmFtZT0iYmFzaCI+e308L3Rvb2xfY2FsbD4KPHRvb2xfY2FsbCBuYW1lPSJiYXNoIj57fTwvdG9vbF9jYWxsPgo8L3RyYW5zY3JpcHQ+Ci0tLU9VVFBVVC0tLQo8dHJhbnNjcmlwdD4KPHVzZXI+cXVlc3Rpb248L3VzZXI+Cjxhc3Npc3RhbnQ+bGF0ZTwvYXNzaXN0YW50Pgo8c3lzdGVtPlJhbiBjb21tYW5kcyDigKIgYW5zd2VyIOKAoiBiYXNoIMOXMjwvc3lzdGVtPgo8dG9vbF9jYWxsIG5hbWU9ImJhc2giPnt9PC90b29sX2NhbGw+Cjx0b29sX2NhbGwgbmFtZT0iYmFzaCI+e308L3Rvb2xfY2FsbD4KPHRvb2xfY2FsbCBuYW1lPSJiYXNoIj57fTwvdG9vbF9jYWxsPgo8dG9vbF9jYWxsIG5hbWU9ImJhc2giPnt9PC90b29sX2NhbGw+Cjx0b29sX2NhbGwgbmFtZT0iYmFzaCI+e308L3Rvb2xfY2FsbD4KPHRvb2xfY2FsbCBuYW1lPSJiYXNoIj57fTwvdG9vbF9jYWxsPgo8dG9vbF9jYWxsIG5hbWU9ImJhc2giPnt9PC90b29sX2NhbGw+Cjx0b29sX2NhbGwgbmFtZT0iYmFzaCI+e308L3Rvb2xfY2FsbD4KPC90cmFuc2NyaXB0Pg=="
        XCTAssertEqual(Data(normalized.utf8).base64EncodedString(), baseline)
    }
}
