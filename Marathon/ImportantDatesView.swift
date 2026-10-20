//
//  ImportantDatesView.swift
//  Marathon
//
//  Created by Marcus Price on 11/12/25.
//

import SwiftUI

struct ImportantDatesView: View {
    @EnvironmentObject var store: WorkoutStore
    @State private var isPresentingEditor = false
    @State private var draft: ImportantDate = .empty()
    @State private var editingIndex: Int? = nil

    // Toolbar color to match background and respond to scroll
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"
    @State private var isScrolled = false

    var body: some View {
        List {
            // Invisible probe at the top of the list to track scroll offset
            Color.clear
                .frame(height: 0.5)
                .listRowInsets(EdgeInsets())
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: NavBarOffsetKey.self, value: proxy.frame(in: .named("datesScroll")).minY)
                    }
                )

            ForEach(store.importantDates.indices, id: \.self) { idx in
                let item = store.importantDates[idx]
                Button {
                    editingIndex = idx
                    draft = item
                    isPresentingEditor = true
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: dateIcon(for: item))
                            .foregroundStyle(AthensTheme.goldAccent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title.isEmpty ? "Untitled" : item.title)
                                .font(.headline)
                            HStack(spacing: 6) {
                                if let d = item.date {
                                    Text(d.formatted(date: .abbreviated, time: .shortened))
                                        .foregroundStyle(.secondary)
                                }
                                if let notes = item.notes, !notes.isEmpty {
                                    if item.date != nil { Text("•").foregroundStyle(.secondary) }
                                    Text(notes).foregroundStyle(.secondary)
                                }
                            }
                            .font(.subheadline)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .onDelete { idxSet in
                store.importantDates.remove(atOffsets: idxSet)
                store.saveImportantDates()
            }
            .onMove { src, dst in
                store.importantDates.move(fromOffsets: src, toOffset: dst)
                store.saveImportantDates()
            }
        }
        .coordinateSpace(name: "datesScroll")
        .onPreferenceChange(NavBarOffsetKey.self) { y in
            withAnimation(.easeInOut(duration: 0.2)) {
                isScrolled = y < -2
            }
        }
        .navigationTitle("Important Dates")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    draft = ImportantDate(title: "", date: nil, notes: nil)
                    editingIndex = nil
                    isPresentingEditor = true
                } label: { Image(systemName: "plus") }
                .tint(AthensTheme.goldAccent)
            }
        }
        .sheet(isPresented: $isPresentingEditor) {
            NavigationStack {
                ImportantDateEditor(item: $draft)
                    .navigationTitle(editingIndex == nil ? "New Item" : "Edit Item")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { isPresentingEditor = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                if let idx = editingIndex {
                                    store.importantDates[idx] = draft
                                } else {
                                    store.importantDates.append(draft)
                                }
                                store.saveImportantDates()
                                isPresentingEditor = false
                            }
                            .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        #if os(iOS)
        // Match Home: transparent at top, dynamic blue when scrolled
        .toolbarBackground(isScrolled ? AthensTheme.midnightBlue : .clear, for: .navigationBar)
        .toolbarBackgroundVisibility(isScrolled ? .visible : .hidden, for: .navigationBar)
        .toolbarColorScheme(appColorScheme == "light" ? .light : .dark, for: .navigationBar)
        #endif
        .background(AthensTheme.backgroundGradient.ignoresSafeArea())
    }

    private func dateIcon(for item: ImportantDate) -> String {
        item.date == nil ? "calendar.badge.exclamationmark" : "calendar"
    }
}

private struct ImportantDateEditor: View {
    @Binding var item: ImportantDate
    @State private var hasDate: Bool = false

    var body: some View {
        Form {
            Section("Title") {
                TextField("Enter title", text: $item.title)
            }
            Section("Date") {
                Toggle("Has Date", isOn: $hasDate.animation())
                if hasDate {
                    DatePicker("When", selection: Binding<Date>(
                        get: { item.date ?? Date() },
                        set: { item.date = $0 }
                    ), displayedComponents: [.date, .hourAndMinute])
                }
            }
            Section("Notes") {
                TextField("Optional details", text: Binding<String>(
                    get: { item.notes ?? "" },
                    set: { item.notes = $0.isEmpty ? nil : $0 }
                ))
            }
        }
        .onAppear {
            hasDate = item.date != nil
        }
        .onChange(of: hasDate) {
            if !hasDate { item.date = nil }
            else if item.date == nil { item.date = Date() }
        }
    }
}

// PreferenceKey to track scroll offset (local to this file)
private struct NavBarOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
