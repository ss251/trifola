import Foundation
import Testing
@testable import TrifolaKit

@Suite("MCP readiness metadata")
struct MCPReadinessTests {
    @Test("initialize identifies trifola and discloses the local index")
    func initializeMetadata() throws {
        let server = MCPIntrospectionServer(sessions: { [] }, quota: {
            .unavailable("not needed")
        })
        let line = try #require(server.handleLine(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        let info = try #require(result["serverInfo"] as? [String: Any])
        let instructions = try #require(result["instructions"] as? String)

        #expect(info["name"] as? String == "trifola")
        #expect(info["title"] as? String == "trifola — session self-introspection")
        #expect(instructions.contains("never mutates ~/.claude or external systems"))
        #expect(instructions.contains("app-local session index"))
    }
}
