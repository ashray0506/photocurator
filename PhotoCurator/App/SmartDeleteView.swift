import SwiftUI
import Photos

/// Build-a-rule deletion, across the whole library regardless of tier —
/// requested directly: "delete certain type of photos, like no face, or
/// face outside the selected or delete selected," plus "add more rules
/// that user can add." Rules stack (AND): add "No face" and "Older than
/// 365 days" together to narrow the match, for instance.
///
/// Crosses tiers (unlike the trip-scoped Extras screen), so it carries
/// its own independent safety floor — see `SmartDeleteRule.swift` and
/// `PhotoDeletionService.deleteSmartSelection`'s doc comments for exactly
/// what that floor is and why it's checked twice.
struct SmartDeleteView: View {
    @EnvironmentObject private var scanner: LibraryScanner
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.colorScheme) private var colorScheme
    private var colors: ThemeColors { ThemeColors(colorScheme) }

    @State private var activeRules: [SmartDeleteRule] = []
    @State private var selectedPersonIds: Set<String> = []
    @State private var showingAddRule = false
    @State private var showingDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deleteProgress: (done: Int, total: Int)?
    @State private var deleteError: String?
    @StateObject private var thumbnails = ThumbnailLoader()

    private var query: SmartDeleteQuery { SmartDeleteQuery(rules: activeRules) }
    private var matches: [PhotoRecord] { scanner.smartDeleteMatches(query) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                rulesSection
                if !activeRules.isEmpty {
                    resultsSection
                }
            }
            .padding(24)
        }
        .navigationTitle("Smart Delete")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete \(matches.count.formatted())", systemImage: "trash")
                }
                .disabled(matches.isEmpty || isDeleting)
            }
        }
        .sheet(isPresented: $showingAddRule) {
            AddRuleSheet(people: scanner.people, existingRuleIds: Set(activeRules.map(\.id))) { rule in
                activeRules.append(rule)
                showingAddRule = false
            }
        }
        .confirmationDialog(
            "Delete \(matches.count.formatted()) photos?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(matches.count.formatted()) Photos", role: .destructive) {
                Task { await performDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They stay in Recently Deleted for 30 days. macOS will also ask you to confirm.")
        }
        .alert("Deletion failed", isPresented: .constant(deleteError != nil), actions: {
            Button("OK") { deleteError = nil }
        }, message: { Text(deleteError ?? "") })
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Smart Delete")
                .font(Theme.titleFont(26))
                .foregroundStyle(colors.ink)
            Text("Build a rule, see exactly what matches, then delete it in one go — works across your whole library, not just one tier.")
                .font(.callout)
                .foregroundStyle(colors.inkMuted)
        }
    }

    // MARK: Rules

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Rules").font(.subheadline.weight(.semibold)).foregroundStyle(colors.inkMuted)
                Spacer()
                Button {
                    showingAddRule = true
                } label: {
                    Label("Add Rule", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }

            if activeRules.isEmpty {
                Text("No rules yet — add one to see matching photos.")
                    .font(.callout)
                    .foregroundStyle(colors.inkMuted)
                    .padding(.vertical, 8)
            } else {
                ForEach(activeRules) { rule in
                    HStack {
                        Text(rule.displayName)
                            .font(.callout)
                            .foregroundStyle(colors.ink)
                        Spacer()
                        Button {
                            activeRules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(colors.inkMuted)
                    }
                    .padding(12)
                    .themedCard(colors, cornerRadius: 8)
                }
            }
        }
    }

    // MARK: Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Matches").font(.subheadline.weight(.semibold)).foregroundStyle(colors.inkMuted)
                Spacer()
                Text("\(matches.count.formatted()) photos")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(colors.inkMuted)
            }

            if let progress = deleteProgress {
                ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                    Text("Deleting \(progress.done.formatted()) of \(progress.total.formatted())…")
                        .font(.caption)
                }
            }

            if matches.isEmpty {
                Text("No photos match these rules.")
                    .font(.callout)
                    .foregroundStyle(colors.inkMuted)
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 150), spacing: 8)], spacing: 8) {
                    ForEach(matches.prefix(120)) { record in
                        thumbnailCell(record)
                    }
                }
                if matches.count > 120 {
                    Text("…and \(matches.count - 120) more.")
                        .font(.caption)
                        .foregroundStyle(colors.inkMuted)
                }
            }
        }
    }

    private func thumbnailCell(_ record: PhotoRecord) -> some View {
        Group {
            if let image = thumbnails.images[record.id] {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 130, height: 130)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: [record.id], options: nil)
            guard let asset = result.firstObject else { return }
            thumbnails.load(asset, targetSize: CGSize(width: 180, height: 180))
        }
    }

    private func performDelete() async {
        isDeleting = true
        let targets = matches
        let count = targets.count
        defer { isDeleting = false; deleteProgress = nil }
        do {
            try await scanner.deleteSmartSelection(targets) { done, total in
                Task { @MainActor in deleteProgress = (done, total) }
            }
            activeRules.removeAll()
            toasts.show("Deleted \(count.formatted()) photos. They're in Recently Deleted for 30 days.",
                       actionLabel: "Open Photos", isAffirmative: true) {
                NSWorkspace.shared.open(URL(string: "photos://")!)
            }
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

/// Picks which rule to add next — a plain list of the fixed rule types
/// plus, for "face not in," a person multi-picker. Adding a brand-new
/// rule *type* later is a new case in `SmartDeleteRule` and one more row
/// here; the screen itself doesn't need to change shape.
private struct AddRuleSheet: View {
    let people: [Person]
    let existingRuleIds: Set<String>
    let onAdd: (SmartDeleteRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPersonIds: Set<String> = []
    @State private var showingPersonPicker = false
    @State private var olderThanDays: String = "365"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add a rule").font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
            }

            List {
                Button("No face in photo") { onAdd(.noFace); dismiss() }
                    .disabled(existingRuleIds.contains(SmartDeleteRule.noFace.id))

                if !people.isEmpty {
                    Button("Face not in selected people…") { showingPersonPicker = true }
                }

                Button("Screenshots") { onAdd(.screenshots); dismiss() }
                    .disabled(existingRuleIds.contains(SmartDeleteRule.screenshots.id))

                ForEach([Tier.tier1, .tier2, .tier3Protected], id: \.self) { tier in
                    Button("In \(tier.shortName)") { onAdd(.inTier(tier)); dismiss() }
                        .disabled(existingRuleIds.contains(SmartDeleteRule.inTier(tier).id))
                }

                HStack {
                    Text("Older than")
                    TextField("days", text: $olderThanDays)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("days")
                    Spacer()
                    Button("Add") {
                        if let days = Int(olderThanDays) {
                            onAdd(.olderThan(days: days))
                            dismiss()
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420, height: 360)
        .sheet(isPresented: $showingPersonPicker) {
            PersonPickerSheet(people: people) { ids in
                onAdd(.faceNotIn(personIds: ids))
                dismiss()
            }
        }
    }
}

private struct PersonPickerSheet: View {
    let people: [Person]
    let onConfirm: (Set<String>) -> Void
    @State private var selected: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keep photos with these people").font(.title3.weight(.semibold))
            Text("Photos with a face that ISN'T one of these will match the rule.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(people, selection: $selected) { person in
                HStack {
                    FaceThumbnail(photoId: person.thumbnailPhotoId, faceBox: person.thumbnailFaceBox, size: 36)
                    Text(person.displayName)
                    Spacer()
                    if selected.contains(person.id) {
                        Image(systemName: "checkmark").foregroundStyle(.blue)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if selected.contains(person.id) { selected.remove(person.id) }
                    else { selected.insert(person.id) }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add Rule") { onConfirm(selected) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380, height: 440)
    }
}
