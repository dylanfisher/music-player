import Discogs
import Fixtures
import Foundation

/// A batch of a Discogs dump's records (51.16): the first byte picks the dump, and the rest is
/// its XML. Each record parsed was a start tag of the dump's record element.
let discogsDump = FuzzTarget(
    name: "discogs-dump",
    summary: "a batch of Discogs dump records (the first byte picks the dump)",
    seedFormats: [],
    tokens: [
        "<release id=\"", "<master id=\"", "<track>", "</track>", "<sub_tracks>", "<duration>",
        "99999999999999999999:00", "<position>", "<anv>", "<master_id is_main_release=\"",
        "<identifier type=\"Barcode\" value=\"", "&amp;", "<id>", "<namevariations>",
    ],
    madeSeeds: { _, _ in
        let records = [
            "<label><id>1</id><name>Svek</name><profile>Swedish</profile></label>\n",
            "<artist><id>1</id><name>Persuader</name><namevariations><name>The Persuader</name>"
                + "</namevariations></artist>\n",
            #"<master id="5"><main_release>10</main_release><artists><artist><id>1</id><name>Persuader</name><anv>P.</anv></artist></artists><title>Stockholm</title><year>1999</year></master>"#
                + "\n",
            DiscogsDumpFixture.syntheticReleases(count: 3)
                + #"<release id="4"><title>Index</title><tracklist><track><position></position><title>Suite</title><sub_tracks><track><position>1a</position><title>Part</title><duration>4:05</duration></track></sub_tracks></track></tracklist></release>"#
                + "\n",
        ]
        return zip(DumpKind.allCases, records).enumerated().map { index, pair in
            [UInt8(index)] + Array("<\(pair.0.rawValue)>\n\(pair.1)</\(pair.0.rawValue)>\n".utf8)
        }
    },
    prepare: { _ in
        { input in
            guard let selector = input.first else { return false }
            let kind = DumpKind.allCases[Int(selector) % DumpKind.allCases.count]
            let document = Data(input.dropFirst())
            guard let records = dumpRecordCount(in: document, kind: kind) else { return false }
            let element = Array("<\(String(kind.rawValue.dropLast()))".utf8)
            let starts = document.indices.filter { document[$0...].starts(with: element) }.count
            precondition(records <= starts, "\(records) records from \(starts) start tags")
            return true
        }
    })
