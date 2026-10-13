import Foundation

/// A group of channels on the discovery screen.
///
/// A section is a **named query**, not a stored list: it is the same public channel catalogue
/// read with one `sort` and, for most sections, one `category`. Nothing is curated by hand and
/// nothing is duplicated — a channel appears under its own category because that is what it was
/// created as, which is what keeps the sections from drifting out of step with the catalogue.
///
/// The screen reads in three parts. "Explore channels" is trending — the whole catalogue by
/// follower count, which is what a reader wants first. The category sections are the catalogue
/// split up. "More channels" is the remainder: the channels that carry no category and
/// therefore appear nowhere above.
///
/// Every section is drawn even when it is empty, because the empty ones are still the shape of
/// the product. The order here is what the "See all" screen opens with, so a section cannot open
/// showing rows in a different order from the few it previewed.
enum ChannelSection: String, CaseIterable {
    /// The most-followed channels anywhere — the screen's first section.
    ///
    /// `popular` rather than `active`: this is the one section that is not a category, so its job
    /// is to answer "what is worth following", and the answer to that is what other readers have
    /// already decided.
    case explore
    case entertainment
    case sports
    /// News and current affairs.
    case news
    case lifestyle
    case people
    case business
    case organizations
    /// Everything that does not fit a category — the last section.
    ///
    /// Not "newest", which is what this used to be: a channel with no category is a real state
    /// (one is created before anybody files it), and it is the one group of channels no other
    /// section on this screen can show.
    case more

    /// The `sort` the API is asked for.
    var sort: String {
        switch self {
        case .explore: return "popular"
        default: return "active"
        }
    }

    /// The `category` filter, or nil for a section that spans the catalogue.
    var category: String? {
        switch self {
        case .explore: return nil
        case .entertainment: return "entertainment"
        case .sports: return "sports"
        case .news: return "news"
        case .lifestyle: return "lifestyle"
        case .people: return "people"
        case .business: return "business"
        case .organizations: return "organization"
        case .more: return ChannelSection.uncategorised
        }
    }

    /// The `category` value the API reads as "has no category".
    static let uncategorised = "none"

    /// What the section's heading says.
    var title: String {
        switch self {
        case .explore: return "Explore channels"
        case .entertainment: return "Entertainment"
        case .sports: return "Sports"
        case .news: return "News"
        case .lifestyle: return "Lifestyle"
        case .people: return "People"
        case .business: return "Business"
        case .organizations: return "Organizations"
        case .more: return "More channels"
        }
    }

    /// The sections drawn under a category heading, in the order the screen lists them.
    static let categorySections: [ChannelSection] = [
        .entertainment, .sports, .news, .lifestyle, .people, .business, .organizations,
    ]
}

/// A sort chip on the See-all screen.
///
/// Four orders over **one** list, which is what the chips are: tapping one re-sorts the same
/// channels rather than moving to another screen. Every value maps to a distinct server order —
/// a chip that re-sorted into the order already showing would be a button that appears to do
/// nothing, so the four offered are the four orders the API actually has.
enum ChannelSortChip: String, CaseIterable {
    /// What other readers have followed most — the default, and "trending".
    case trending
    /// Most recently active first.
    case active
    case new
    case name

    /// The `sort` the API is asked for.
    ///
    /// Spelled out rather than taken from the case name, because the wire value for the first
    /// chip is `popular` — the one sort the API has always had — and a chip that sent
    /// "trending" would be a request the server answers with a 400.
    var sort: String {
        switch self {
        case .trending: return "popular"
        case .active: return "active"
        case .new: return "new"
        case .name: return "name"
        }
    }

    var title: String {
        switch self {
        case .trending: return "Trending"
        case .active: return "Most active"
        case .new: return "New"
        case .name: return "A–Z"
        }
    }

    /// The chip to show selected for a sort the API returned.
    static func fromSort(_ sort: String) -> ChannelSortChip {
        allCases.first { $0.sort == sort } ?? .trending
    }
}
