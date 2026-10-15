import Foundation

/// Opt-in AI-generated trip names via the Anthropic API — the one
/// deliberate, explicit exception to this app's "fully on-device"
/// design. Never automatic: a user must have entered their own API key
/// in Settings AND tapped "Suggest with AI" on a specific trip. What
/// leaves the device is exactly the trip's place names, country, and
/// date range — never photos, never any other photo metadata. See
/// `AnthropicClient` for the shared request plumbing.
struct AITripNamer {
    typealias NamerError = AnthropicClient.ClientError

    /// `places` is city-level names in visit order (the same stops
    /// `Trip.suggestedName` itself uses — see `LibraryScanner.namingStops`),
    /// never raw GPS or anything photo-derived.
    func suggestName(places: [String], country: String?, startDay: Date, endDay: Date) async throws -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        let dateRange = Calendar.current.isDate(startDay, inSameDayAs: endDay)
            ? formatter.string(from: startDay)
            : "\(formatter.string(from: startDay)) to \(formatter.string(from: endDay))"

        let placesText = places.isEmpty ? "an unknown location" : places.joined(separator: ", ")
        let countryText = country.map { " in \($0)" } ?? ""
        // "Evocative" alone still read as literal/generic in practice
        // (basically the place name restated) — asked directly for
        // something with warmth and nostalgia instead, the way someone
        // would title a photo album they're flipping back through years
        // later, not a travel brochure.
        let prompt = """
        Suggest a short, warm, nostalgic title (4 words maximum, no quotation \
        marks, no emoji) for a travel photo album covering these \
        places\(countryText): \(placesText). Trip dates: \(dateRange). Write it \
        the way someone would title a cherished photo album they're looking \
        back on years later — fond and a little wistful, not a travel-brochure \
        description, and not just the place name restated. Reply with only the \
        title, nothing else.
        """
        return try await AnthropicClient.complete(prompt: prompt, maxTokens: 40)
    }
}
