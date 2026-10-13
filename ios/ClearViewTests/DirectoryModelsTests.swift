import XCTest
@testable import ClearView

/// Tests for the channel directory: what the server sends, what survives the offline
/// cache, and which rows are refused rather than drawn broken.
final class DirectoryModelsTests: XCTestCase {

    private let body = """
    {
      "categories": [
        {
          "id": "cat-news",
          "name": "News",
          "slug": "news",
          "sort": 1,
          "channels": [
            {"id": "c1", "platform": "youtube", "handle": "bbcnews", "name": "BBC News",
             "iconUrl": "https://x/bbc.png", "url": "https://youtube.com/@bbcnews",
             "categoryId": "cat-news", "sort": 2}
          ],
          "subcategories": [
            {
              "id": "sub-uk",
              "categoryId": "cat-news",
              "name": "UK",
              "slug": "uk",
              "sort": 1,
              "channels": [
                {"id": "c2", "platform": "x", "handle": "uknews", "name": null,
                 "iconUrl": null, "url": "https://x.com/uknews", "subcategoryId": "sub-uk", "sort": 1}
              ]
            }
          ]
        },
        {
          "id": "cat-empty",
          "name": "Empty",
          "slug": "empty",
          "sort": 2,
          "channels": [],
          "subcategories": []
        }
      ],
      "unfiled": [
        {"id": "c3", "platform": "instagram", "handle": "someone", "name": "Someone",
         "url": "https://instagram.com/someone", "sort": 3}
      ]
    }
    """

    /// The whole nested shape parses: categories, their channels, their subcategories and
    /// the unfiled list.
    func testTheWholeSnapshotParses() throws {
        let snapshot = try XCTUnwrap(DirectoryCodec.snapshot(json: body))

        XCTAssertEqual(snapshot.categories.map(\.id), ["cat-news", "cat-empty"])
        let news = try XCTUnwrap(snapshot.categories.first)
        XCTAssertEqual(news.name, "News")
        XCTAssertEqual(news.slug, "news")
        XCTAssertEqual(news.sort, 1)
        XCTAssertEqual(news.channels.map(\.id), ["c1"])
        XCTAssertEqual(news.subcategories.map(\.id), ["sub-uk"])
        XCTAssertEqual(news.channelCount, 2, "subcategory channels count towards the category")
        XCTAssertEqual(news.channels.first?.iconUrl, "https://x/bbc.png")
        XCTAssertEqual(snapshot.unfiled.map(\.id), ["c3"])
        XCTAssertFalse(snapshot.isEmpty)
    }

    /// "All" is the whole list in server order, and empty categories do not draw a tab.
    func testTheAllListAndDisplayableCategories() throws {
        let snapshot = try XCTUnwrap(DirectoryCodec.snapshot(json: body))

        XCTAssertEqual(snapshot.allChannels.map(\.id), ["c1", "c2", "c3"])
        XCTAssertEqual(snapshot.displayableCategories.map(\.id), ["cat-news"])
        XCTAssertEqual(snapshot.channel(id: "c2")?.handle, "uknews")
        XCTAssertNil(snapshot.channel(id: "nope"))
    }

    /// A channel with no name still has a row — the handle is identity.
    func testAChannelWithNoNameFallsBackToItsHandle() throws {
        let snapshot = try XCTUnwrap(DirectoryCodec.snapshot(json: body))
        let noName = try XCTUnwrap(snapshot.channel(id: "c2"))

        XCTAssertNil(noName.name)
        XCTAssertEqual(noName.displayName, "@uknews")
        XCTAssertEqual(noName.displayHandle, "@uknews")
        XCTAssertEqual(noName.platformLabel, "X")

        let named = try XCTUnwrap(snapshot.channel(id: "c1"))
        XCTAssertEqual(named.displayName, "BBC News")
        XCTAssertEqual(named.platformLabel, "YouTube")
        XCTAssertEqual(named.subcategoryId, nil)
    }

