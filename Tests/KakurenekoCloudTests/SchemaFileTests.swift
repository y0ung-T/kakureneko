import CloudKit
import Foundation
import Testing
@testable import KakurenekoCloud

/// `Xcode/CloudKit/schema.ckdb` (what cktool imports and the CloudKit console deploys) must declare exactly the fields
/// `CloudRecordCoding` writes (+ `owner`), index `owner` / the creator / the modification time, and give no world read.
@Suite("CloudKit schema file")
struct SchemaFileTests {
    static let fileURL = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Xcode/CloudKit/schema.ckdb")

    /// Record type → (field → declaration) and its GRANT lines.
    static func parse() throws -> [String: (fields: [String: String], grants: [String])] {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        var result: [String: (fields: [String: String], grants: [String])] = [:]
        var current: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("RECORD TYPE ") {
                current = String(line.dropFirst("RECORD TYPE ".count).split(separator: " ").first ?? "")
                result[current!] = ([:], [])
            } else if line.hasPrefix(")") {
                current = nil
            } else if let type = current, !line.isEmpty {
                let body = line.hasSuffix(",") ? String(line.dropLast()) : line
                if body.hasPrefix("GRANT ") {
                    result[type]?.grants.append(body)
                } else {
                    let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
                    result[type]?.fields[parts[0].replacingOccurrences(of: "\"", with: "")] =
                        parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                }
            }
        }
        return result
    }

    @Test func fieldsMatchWhatTheCodeWrites() throws {
        let schema = try Self.parse()
        for item in CloudSchemaBootstrap.placeholders(now: Date()) {
            let type = item.id.recordType
            let declared = try #require(schema[type], "\(type) missing from schema.ckdb")
            let written = Set(CloudRecordCoding.record(for: item).allKeys()).union([CloudSchema.Field.owner])
            let user = Set(declared.fields.keys.filter { !$0.hasPrefix("___") })
            #expect(user == written, "\(type): schema \(user.sorted()) vs code \(written.sorted())")
        }
    }

    @Test func indexesAndPermissions() throws {
        let schema = try Self.parse()
        for type in CloudSchema.RecordType.all {
            let declared = try #require(schema[type])
            #expect(declared.fields[CloudSchema.Field.owner] == "STRING QUERYABLE", "\(type)")
            #expect(declared.fields["___modTime"] == "TIMESTAMP QUERYABLE SORTABLE", "\(type)")
            #expect(declared.fields["___createdBy"] == "REFERENCE QUERYABLE", "\(type): the creator-only role filters queries on it")
            #expect(declared.grants == [#"GRANT READ, WRITE TO "_creator""#, #"GRANT CREATE TO "_icloud""#], "\(type): no world read")
        }
    }
}
