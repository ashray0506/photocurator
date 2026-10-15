//  AlbumModels.swift
//  View models for a curated trip album. Map these from your existing Trip / curation types.

import Foundation

struct AlbumPhoto: Identifiable, Hashable {
    /// PHAsset.localIdentifier
    let id: String
    var takenAt: Date?
}

struct TripStamp: Hashable {
    var place: String          // "Lisboa"
    var year: Int
}

struct AlbumSpread: Identifiable, Hashable {
    let id: Int
    var left: [AlbumPhoto]     // 1–3: first is the hero
    var right: [AlbumPhoto]    // 1–3: first is the hero
    var leftCaption: String
    var rightCaption: String
    var stamp: TripStamp?
}

struct AlbumModel: Identifiable, Hashable {
    let id: String             // trip id, used to remember the last open page
    var title: String          // "Portugal, in spring"
    var eyebrow: String        // "앨범 07 · MAY 2025"
    var summary: String        // "Six days, 412 photos. We picked the 38 that tell it best."
    var keptCount: Int
    var totalCount: Int
    var bytesToFree: Int64
    var miles: Int
    var spreads: [AlbumSpread]

    var allPhotos: [AlbumPhoto] { spreads.flatMap { $0.left + $0.right } }
    var outtakeCount: Int { max(totalCount - keptCount, 0) }

    func spreadIndex(containing photo: AlbumPhoto) -> Int? {
        spreads.firstIndex { $0.left.contains(photo) || $0.right.contains(photo) }
    }
}

// MARK: - Pagination

enum AlbumPaginator {
    /// Groups kept photos by day, then lays out spreads of up to 3 + 2 photos.
    /// `caption(for:)` lets you plug in place names or AI captions per day.
    static func spreads(from kept: [AlbumPhoto],
                        stampForSpread: (Int) -> TripStamp? = { _ in nil },
                        caption: (Date?) -> String) -> [AlbumSpread] {
        let calendar = Calendar.current
        let sorted = kept.sorted { ($0.takenAt ?? .distantPast) < ($1.takenAt ?? .distantPast) }
        let byDay = Dictionary(grouping: sorted) { p in p.takenAt.map { calendar.startOfDay(for: $0) } }
        let days = byDay.keys.sorted { ($0 ?? .distantPast) < ($1 ?? .distantPast) }

        var result: [AlbumSpread] = []
        var buffer: [AlbumPhoto] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            var leftFinal = Array(buffer.prefix(3))
            var right = Array(buffer.dropFirst(3))
            if right.isEmpty, leftFinal.count > 1 { right = [leftFinal.removeLast()] }   // never leave a page blank
            let i = result.count
            result.append(AlbumSpread(id: i,
                                      left: leftFinal,
                                      right: right,
                                      leftCaption: caption(leftFinal.first?.takenAt),
                                      rightCaption: caption(right.first?.takenAt),
                                      stamp: stampForSpread(i)))
            buffer.removeAll()
        }

        for day in days {
            for photo in byDay[day] ?? [] {
                buffer.append(photo)
                if buffer.count == 5 { flush() }
            }
            if buffer.count >= 3 { flush() }   // start a new spread on a new day when sensible
        }
        flush()
        return result
    }
}