    /// A blank name is not a name: the handle is shown instead.
    func testABlankNameReadsAsNoName() throws {
        let snapshot = try XCTUnwrap(DirectoryCodec.snapshot(json: """
        {"categories": [], "unfiled": [
          {"id": "c9", "platform": "youtube", "handle": "blankname", "name": "   ",
           "iconUrl": "  ", "url": "https://youtube.com/@blankname"}
        ]}
        """))

        let channel = try XCTUnwrap(snapshot.unfiled.first)
        XCTAssertNil(channel.name)
        XCTAssertNil(channel.iconUrl, "a blank icon URL is the same as no icon")
        XCTAssertEqual(channel.displayName, "@blankname")
        XCTAssertEqual(channel.sort, 0, "a missing sort is zero, not a crash")
    }

    /// Rows that cannot be drawn, copied or opened are dropped; the rest of the directory
    /// still loads.
    func testUnusableRowsAreDropped() throws {
        let snapshot = try XCTUnwrap(DirectoryCodec.snapshot(json: """
        {
          "categories": [
            {"id": "", "name": "No id"},
            {"id": "cat-ok", "name": "Fine", "channels": [
              {"id": "no-url", "platform": "x", "handle": "nourl"},
              {"id": "no-platform", "handle": "noplat", "url": "https://x.com/noplat"},
              {"id": "no-handle", "platform": "x", "url": "https://x.com/nohandle"},
              {"id": "ok", "platform": "x", "handle": "fine", "url": "https://x.com/fine"}
            ], "subcategories": [
              {"id": "sub-no-name", "name": ""}
            ]}
          ],
          "unfiled": "not an array"
        }
        """))

        XCTAssertEqual(snapshot.categories.map(\.id), ["cat-ok"])
        XCTAssertEqual(snapshot.categories[0].channels.map(\.id), ["ok"])
        XCTAssertTrue(snapshot.categories[0].subcategories.isEmpty)
        XCTAssertTrue(snapshot.unfiled.isEmpty, "a malformed list is an empty list")
    }

    /// Nothing at all is an empty snapshot, not an error — the screen shows its honest
    /// "no directory yet" state.
    func testMissingBodiesAreEmpty() {
        XCTAssertEqual(DirectoryCodec.snapshot(from: [:]), DirectorySnapshot())
        XCTAssertEqual(DirectoryCodec.snapshot(from: [:]).isEmpty, true)
        XCTAssertNil(DirectoryCodec.decode(nil))
        XCTAssertNil(DirectoryCodec.decode(""))
        XCTAssertNil(DirectoryCodec.decode("not json"))
        XCTAssertNil(DirectoryCodec.decode("[1,2,3]"), "an array is not a snapshot body")
    }

    /// The cache and the network are the same shape: a snapshot survives its own round
    /// trip unchanged, ids and order included.
    func testASnapshotRoundTripsThroughTheCache() throws {
        let snapshot = try XCTUnwrap(DirectoryCodec.snapshot(json: body))
        let restored = try XCTUnwrap(DirectoryCodec.roundTrip(snapshot))

        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(restored.allChannels.map(\.id), ["c1", "c2", "c3"])
        XCTAssertEqual(restored.categories[0].subcategories[0].channels[0].handle, "uknews")
        XCTAssertEqual(restored.unfiled[0].platform, "instagram")
    }

    /// An empty snapshot round trips too — "the directory is empty" is a fact worth
    /// caching, and must not read as "nothing is cached".
    func testAnEmptySnapshotRoundTrips() throws {
        let restored = try XCTUnwrap(DirectoryCodec.roundTrip(DirectorySnapshot()))

        XCTAssertEqual(restored, DirectorySnapshot())
        XCTAssertTrue(restored.isEmpty)
    }

    /// The platform wording, including one the app has not heard of.
    func testPlatformLabels() {
        func label(_ platform: String) -> String {
            DirectoryChannel(
                id: "c",
                platform: platform,
                handle: "h",
                name: nil,
                iconUrl: nil,
                url: "https://example.com",
                categoryId: nil,
                subcategoryId: nil,
                sort: 0
            ).platformLabel
        }

        XCTAssertEqual(label("youtube"), "YouTube")
        XCTAssertEqual(label("instagram"), "Instagram")
        XCTAssertEqual(label("x"), "X")
        XCTAssertEqual(label("threads"), "Threads", "an unknown platform still reads as a name")
    }
}
