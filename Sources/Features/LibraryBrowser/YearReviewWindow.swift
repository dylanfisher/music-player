import AppKit
import Library
import Settings

/// Year in Review (ADR 0102): one year's Listening Stats on a page of its own, in a window
/// beside the main one. The year's totals, its busiest month and day and what was new that
/// year, its months as bars with the busiest marked, the top ten of each list, what was first
/// played, the week's clock and the formats. Built from the year's report, the one the panel
/// shows for that year; its rows and bars act as the panel's do.
@MainActor
final class YearReviewWindow: NSWindowController {
    let cards = StatsCards(listLength: 10, listHeightPoints: 248)
    let highlights = StatsFigures()
    let months = StatsBarChart()
    let yearLabel = NSTextField(labelWithString: "")
    let summaryLabel = NSTextField(labelWithString: "")
    private(set) var year: Int?
    private let flow = StatsFlowView()
    private let monthsCard: StatsCard
    private let highlightsCard: StatsCard

    init() {
        monthsCard = StatsCard(title: "Plays per Month", body: months, columns: 2, heightPoints: 200)
        highlightsCard = StatsCard(
            title: "Highlights", body: highlights, columns: 2, heightPoints: 80)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        window.minSize = NSSize(width: 420, height: 400)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Year in Review")
        super.init(window: window)
        build(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, not from a nib") }

    private func build(in window: NSWindow) {
        yearLabel.font = .systemFont(ofSize: 44, weight: .bold)
        let caption = NSTextField(labelWithString: "Year in Review")
        caption.font = .systemFont(ofSize: 20, weight: .medium)
        caption.textColor = .secondaryLabelColor
        summaryLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        let titles = NSStackView(views: [yearLabel, caption])
        titles.alignment = .firstBaseline
        titles.spacing = 10
        let header = NSStackView(views: [titles, summaryLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2

        highlights.valueFontSize = 17
        months.unit = .month
        months.clicked = { [weak self] place in
            guard let self, let bar = cards.report?.months[place] else { return }
            cards.actions.showSpan(bar.span)
        }
        flow.maximumColumns = 2
        flow.minimumColumnPoints = 300
        flow.cards =
            [cards.totalsCard, highlightsCard, monthsCard]
            + StatsReport.List.allCases.compactMap { cards.listCards[$0] }
            + [cards.firstCard, cards.clockCard, cards.formatsCard]

        let page = FlippedView()
        for view in [header, flow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview(view)
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.documentView = page
        page.translatesAutoresizingMaskIntoConstraints = false
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            page.topAnchor.constraint(equalTo: clip.topAnchor),
            header.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -22),
            header.topAnchor.constraint(equalTo: page.topAnchor, constant: 18),
            flow.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10),
            flow.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10),
            flow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            flow.height,
            page.bottomAnchor.constraint(equalTo: flow.bottomAnchor),
        ])
        window.contentView = scroll
    }

    /// Fills the page from `year`'s report and titles the window for it.
    func show(_ report: StatsReport, year: Int, ranking: StatsReport.Ranking) {
        self.year = year
        window?.title = "Year in Review \(year)"
        yearLabel.stringValue = String(year)
        summaryLabel.stringValue =
            count(report.plays, "play") + " · " + approximateDuration(report.seconds) + " · "
            + count(report.artists, "artist") + " · " + count(report.albums, "album")
        cards.show(report, ranking: ranking)
        highlights.figures = Self.highlights(report, calendar: cards.calendar)
        months.bars = report.months
        months.marked = report.busiestMonth.flatMap { busiest in
            report.months.firstIndex(of: busiest)
        }
    }

    /// The busiest month and day, and how many albums and artists were new that year.
    static func highlights(_ report: StatsReport, calendar: Calendar) -> [StatsFigures.Figure] {
        [
            .init(
                value: report.busiestMonth.map { barTitle($0, unit: .month, calendar: calendar) }
                    ?? "–",
                name: "Busiest Month"
                    + (report.busiestMonth.map { ", " + count($0.plays, "play") } ?? "")),
            .init(
                value: report.busiestDay.map { shortDate($0.span.start, calendar: calendar) }
                    ?? "–",
                name: "Busiest Day" + (report.busiestDay.map { ", " + count($0.plays, "play") } ?? ""),
                help: report.busiestDay.map { dayTitle($0.span, calendar: calendar) }),
            .init(value: number(report.firstAlbumCount), name: "New Albums"),
            .init(value: number(report.firstArtistCount), name: "New Artists"),
        ]
    }
}

/// A view whose y runs down, for a page laid out from its top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
