import Foundation
import Testing
@testable import BouncerCore

struct UpdateManifestTests {
    private func manifest(version: String = "0.1.1", build: Int = 30, minimum: String = "27.0",
                          architecture: String = "arm64", digest: String = String(repeating: "a", count: 64),
                          schema: Int = 1) throws -> UpdateManifest {
        let data = try JSONSerialization.data(withJSONObject: ["schema": schema, "version": version, "build": build,
            "minimumSystemVersion": minimum, "architecture": architecture, "sha256": digest])
        return try JSONDecoder().decode(UpdateManifest.self, from: data)
    }

    @Test func permitsNewBuildsAndComparesVersionsNumerically() throws {
        #expect(try manifest(version: "0.1.0").isNewer(thanBuild: 29, version: "0.1.0", systemVersion: "27.0.1"))
        #expect(try manifest(version: "0.10.0").isNewer(thanBuild: 29, version: "0.9.0", systemVersion: "27.0.0"))
        #expect(try manifest(minimum: "27.0.0").isNewer(thanBuild: 29, version: "0.1.0", systemVersion: "27.0"))
    }

    @Test func refusesSameBuildAndBothKindsOfDowngrade() throws {
        #expect(try !manifest(build: 29).isNewer(thanBuild: 29, version: "0.1.0", systemVersion: "27.0.1"))
        #expect(try !manifest(build: 28).isNewer(thanBuild: 29, version: "0.1.0", systemVersion: "27.0.1"))
        #expect(try !manifest(version: "0.0.9").isNewer(thanBuild: 29, version: "0.1.0", systemVersion: "27.0.1"))
    }

    @Test func rejectsUnsupportedAndMalformedReleases() throws {
        let invalid = try [manifest(schema: 2), manifest(build: 0), manifest(architecture: "x86_64"),
            manifest(digest: String(repeating: "z", count: 64)), manifest(digest: "aaa"),
            manifest(version: "0.1.1-beta"), manifest(version: "0..1"), manifest(minimum: "27.x")]
        for value in invalid {
            #expect(throws: UpdateManifest.ValidationError.self) {
                try value.isNewer(thanBuild: 29, version: "0.1.0", systemVersion: "27.0.1")
            }
        }
        #expect(throws: UpdateManifest.ValidationError.self) {
            try manifest(minimum: "28.0").isNewer(thanBuild: 29, version: "0.1.0", systemVersion: "27.0.1")
        }
    }

    @Test func releaseExecutablesRequireARM64AndCannotBeLibrariesOrUniversalArchives() {
        let executable: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1, 0, 0, 0, 0, 2, 0, 0, 0]
        #expect(UpdateBinaryPolicy.isARM64ExecutableHeader(Data(executable)))
        #expect(!UpdateBinaryPolicy.isARM64ExecutableHeader(Data(executable.prefix(15))))
        var intel = executable; intel[4] = 7
        #expect(!UpdateBinaryPolicy.isARM64ExecutableHeader(Data(intel)))
        var library = executable; library[12] = 6
        #expect(!UpdateBinaryPolicy.isARM64ExecutableHeader(Data(library)))
        var universal = executable; universal.replaceSubrange(0..<4, with: [0xca, 0xfe, 0xba, 0xbe])
        #expect(!UpdateBinaryPolicy.isARM64ExecutableHeader(Data(universal)))
    }
}
