import Foundation

/// Positions belong to the editor document, not to Markdown source offsets.
struct CrepeSelection: Codable, Equatable {
    var anchor: Int
    var head: Int
}

struct CrepeSnapshot: Decodable {
    let id: UUID
    let generation: UUID
    let revision: Int
    let markdown: String
    let selection: CrepeSelection
    let active: [String]
    let mixed: [String]
}

/// A late bridge message can update its own note, but never a newer incarnation
/// of that note (external replace/reload) or an already deleted note.
struct CrepeBridgeState {
    private var generations: [UUID: UUID] = [:]
    private var revisions: [UUID: Int] = [:]

    mutating func begin(_ id: UUID, generation: UUID) {
        generations[id] = generation
        revisions[id] = -1
    }

    mutating func accept(_ snapshot: CrepeSnapshot, existingIDs: Set<UUID>) -> Bool {
        guard existingIDs.contains(snapshot.id), generations[snapshot.id] == snapshot.generation,
              snapshot.revision > (revisions[snapshot.id] ?? -1),
              snapshot.selection.anchor >= 0, snapshot.selection.head >= 0 else { return false }
        revisions[snapshot.id] = snapshot.revision
        return true
    }

    mutating func forget(except ids: Set<UUID>) {
        generations = generations.filter { ids.contains($0.key) }
        revisions = revisions.filter { ids.contains($0.key) }
    }
}
