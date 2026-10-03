/// Every `demo()` in the package. The checks are asserts, so this only checks anything in a
/// debug build; `diffkit-selfcheck` refuses to run otherwise.
@_spi(Testing) public enum DiffKitSelfTest {
    public static func run() {
        DiffParser.demo()
        DiffParser.gitDiffDemo()
        DiffAnchor.demo()
        FileTree.demo()
        DiffFind.demo()
        SyntaxHighlighter.demo()
        PatchView.demo()
        PatchImagePreview.demo()
    }
}
