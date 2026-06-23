import RepoPromptCore
import RepoPromptCoreMacOS

extension RepoPromptCore.FileSystemService {
    static func realpathString(_ path: String) -> String? {
        realpathString(path, access: MacOSWorkspaceDirectoryAccess())
    }
}
