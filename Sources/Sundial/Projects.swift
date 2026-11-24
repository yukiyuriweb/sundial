import Foundation

/// The name of the Git repository holding the path, looking no higher than the home folder. A linked
/// worktree (such as one an agent made) counts as its main repository.
func gitProject(forPath path: String) -> String? {
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    var dir = isDirectory.boolValue ? path : (path as NSString).deletingLastPathComponent
    let home = NSHomeDirectory()
    while dir.hasPrefix(home + "/") {
        let git = dir + "/.git"
        var gitIsDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: git, isDirectory: &gitIsDirectory) {
            return (gitIsDirectory.boolValue ? nil : mainRepository(ofWorktree: git)) ?? (dir as NSString).lastPathComponent
        }
        dir = (dir as NSString).deletingLastPathComponent
    }
    return nil
}

/// A worktree's .git file reads "gitdir: <repo>/.git/worktrees/<name>"
private func mainRepository(ofWorktree gitFile: String) -> String? {
    guard let text = try? String(contentsOfFile: gitFile, encoding: .utf8),
          let range = text.range(of: "/.git/worktrees/") else { return nil }
    let line = text[..<range.lowerBound]
    let repo = line.hasPrefix("gitdir: ") ? line.dropFirst("gitdir: ".count) : line
    return (String(repo) as NSString).lastPathComponent
}

func abbreviated(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
