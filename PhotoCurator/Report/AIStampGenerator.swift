import Foundation

/// Opt-in AI-written passport-stamp lines — reuses `AnthropicClient`, the
/// same plumbing and the same opt-in gate as `AITripNamer` (a saved API
/// key in Settings). Sends exactly a place name and its country, nothing
/// else — not photos, not dates, not any other trip data.
///
/// Checked Vision's landmark-recognition capability before building this:
/// there is no public API for it (`VNClassifyImageRequest`, which does
/// run on every photo, is a general ~1300-label scene/object classifier,
/// not a landmark identifier) — Apple doesn't expose that to third-party
/// apps. So a stamp's text comes from place/country text alone, the same
/// data `AITripNamer` already sends, not from anything in the photos.
struct AIStampGenerator {
    /// A short phrase suitable for a passport-stamp caption, e.g. "Rome"
    /// + "Italy" -> "Eternal City" or "Ancient Rome" — evocative rather
    /// than literal, since the place name itself is already on the stamp.
    func suggestCaption(place: String, country: String?) async throws -> String {
        let countryText = country.map { ", \($0)" } ?? ""
        let prompt = """
        Write a short, evocative caption (2-4 words, no quotation marks, \
        no emoji) for a travel passport stamp for this place: \(place)\(countryText). \
        Something that captures its character, not a literal description. \
        Reply with only the caption, nothing else.
        """
        return try await AnthropicClient.complete(prompt: prompt, maxTokens: 20)
    }
}
