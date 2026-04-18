//
//  KokoMemoryManager.swift
//  leanring-buddy
//
//  Persistent memory across sessions. Stores conversation summaries
//  and user-provided notes in a human-readable `memory.md` file in
//  the app's Application Support directory. The user can edit this
//  file directly (via a button in the menu bar panel) to correct or
//  add memories, and its contents are injected into Claude's system
//  prompt so Koko remembers things across app launches.
//

import AppKit
import Foundation

@MainActor
final class KokoMemoryManager {
    /// Whether session memory is enabled. When off, nothing is read
    /// from or written to the memory file, and the system prompt
    /// doesn't include any memory context.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "isKokoMemoryEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "isKokoMemoryEnabled") }
    }

    /// Path to the memory file.
    private let memoryFileURL: URL

    /// Maximum number of memory entries to keep. Oldest entries are
    /// trimmed when this limit is exceeded.
    private let maxMemoryEntries = 50

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Koko", isDirectory: true)

        // Ensure the directory exists.
        try? FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )

        self.memoryFileURL = appSupport.appendingPathComponent("memory.md")

        // Create the file with a header if it doesn't exist yet.
        if !FileManager.default.fileExists(atPath: memoryFileURL.path) {
            let header = """
            # Koko's Memory

            This file stores things Koko remembers across sessions.
            You can edit it freely — add notes, correct mistakes, or
            delete entries you don't want Koko to remember.

            Each entry below is a short summary of a past interaction
            or a note you've added manually.

            ---

            """
            try? header.write(to: memoryFileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Returns the full memory content for injection into the system
    /// prompt. Returns an empty string if memory is disabled or the
    /// file is empty/missing.
    func loadMemoryForPrompt() -> String {
        guard isEnabled else { return "" }
        guard let content = try? String(contentsOf: memoryFileURL, encoding: .utf8) else {
            return ""
        }
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return "" }
        return trimmedContent
    }

    /// Appends a pre-generated summary line to the memory file.
    /// Called by `CompanionManager` after it asks Claude to distill
    /// the exchange into a single short learning. The summary should
    /// be 10-15 words max — a fact Koko learned, not a transcript.
    func appendSummary(_ summary: String) {
        guard isEnabled else { return }
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else { return }

        let timestamp = Self.timestampFormatter.string(from: Date())
        let entry = "- [\(timestamp)] \(trimmedSummary)\n"

        if let fileHandle = try? FileHandle(forWritingTo: memoryFileURL) {
            fileHandle.seekToEndOfFile()
            if let data = entry.data(using: .utf8) {
                fileHandle.write(data)
            }
            try? fileHandle.close()
        }

        trimMemoryIfNeeded()
    }

    /// Opens the memory file in the user's default text editor so
    /// they can review, edit, or add their own notes.
    func openMemoryFileInEditor() {
        NSWorkspace.shared.open(memoryFileURL)
    }

    /// Returns the path to the memory file for display in the UI.
    var memoryFilePath: String {
        memoryFileURL.path
    }

    // MARK: - Private

    /// Keeps the memory file from growing unbounded by trimming the
    /// oldest entries when it exceeds `maxMemoryEntries`.
    private func trimMemoryIfNeeded() {
        guard let content = try? String(contentsOf: memoryFileURL, encoding: .utf8) else { return }

        let lines = content.components(separatedBy: "\n")
        let entryLines = lines.filter { $0.hasPrefix("- [") }

        guard entryLines.count > maxMemoryEntries else { return }

        // Find the header (everything before the first entry) and
        // keep only the most recent entries.
        let headerEndIndex = lines.firstIndex(where: { $0.hasPrefix("- [") }) ?? 0
        let headerLines = Array(lines[..<headerEndIndex])
        let entriesToKeep = Array(entryLines.suffix(maxMemoryEntries))

        let trimmedContent = (headerLines + entriesToKeep).joined(separator: "\n") + "\n"
        try? trimmedContent.write(to: memoryFileURL, atomically: true, encoding: .utf8)
    }

    private static let timestampFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        return dateFormatter
    }()
}
