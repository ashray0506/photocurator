import SwiftUI
import Photos

/// The People section: every known face cluster, carried forward across
/// rescans as a stable `Person` (see `Person.swift` / `PersonMatcher.swift`
/// for why that needed its own groundwork — `FaceCluster` alone has no
/// identity beyond one scan session). Click a card to see everyone's
/// photos with that person in them; rename a card to replace the generic
/// "Person seen N times" placeholder with a real name.
struct PeopleView: View {
    @EnvironmentObject private var scanner: LibraryScanner
    @Environment(\.colorScheme) private var colorScheme
    private var colors: ThemeColors { ThemeColors(colorScheme) }

    @State private var selectedPerson: Person?
    @State private var renamingPerson: Person?
    /// Clustering is a best effort — it will sometimes split one real
    /// person into several cards, or (less often) mix two people
    /// together. Reported directly: "random faces and same faces are
    /// shown differently... no way to merge faces." This mode is the fix
    /// for the "no way" part — picking the cluster quality up by hand
    /// where the algorithm got it wrong, same as renaming fixes the name
    /// the algorithm can't know.
    @State private var isMerging = false
    @State private var mergeSelection: Set<String> = []

    private var sortedPeople: [Person] {
        scanner.people.sorted { $0.photoCount > $1.photoCount }
    }

    var body: some View {
        ScrollView {
            if sortedPeople.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 18)], spacing: 22) {
                    ForEach(sortedPeople) { person in
                        personCard(person)
                    }
                }
                .padding(28)
            }
        }
        .navigationTitle("People")
        .toolbar {
            ToolbarItemGroup {
                if isMerging {
                    Text(mergeSelection.isEmpty ? "Select two or more people to merge" : "\(mergeSelection.count) selected")
                        .font(.caption)
                        .foregroundStyle(colors.inkMuted)
                    Button("Cancel") {
                        isMerging = false
                        mergeSelection = []
                    }
                    Button("Merge") { performMerge() }
                        .disabled(mergeSelection.count < 2)
                } else if sortedPeople.count >= 2 {
                    Button("Merge People…") { isMerging = true }
                }
            }
        }
        .sheet(item: $selectedPerson) { person in
            PersonPhotosSheet(person: person)
        }
        .sheet(item: $renamingPerson) { person in
            RenamePersonSheet(person: person) { newName in
                scanner.renamePerson(id: person.id, to: newName)
                renamingPerson = nil
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent.opacity(0.6))
            Text("No people yet")
                .font(Theme.titleFont(20))
            Text("Scan your library — people who show up often enough across your photos will appear here.")
                .font(.callout)
                .foregroundStyle(colors.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    /// The card with the most photos becomes the survivor — it has the
    /// most representative prints and the most-established name/
    /// thumbnail, so it's the one worth keeping identity around rather
    /// than an arbitrary pick (e.g. selection order).
    private func performMerge() {
        let chosen = sortedPeople.filter { mergeSelection.contains($0.id) }
        guard let keeper = chosen.max(by: { $0.photoCount < $1.photoCount }) else { return }
        let losers = chosen.filter { $0.id != keeper.id }.map(\.id)
        scanner.mergePeople(keep: keeper.id, into: losers)
        isMerging = false
        mergeSelection = []
    }

    private func personCard(_ person: Person) -> some View {
        Button {
            if isMerging {
                if mergeSelection.contains(person.id) {
                    mergeSelection.remove(person.id)
                } else {
                    mergeSelection.insert(person.id)
                }
            } else {
                selectedPerson = person
            }
        } label: {
            VStack(spacing: 8) {
                FaceThumbnail(photoId: person.thumbnailPhotoId, faceBox: person.thumbnailFaceBox, size: 110)
                    .overlay(Circle().stroke(isMerging && mergeSelection.contains(person.id) ? Theme.accent : colors.hairline,
                                             lineWidth: isMerging && mergeSelection.contains(person.id) ? 3 : 1))
                    .overlay(alignment: .topTrailing) {
                        if isMerging && mergeSelection.contains(person.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.white, Theme.accent)
                                .background(Circle().fill(.white))
                                .offset(x: -4, y: 4)
                        }
                    }
                Text(person.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(colors.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !isMerging {
                Button("Rename…") { renamingPerson = person }
                Button("Merge…") {
                    isMerging = true
                    mergeSelection = [person.id]
                }
            }
        }
    }
}

private struct RenamePersonSheet: View {
    let person: Person
    let onConfirm: (String) -> Void
    @State private var draftName: String
    @Environment(\.dismiss) private var dismiss

    init(person: Person, onConfirm: @escaping (String) -> Void) {
        self.person = person
        self.onConfirm = onConfirm
        self._draftName = State(initialValue: person.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Name this person").font(.title3.weight(.semibold))
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onConfirm(draftName) }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { onConfirm(draftName) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}

/// All of one person's photos, in a plain grid — reuses the same
/// thumbnail-cell shape as other review screens in spirit, kept local
/// since this sheet doesn't need rescue/delete actions of its own; Smart
/// Delete is where a person's photos get acted on in bulk.
private struct PersonPhotosSheet: View {
    let person: Person
    @EnvironmentObject private var scanner: LibraryScanner
    @StateObject private var thumbnails = ThumbnailLoader()
    @Environment(\.dismiss) private var dismiss

    private var photos: [PhotoRecord] { scanner.photos(for: person) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(person.displayName).font(.title3.weight(.semibold))
                Spacer()
                Text("\(photos.count.formatted()) photos").font(.caption).foregroundStyle(.secondary)
                Button("Close") { dismiss() }
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 8)], spacing: 8) {
                    ForEach(photos) { record in
                        thumbnailCell(record)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 680, height: 560)
    }

    private func thumbnailCell(_ record: PhotoRecord) -> some View {
        Group {
            if let image = thumbnails.images[record.id] {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: [record.id], options: nil)
            guard let asset = result.firstObject else { return }
            thumbnails.load(asset, targetSize: CGSize(width: 160, height: 160))
        }
    }
}
