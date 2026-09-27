import Foundation

/// The directory tree a set of changed files is shown in, and the flat order that tree implies.
///
/// Only the part with no SwiftUI in it is here. A file-list view walks `tree(of:)` to emit its
/// own rows (collapsed directories, indentation).
public enum FileTree {
/// Directory-first, alphabetical-within-directory order (subdirectories before the files
/// directly inside them), as a flat list. "Next/previous file" navigation should call this
/// rather than approximate the sort, or it will disagree with the tree.
public static func fileOrder(for files: [FileChange]) -> [FileChange] {
    var out: [FileChange] = []
    func walk(_ node: Node) {
        for key in node.children.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            if let child = node.children[key] { walk(child) }
        }
        for (_, file) in node.files.sorted(by: { $0.0.localizedStandardCompare($1.0) == .orderedAscending }) {
            out.append(file)
        }
    }
    walk(tree(of: files))
    return out
}

/// The path of the row a file tree draws first. Seeding a selection with `files.first`
/// instead picks whatever the source happened to list first, which is a row in the middle
/// of the tree.
public static func firstPath(of files: [FileChange]) -> String? { fileOrder(for: files).first?.path }

/// A flat lexicographic sort of full paths diverges from tree order exactly when a directory
/// has both a subdirectory and a file of its own — e.g. "app/config.rb" sorts before
/// "app/models/x.rb" lexicographically ('c' < 'm'), but the tree lists subdirectories first.
/// Navigation that approximated this order with a plain sort walked paths like these in a
/// different order from the tree.
@_spi(Testing) public static func demo() {
    func f(_ path: String) -> FileChange {
        FileChange(path: path, status: .modified, additions: 1, deletions: 0, patch: "")
    }
    let files = [f("app/config.rb"), f("app/models/x.rb"), f("app/models/y.rb"), f("zzz.rb")]
    let order = fileOrder(for: files).map(\.path)
    assert(order == ["app/models/x.rb", "app/models/y.rb", "app/config.rb", "zzz.rb"])
    // The initial selection is the top row of the tree, not the first file listed.
    assert(firstPath(of: files) == "app/models/x.rb")
}

/// Groups paths into a directory trie, then collapses single-child directory chains so
/// "Sources/App/Diff" is one row instead of three.
public static func tree(of files: [FileChange]) -> Node {
    let root = Node(name: "")
    for file in files {
        var components = file.path.split(separator: "/").map(String.init)
        guard let fileName = components.popLast() else { continue }
        var cursor = root
        for component in components {
            if let existing = cursor.children[component] {
                cursor = existing
            } else {
                let child = Node(name: component)
                cursor.children[component] = child
                cursor = child
            }
        }
        cursor.files.append((fileName, file))
    }
    collapse(root)
    return root
}

/// Folds a directory that holds exactly one sub-directory and no files of its own into
/// that child, so the chain reads "a/b/c" on one row.
static func collapse(_ node: Node) {
    for child in node.children.values { collapse(child) }
    guard node.files.isEmpty, node.children.count == 1,
          let child = node.children.values.first, !node.name.isEmpty else { return }
    node.name += "/" + child.name
    node.children = child.children
    node.files = child.files
}

/// A reference type so `collapse` can rewrite a chain in place. The file list walks one of
/// these to emit its rows, which is the only reason the members are public.
public final class Node {
    public var name: String
    public var children: [String: Node] = [:]
    public var files: [(String, FileChange)] = []

    init(name: String) { self.name = name }
}
}
