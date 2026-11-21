import CoreFoundation
import Darwin
import Foundation

private typealias Object = [String: Any]

private struct RPCError: Error {
  let code: Int
  let message: String
  init(_ code: Int, _ message: String) {
    self.code = code
    self.message = message
  }
}

@main
private struct FingerMCP {
  private static let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
  private var version: String?

  static func main() {
    var server = FingerMCP()
    var line = Data()
    var input = [UInt8](repeating: 0, count: 64 * 1024)
    var oversized = false
    while true {
      let count = input.withUnsafeMutableBytes {
        Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count)
      }
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else {
        if !line.isEmpty || oversized { server.finish(line, oversized: oversized) }
        return
      }
      let chunk = input[..<count]
      var start = chunk.startIndex
      while start < chunk.endIndex {
        let end = chunk[start...].firstIndex(of: 10) ?? chunk.endIndex
        if !oversized && line.count + end - start <= AgentWire.maximumSize {
          line.append(contentsOf: chunk[start..<end])
        } else {
          oversized = true
        }
        if end == chunk.endIndex { break }
        server.finish(line, oversized: oversized)
        line.removeAll(keepingCapacity: false)
        oversized = false
        start = end + 1
      }
    }
  }

  private mutating func finish(_ data: Data, oversized: Bool) {
    let reply: Object?
    if oversized {
      reply = [
        "jsonrpc": "2.0", "id": NSNull(),
        "error": ["code": -32600, "message": "Message exceeds size limit."],
      ]
    } else {
      reply = data.isEmpty ? nil : respond(to: data)
    }
    if let reply, var bytes = try? JSONSerialization.data(withJSONObject: reply) {
      bytes.append(10)
      FileHandle.standardOutput.write(bytes)
    }
  }

  private mutating func respond(to data: Data) -> Object? {
    var id: Any = NSNull()
    do {
      let decoded: Any
      do {
        decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
      } catch { throw RPCError(-32700, "Parse error") }
      guard let message = decoded as? Object, message["jsonrpc"] as? String == "2.0",
        let method = message["method"] as? String
      else {
        throw RPCError(-32600, "Invalid JSON-RPC request")
      }
      // Notifications never receive replies.
      guard let requestID = message["id"] else { return nil }
      guard requestID is String || Self.integer(requestID) != nil else {
        throw RPCError(-32600, "Invalid request ID")
      }
      id = requestID
      let params = message["params"] as? Object ?? [:]
      let result: Object
      switch method {
      case "initialize":
        guard let preferred = params["protocolVersion"] as? String else {
          throw RPCError(-32602, "Missing protocolVersion")
        }
        let selected = Self.versions.contains(preferred) ? preferred : Self.versions[0]
        version = selected
        result = [
          "protocolVersion": selected, "capabilities": ["tools": Object()],
          "serverInfo": ["name": "finger", "version": "1.0.0"],
          "instructions":
            "Use the selection tool to read highlighted items in the running Finger window. Use its selection_id and item IDs to show a named collection there.",
        ]
      case "ping":
        result = [:]
      case "tools/list", "tools/call":
        guard version != nil else { throw RPCError(-32002, "Initialize the MCP session first.") }
        result = method == "tools/list" ? ["tools": Self.definitions] : try call(params)
      default:
        throw RPCError(-32601, "Unknown method")
      }
      return ["jsonrpc": "2.0", "id": id, "result": result]
    } catch let error as RPCError {
      return ["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]]
    } catch {
      return [
        "jsonrpc": "2.0", "id": id,
        "error": ["code": -32603, "message": error.localizedDescription],
      ]
    }
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue == Double(number.intValue)
    else { return nil }
    return number.intValue
  }

  private func call(_ params: Object) throws -> Object {
    guard let tool = params["name"] as? String else { throw RPCError(-32602, "Missing tool name") }
    guard params["arguments"] == nil || params["arguments"] is Object else {
      throw RPCError(-32602, "Tool arguments must be an object.")
    }
    let args = params["arguments"] as? Object ?? [:]
    let request: AgentRequest
    switch tool {
    case "get_selection":
      guard Set(args.keys).isSubset(of: ["selection_id", "offset", "limit"]),
        args["selection_id"] == nil || args["selection_id"] is String,
        args["offset"] == nil || Self.integer(args["offset"]) != nil,
        args["limit"] == nil || Self.integer(args["limit"]) != nil
      else {
        throw RPCError(-32602, "Use selection_id (string), offset (integer), or limit (integer).")
      }
      request = AgentRequest(
        action: "selection", selectionID: args["selection_id"] as? String,
        offset: Self.integer(args["offset"]), limit: Self.integer(args["limit"]))
    case "show_collection":
      guard Set(args.keys).isSubset(of: ["selection_id", "name", "item_ids"]),
        let id = args["selection_id"] as? String, let name = args["name"] as? String
      else {
        throw RPCError(-32602, "Pass selection_id and name as strings, and optionally item_ids.")
      }
      var ids: [Int]?
      if let list = args["item_ids"] {
        guard let values = list as? [Any] else {
          throw RPCError(-32602, "item_ids must be an array.")
        }
        ids = try values.map {
          guard let id = Self.integer($0) else {
            throw RPCError(-32602, "item_ids must be integers.")
          }
          return id
        }
      }
      request = AgentRequest(action: "collection", selectionID: id, name: name, itemIDs: ids)
    default:
      throw RPCError(-32602, "Unknown Finger tool.")
    }
    do {
      let reply = try AgentWire.call(request)
      if let error = reply.error { throw FingerAgentError(error) }
      var payload: Object = ["total": reply.total ?? 0]
      if let id = reply.selectionID {
        payload["selection_id"] = id
        payload["folder"] = reply.folder as Any? ?? NSNull()
        payload["collection"] = reply.collection as Any? ?? NSNull()
        payload["items"] = (reply.items ?? []).map {
          ["id": $0.id, "name": $0.name, "path": $0.path] as Object
        }
        payload["next_offset"] = reply.nextOffset as Any? ?? NSNull()
      } else {
        payload["name"] = reply.name
      }
      let encoded = try JSONSerialization.data(
        withJSONObject: payload, options: [.withoutEscapingSlashes])
      var result: Object = [
        "content": [["type": "text", "text": String(decoding: encoded, as: UTF8.self)]]
      ]
      if version == "2025-11-25" || version == "2025-06-18" {
        result["structuredContent"] = payload
      }
      return result
    } catch {
      return ["isError": true, "content": [["type": "text", "text": error.localizedDescription]]]
    }
  }

  private static let definitions: [Object] = [
    [
      "name": "get_selection", "title": "Read Finger selection",
      "description":
        "Read selected filenames and paths from the running Finger window. Start with empty arguments for a new snapshot. To page through it, pass its selection_id and next_offset as offset.",
      "inputSchema": [
        "type": "object", "additionalProperties": false,
        "properties": [
          "selection_id": [
            "type": "string", "description": "Selection snapshot returned by an earlier read.",
          ],
          "offset": ["type": "integer", "minimum": 0],
          "limit": ["type": "integer", "minimum": 1, "maximum": 150, "default": 60],
        ],
      ] as Object,
      "annotations": ["readOnlyHint": true, "openWorldHint": false],
    ],
    [
      "name": "show_collection", "title": "Show named collection in Finger",
      "description":
        "Open a named virtual collection in the same Finger window. Omit item_ids to include the entire captured selection, or supply selected IDs in display order. Files stay in their original locations.",
      "inputSchema": [
        "type": "object", "additionalProperties": false, "required": ["name", "selection_id"],
        "properties": [
          "selection_id": ["type": "string"],
          "name": ["type": "string", "minLength": 1, "maxLength": 100],
          "item_ids": [
            "type": "array", "minItems": 1, "uniqueItems": true,
            "items": ["type": "integer", "minimum": 0],
          ],
        ],
      ] as Object,
      "annotations": ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false],
    ],
  ]
}
