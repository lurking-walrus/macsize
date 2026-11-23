import Testing
@testable import MacSizeCore

@Suite struct SensitivePathsTests {
    let home = "/Users/sam"

    @Test func ordinaryFilesAreNotFlagged() {
        #expect(SensitivePaths.warning(for: "/Users/sam/Downloads/big.iso", home: home) == nil)
        #expect(SensitivePaths.warning(for: "/Users/sam/Library/Caches/com.foo", home: home) == nil)
        #expect(SensitivePaths.warning(for: "/Users/sam/Projects/app/node_modules", home: home) == nil)
    }

    @Test func userDataIsFlaggedAtAnyDepth() {
        #expect(SensitivePaths.warning(for: "/Users/sam/Library/Keychains", home: home) != nil)
        #expect(SensitivePaths.warning(for: "/Users/sam/Library/Keychains/login.keychain-db", home: home) != nil)
        #expect(SensitivePaths.warning(for: "/Users/sam/Library/Mobile Documents/com~apple~CloudDocs/x", home: home) != nil)
        #expect(SensitivePaths.warning(for: "/Users/sam/.ssh/id_ed25519", home: home) != nil)
        #expect(SensitivePaths.warning(for: "/Users/sam/Documents/taxes.pdf", home: home) != nil)
    }

    @Test func topLevelFoldersAreFlaggedOnlyForTheFolderItself() {
        #expect(SensitivePaths.warning(for: "/Users/sam/Downloads", home: home) != nil)
        #expect(SensitivePaths.warning(for: "/Users/sam/Library", home: home) != nil)
        #expect(SensitivePaths.warning(for: "/Users/sam/Pictures/vacation.jpg", home: home) == nil)
    }

    @Test func systemAndAppLocationsAreFlagged() {
        #expect(SensitivePaths.warning(for: "/Applications", home: home) != nil)
        #expect(SensitivePaths.warning(for: "/Applications/Safari.app", home: home) != nil)
        #expect(SensitivePaths.warning(for: "/Applications/Safari.app/Contents", home: home) == nil)
        #expect(SensitivePaths.warning(for: "/System/Library/CoreServices", home: home) != nil)
        #expect(SensitivePaths.warning(for: "/Users/sam", home: home) != nil)
        #expect(SensitivePaths.warning(for: "/Users/sam/Pictures/Photos Library.photoslibrary", home: home) != nil)
    }

    @Test func prefixMatchingRespectsPathBoundaries() {
        #expect(SensitivePaths.warning(for: "/Users/sam/Documents2/x", home: home) == nil)
        #expect(SensitivePaths.warning(for: "/usrlocal/x", home: home) == nil)
    }

    @Test func dataVolumePrefixIsNormalized() {
        #expect(SensitivePaths.warning(for: "/System/Volumes/Data/Users/sam/.ssh", home: home) != nil)
    }
}
